const std = @import("std");
const libc = std.c;

const BufferMode = enum { none, line, full };

fn parseMode(s: []const u8) ?struct { mode: BufferMode, size: usize } {
    if (s.len == 0) return .{ .mode = .full, .size = 0 };

    if (s[0] == 'L' or s[0] == 'l') {
        return .{ .mode = .line, .size = 0 };
    }

    if (s[0] == '0') {
        return .{ .mode = .none, .size = 0 };
    }

    // Parse size
    var end: usize = 0;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') {
        end += 1;
    }

    if (end == 0) return null;

    var size = std.fmt.parseInt(usize, s[0..end], 10) catch return null;

    if (end < s.len) {
        const suffix = s[end];
        const mult: usize = switch (suffix) {
            'K', 'k' => 1024,
            'M', 'm' => 1024 * 1024,
            'G', 'g' => 1024 * 1024 * 1024,
            else => return null,
        };
        size *= mult;
    }

    return .{ .mode = .full, .size = size };
}

extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const X_OK: c_int = 1;

/// Find an executable in PATH, returning null-terminated path if found
fn findExecutable(cmd: []const u8, path_buf: []u8) ?[*:0]const u8 {
    // If the command contains a slash, use it directly
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        const path_z = std.fmt.bufPrintZ(path_buf, "{s}", .{cmd}) catch return null;
        if (access(path_z.ptr, X_OK) == 0) {
            return path_z.ptr;
        }
        return null;
    }

    // Search PATH
    var env_idx: usize = 0;
    while (libc.environ[env_idx]) |env_entry| : (env_idx += 1) {
        const env_str = std.mem.span(env_entry);
        if (std.mem.startsWith(u8, env_str, "PATH=")) {
            const path_val = env_str[5..];
            var path_iter = std.mem.splitScalar(u8, path_val, ':');
            while (path_iter.next()) |dir| {
                if (dir.len == 0) continue;
                const full_path = std.fmt.bufPrintZ(path_buf, "{s}/{s}", .{ dir, cmd }) catch continue;
                if (access(full_path.ptr, X_OK) == 0) {
                    return full_path.ptr;
                }
            }
            break;
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    var stdin_mode: ?[]const u8 = null;
    var stdout_mode: ?[]const u8 = null;
    var stderr_mode: ?[]const u8 = null;
    var cmd_args = std.ArrayListUnmanaged([]const u8).empty;
    defer cmd_args.deinit(allocator);

    var parsing_opts = true;

    while (args.next()) |arg| {
        if (parsing_opts) {
            if (std.mem.eql(u8, arg, "--help")) {
                const help =
                    \\Usage: zstdbuf OPTION... COMMAND [ARG]...
                    \\Run COMMAND with modified buffering operations for its standard streams.
                    \\
                    \\  -i, --input=MODE   adjust stdin buffering
                    \\  -o, --output=MODE  adjust stdout buffering
                    \\  -e, --error=MODE   adjust stderr buffering
                    \\      --help         display this help and exit
                    \\
                    \\MODE is 'L' for line buffered, '0' for unbuffered,
                    \\or a size specification for full buffering.
                    \\
                    \\Note: This implementation uses environment variables to hint
                    \\buffering mode. Full stdbuf functionality requires LD_PRELOAD.
                    \\
                ;
                _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
                return;
            } else if (std.mem.eql(u8, arg, "--")) {
                parsing_opts = false;
            } else if (std.mem.startsWith(u8, arg, "-i")) {
                stdin_mode = if (arg.len > 2) arg[2..] else args.next();
            } else if (std.mem.startsWith(u8, arg, "--input=")) {
                stdin_mode = arg[8..];
            } else if (std.mem.startsWith(u8, arg, "-o")) {
                stdout_mode = if (arg.len > 2) arg[2..] else args.next();
            } else if (std.mem.startsWith(u8, arg, "--output=")) {
                stdout_mode = arg[9..];
            } else if (std.mem.startsWith(u8, arg, "-e")) {
                stderr_mode = if (arg.len > 2) arg[2..] else args.next();
            } else if (std.mem.startsWith(u8, arg, "--error=")) {
                stderr_mode = arg[8..];
            } else if (arg.len > 0 and arg[0] == '-') {
                _ = libc.write(libc.STDERR_FILENO, "zstdbuf: invalid option\n", 24);
                std.process.exit(1);
            } else {
                try cmd_args.append(allocator, arg);
                parsing_opts = false;
            }
        } else {
            try cmd_args.append(allocator, arg);
        }
    }

    if (cmd_args.items.len == 0) {
        _ = libc.write(libc.STDERR_FILENO, "zstdbuf: missing operand\n", 25);
        std.process.exit(1);
    }

    // Build environment list - copy from std.c.environ and add our vars
    var envp_buf = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer envp_buf.deinit(allocator);

    // Track which vars we're overriding
    var override_pythonunbuffered = false;
    var override_stdbuf_o = false;
    var override_stdbuf_e = false;
    var override_stdbuf_i = false;

    // Determine what we need to set
    var set_pythonunbuffered: ?[]const u8 = null;
    var set_stdbuf_o: ?[]const u8 = null;
    var set_stdbuf_e: ?[]const u8 = null;
    var set_stdbuf_i: ?[]const u8 = null;

    // Static buffers for formatted values
    var stdbuf_o_buf: [32]u8 = undefined;
    var stdbuf_e_buf: [32]u8 = undefined;
    var stdbuf_i_buf: [32]u8 = undefined;

    if (stdout_mode) |mode| {
        if (parseMode(mode)) |p| {
            switch (p.mode) {
                .none => {
                    set_pythonunbuffered = "1";
                    set_stdbuf_o = "0";
                    override_pythonunbuffered = true;
                    override_stdbuf_o = true;
                },
                .line => {
                    set_stdbuf_o = "L";
                    override_stdbuf_o = true;
                },
                .full => {
                    const s = std.fmt.bufPrint(&stdbuf_o_buf, "{d}", .{p.size}) catch "4096";
                    set_stdbuf_o = s;
                    override_stdbuf_o = true;
                },
            }
        }
    }

    if (stderr_mode) |mode| {
        if (parseMode(mode)) |p| {
            switch (p.mode) {
                .none => {
                    set_stdbuf_e = "0";
                    override_stdbuf_e = true;
                },
                .line => {
                    set_stdbuf_e = "L";
                    override_stdbuf_e = true;
                },
                .full => {
                    const s = std.fmt.bufPrint(&stdbuf_e_buf, "{d}", .{p.size}) catch "4096";
                    set_stdbuf_e = s;
                    override_stdbuf_e = true;
                },
            }
        }
    }

    if (stdin_mode) |mode| {
        if (parseMode(mode)) |p| {
            switch (p.mode) {
                .none => {
                    set_stdbuf_i = "0";
                    override_stdbuf_i = true;
                },
                .line => {
                    set_stdbuf_i = "L";
                    override_stdbuf_i = true;
                },
                .full => {
                    const s = std.fmt.bufPrint(&stdbuf_i_buf, "{d}", .{p.size}) catch "4096";
                    set_stdbuf_i = s;
                    override_stdbuf_i = true;
                },
            }
        }
    }

    // Copy existing environment, skipping vars we're overriding
    var env_idx: usize = 0;
    while (libc.environ[env_idx]) |env_entry| : (env_idx += 1) {
        const env_str = std.mem.span(env_entry);

        // Check if we should skip this var
        var skip = false;
        if (override_pythonunbuffered and std.mem.startsWith(u8, env_str, "PYTHONUNBUFFERED=")) skip = true;
        if (override_stdbuf_o and std.mem.startsWith(u8, env_str, "STDBUF_O=")) skip = true;
        if (override_stdbuf_e and std.mem.startsWith(u8, env_str, "STDBUF_E=")) skip = true;
        if (override_stdbuf_i and std.mem.startsWith(u8, env_str, "STDBUF_I=")) skip = true;

        if (!skip) {
            const z = try allocator.allocSentinel(u8, env_str.len, 0);
            @memcpy(z, env_str);
            try envp_buf.append(allocator, z.ptr);
        }
    }

    // Add our overrides
    if (set_pythonunbuffered) |val| {
        const env_str = try std.fmt.allocPrint(allocator, "PYTHONUNBUFFERED={s}", .{val});
        const z = try allocator.dupeZ(u8, env_str);
        allocator.free(env_str);
        try envp_buf.append(allocator, z.ptr);
    }
    if (set_stdbuf_o) |val| {
        const env_str = try std.fmt.allocPrint(allocator, "STDBUF_O={s}", .{val});
        const z = try allocator.dupeZ(u8, env_str);
        allocator.free(env_str);
        try envp_buf.append(allocator, z.ptr);
    }
    if (set_stdbuf_e) |val| {
        const env_str = try std.fmt.allocPrint(allocator, "STDBUF_E={s}", .{val});
        const z = try allocator.dupeZ(u8, env_str);
        allocator.free(env_str);
        try envp_buf.append(allocator, z.ptr);
    }
    if (set_stdbuf_i) |val| {
        const env_str = try std.fmt.allocPrint(allocator, "STDBUF_I={s}", .{val});
        const z = try allocator.dupeZ(u8, env_str);
        allocator.free(env_str);
        try envp_buf.append(allocator, z.ptr);
    }

    try envp_buf.append(allocator, null);

    // Convert command args to null-terminated arrays
    var argv_buf = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer argv_buf.deinit(allocator);

    for (cmd_args.items) |arg| {
        const z = try allocator.dupeZ(u8, arg);
        try argv_buf.append(allocator, z.ptr);
    }
    try argv_buf.append(allocator, null);

    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_buf.items.ptr);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(envp_buf.items.ptr);

    // Find the executable in PATH
    var exec_path_buf: [4096]u8 = undefined;
    const exec_path = findExecutable(cmd_args.items[0], &exec_path_buf) orelse {
        _ = libc.write(libc.STDERR_FILENO, "zstdbuf: '", 10);
        _ = libc.write(libc.STDERR_FILENO, cmd_args.items[0].ptr, cmd_args.items[0].len);
        _ = libc.write(libc.STDERR_FILENO, "': command not found\n", 21);
        std.process.exit(127);
    };

    _ = execve(exec_path, argv, envp);

    _ = libc.write(libc.STDERR_FILENO, "zstdbuf: failed to execute '", 28);
    _ = libc.write(libc.STDERR_FILENO, cmd_args.items[0].ptr, cmd_args.items[0].len);
    _ = libc.write(libc.STDERR_FILENO, "'\n", 2);
    std.process.exit(126);
}
