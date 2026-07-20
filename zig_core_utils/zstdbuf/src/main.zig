const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

// ---------------------------------------------------------------------------
// Mode / size parsing
//
// GNU stdbuf's MODE grammar (coreutils 9.10 stdbuf.c, parse_size ->
// xstrtoumax with valid_suffixes "EGkKMPTYZ0"):
//   - "L"                -> line buffered   (invalid for stdin)
//   - "0" or any number  -> fully buffered with that buffer size (0 == unbuffered)
//   - number + suffix    -> scaled size. Suffix letters: k K (1024), M, G, T,
//                           P, E, Z, Y. A bare suffix or "iB" is a 1024 base;
//                           "B" is a 1000 base. Only 'k' has a lowercase form.
//   - overflow of usize  -> error.TooLarge ("Value too large to be stored ...")
//   - anything else      -> error.InvalidMode ("Invalid argument")
// ---------------------------------------------------------------------------

pub const ModeError = error{ InvalidMode, TooLarge };

pub const Mode = union(enum) {
    line,
    /// fully buffered; 0 means unbuffered.
    size: usize,
};

/// Parse a MODE string exactly as GNU stdbuf does. "L" is a line-buffer mode;
/// everything else is a size (0 == unbuffered).
pub fn parseMode(s: []const u8) ModeError!Mode {
    if (std.mem.eql(u8, s, "L")) return .line;
    return .{ .size = try parseSize(s) };
}

/// Parse a size specification (decimal digits + optional binary/decimal
/// suffix) into a usize, matching GNU's xstrtoumax scaling table.
pub fn parseSize(s: []const u8) ModeError!usize {
    if (s.len == 0) return error.InvalidMode;

    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == 0) return error.InvalidMode; // no leading digits (e.g. "-1", "xyz")

    const num = std.fmt.parseInt(usize, s[0..i], 10) catch return error.TooLarge;

    if (i == s.len) return num;

    // Suffix. First char selects the SI/binary exponent; only 'k' is accepted
    // in lowercase (GNU's valid_suffixes "EGkKMPTYZ0").
    const suffix = s[i..];
    const exp: u6 = switch (suffix[0]) {
        'k', 'K' => 1,
        'M' => 2,
        'G' => 3,
        'T' => 4,
        'P' => 5,
        'E' => 6,
        'Z' => 7,
        'Y' => 8,
        else => return error.InvalidMode,
    };

    const tail = suffix[1..];
    const base: usize = if (tail.len == 0)
        1024
    else if (std.mem.eql(u8, tail, "B"))
        1000
    else if (std.mem.eql(u8, tail, "iB"))
        1024
    else
        return error.InvalidMode;

    // multiplier = base ** exp, then size = num * multiplier, all checked.
    var mult: usize = 1;
    var e: u6 = 0;
    while (e < exp) : (e += 1) {
        mult = std.math.mul(usize, mult, base) catch return error.TooLarge;
    }
    return std.math.mul(usize, num, mult) catch return error.TooLarge;
}

// ---------------------------------------------------------------------------
// libc glue
// ---------------------------------------------------------------------------

extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

/// Absolute path of the running executable, or null if it can't be resolved.
fn selfExePath(buf: []u8) ?[]const u8 {
    if (builtin.os.tag.isDarwin()) {
        var size: u32 = @intCast(buf.len);
        if (_NSGetExecutablePath(buf.ptr, &size) != 0) return null;
        return std.mem.sliceTo(buf, 0);
    } else {
        const n = readlink("/proc/self/exe", buf.ptr, buf.len);
        if (n <= 0 or @as(usize, @intCast(n)) >= buf.len) return null;
        return buf[0..@intCast(n)];
    }
}
const X_OK: c_int = 1;
const F_OK: c_int = 0;
const ENOENT: c_int = 2;

fn diag(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zstdbuf: " ++ fmt, args) catch return;
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn tryHelp() void {
    const m = "Try 'zstdbuf --help' for more information.\n";
    _ = libc.write(libc.STDERR_FILENO, m.ptr, m.len);
}

/// Find an executable in PATH, returning null-terminated path if found.
fn findExecutable(cmd: []const u8, path_buf: []u8) ?[*:0]const u8 {
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        const path_z = std.fmt.bufPrintZ(path_buf, "{s}", .{cmd}) catch return null;
        if (access(path_z.ptr, X_OK) == 0) return path_z.ptr;
        return null;
    }

    var env_idx: usize = 0;
    while (libc.environ[env_idx]) |env_entry| : (env_idx += 1) {
        const env_str = std.mem.span(env_entry);
        if (std.mem.startsWith(u8, env_str, "PATH=")) {
            const path_val = env_str[5..];
            var path_iter = std.mem.splitScalar(u8, path_val, ':');
            while (path_iter.next()) |dir| {
                if (dir.len == 0) continue;
                const full_path = std.fmt.bufPrintZ(path_buf, "{s}/{s}", .{ dir, cmd }) catch continue;
                if (access(full_path.ptr, X_OK) == 0) return full_path.ptr;
            }
            break;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// libstdbuf injection
//
// GNU's actual mechanism: set _STDBUF_I/_STDBUF_O/_STDBUF_E, then pre-load a
// small shared library (libstdbuf) whose constructor reads those variables and
// calls setvbuf() on the child's stdio streams. We ship src/libstdbuf.zig as
// that library and point the platform's pre-load variable at it.
//   - macOS: DYLD_INSERT_LIBRARIES / libstdbuf.dylib
//   - Linux/other: LD_PRELOAD / libstdbuf.so
// If the shipped library cannot be located we still export the _STDBUF_*
// contract (so any compatible libstdbuf already on the preload path works),
// which is exactly GNU's env-var interface.
// ---------------------------------------------------------------------------

const preload_var = if (builtin.os.tag.isDarwin()) "DYLD_INSERT_LIBRARIES" else "LD_PRELOAD";
const preload_lib = if (builtin.os.tag.isDarwin()) "libstdbuf.dylib" else "libstdbuf.so";

/// Return the path to the shipped libstdbuf, if it can be found next to the
/// executable (bin/) or in a sibling lib/ directory. Caller owns the slice.
fn findLibStdbuf(allocator: std.mem.Allocator) ?[]const u8 {
    var exe_path_buf: [4096]u8 = undefined;
    const exe_path = selfExePath(&exe_path_buf) orelse return null;
    const slash = std.mem.lastIndexOfScalar(u8, exe_path, '/') orelse return null;
    const exe_dir = exe_path[0..slash];

    const candidates = [_][]const u8{
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ exe_dir, preload_lib }) catch return null,
        std.fmt.allocPrint(allocator, "{s}/../lib/{s}", .{ exe_dir, preload_lib }) catch return null,
    };
    for (candidates, 0..) |cand, idx| {
        const cand_z = allocator.dupeZ(u8, cand) catch continue;
        defer allocator.free(cand_z);
        if (access(cand_z.ptr, F_OK) == 0) {
            // free the other candidate we won't return
            for (candidates, 0..) |other, j| if (j != idx) allocator.free(other);
            return cand;
        }
    }
    for (candidates) |c| allocator.free(c);
    return null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    // env values to export: "L" or a decimal size string (owned strings).
    var val_i: ?[]const u8 = null;
    var val_o: ?[]const u8 = null;
    var val_e: ?[]const u8 = null;
    var any_mode = false;

    var cmd_args = std.ArrayListUnmanaged([]const u8).empty;
    defer cmd_args.deinit(allocator);

    var parsing_opts = true;

    // Resolve a MODE for a stream. `stdin` rejects line-buffering. On any parse
    // failure this prints the GNU diagnostic and exits 125 (EXIT_CANCELED).
    const resolve = struct {
        fn call(alloc: std.mem.Allocator, raw: []const u8, is_stdin: bool) []const u8 {
            if (std.mem.eql(u8, raw, "L")) {
                if (is_stdin) {
                    diag("line buffering standard input is meaningless\n", .{});
                    tryHelp();
                    std.process.exit(125);
                }
                return "L";
            }
            const size = parseSize(raw) catch |err| {
                switch (err) {
                    error.TooLarge => diag("invalid mode '{s}': Value too large to be stored in data type\n", .{raw}),
                    error.InvalidMode => diag("invalid mode '{s}': Invalid argument\n", .{raw}),
                }
                std.process.exit(125);
            };
            return std.fmt.allocPrint(alloc, "{d}", .{size}) catch {
                std.process.exit(125);
            };
        }
    }.call;

    while (args.next()) |arg| {
        if (!parsing_opts) {
            try cmd_args.append(allocator, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zstdbuf OPTION... COMMAND [ARG]...
                \\Run COMMAND, with modified buffering operations for its standard streams.
                \\
                \\Mandatory arguments to long options are mandatory for short options too.
                \\  -i, --input=MODE   adjust standard input stream buffering
                \\  -o, --output=MODE  adjust standard output stream buffering
                \\  -e, --error=MODE   adjust standard error stream buffering
                \\      --help     display this help and exit
                \\      --version  output version information and exit
                \\
                \\If MODE is 'L' the corresponding stream will be line buffered.
                \\This option is invalid with standard input.
                \\
                \\If MODE is '0' the corresponding stream will be unbuffered.
                \\
                \\Otherwise MODE is a number which may be followed by one of the following:
                \\KB 1000, K 1024, MB 1000*1000, M 1024*1024, and so on for G, T, P, E.
                \\Binary prefixes can be used, too: KiB=K, MiB=M, and so on.
                \\
                \\NOTE: If COMMAND adjusts the buffering of its standard streams ('tee' does
                \\for example) then that will override corresponding changes by 'zstdbuf'.
                \\Also some filters (like 'dd' and 'cat' etc.) don't use streams for I/O,
                \\and are thus unaffected by 'zstdbuf' settings.
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const ver = "zstdbuf (zig-core-utils) 1.0\n";
            _ = libc.write(libc.STDOUT_FILENO, ver.ptr, ver.len);
            return;
        } else if (std.mem.eql(u8, arg, "--")) {
            parsing_opts = false;
        } else if (std.mem.startsWith(u8, arg, "--input")) {
            const mode = try longOptArg(arg, "--input", &args);
            val_i = resolve(allocator, mode, true);
            any_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--output")) {
            const mode = try longOptArg(arg, "--output", &args);
            val_o = resolve(allocator, mode, false);
            any_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--error")) {
            const mode = try longOptArg(arg, "--error", &args);
            val_e = resolve(allocator, mode, false);
            any_mode = true;
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            diag("unrecognized option '{s}'\n", .{arg});
            tryHelp();
            std.process.exit(125);
        } else if (arg.len >= 2 and arg[0] == '-') {
            // Short option cluster. Only -i/-o/-e take an argument; each ends the
            // cluster (the rest is the MODE, or the next argv element).
            const opt = arg[1];
            switch (opt) {
                'i', 'o', 'e' => {
                    const mode = if (arg.len > 2) arg[2..] else (args.next() orelse {
                        diag("option requires an argument -- '{c}'\n", .{opt});
                        tryHelp();
                        std.process.exit(125);
                    });
                    switch (opt) {
                        'i' => val_i = resolve(allocator, mode, true),
                        'o' => val_o = resolve(allocator, mode, false),
                        'e' => val_e = resolve(allocator, mode, false),
                        else => unreachable,
                    }
                    any_mode = true;
                },
                else => {
                    diag("invalid option -- '{c}'\n", .{opt});
                    tryHelp();
                    std.process.exit(125);
                },
            }
        } else {
            // First non-option operand: the command. (getopt '+' semantics.)
            try cmd_args.append(allocator, arg);
            parsing_opts = false;
        }
    }

    // GNU order: missing operand is reported before the "must specify a mode"
    // check, so `stdbuf` with no args prints "missing operand".
    if (cmd_args.items.len == 0) {
        diag("missing operand\n", .{});
        tryHelp();
        std.process.exit(125);
    }
    if (!any_mode) {
        diag("you must specify a buffering mode option\n", .{});
        tryHelp();
        std.process.exit(125);
    }

    // ---- Build the child environment ----------------------------------------
    var envp_buf = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer envp_buf.deinit(allocator);

    const lib_path = findLibStdbuf(allocator);
    defer if (lib_path) |p| allocator.free(p);

    // Copy the existing environment, dropping the vars we are going to set.
    var env_idx: usize = 0;
    while (libc.environ[env_idx]) |env_entry| : (env_idx += 1) {
        const env_str = std.mem.span(env_entry);
        if (std.mem.startsWith(u8, env_str, "_STDBUF_I=")) continue;
        if (std.mem.startsWith(u8, env_str, "_STDBUF_O=")) continue;
        if (std.mem.startsWith(u8, env_str, "_STDBUF_E=")) continue;
        if (lib_path != null and std.mem.startsWith(u8, env_str, preload_var ++ "=")) continue;

        const z = try allocator.allocSentinel(u8, env_str.len, 0);
        @memcpy(z, env_str);
        try envp_buf.append(allocator, z.ptr);
    }

    if (val_i) |v| try appendEnv(allocator, &envp_buf, "_STDBUF_I", v);
    if (val_o) |v| try appendEnv(allocator, &envp_buf, "_STDBUF_O", v);
    if (val_e) |v| try appendEnv(allocator, &envp_buf, "_STDBUF_E", v);

    // Pre-load our libstdbuf so the settings actually take effect.
    if (lib_path) |p| {
        // Prepend to any inherited preload list (we already dropped the old one).
        var old: ?[]const u8 = null;
        var j: usize = 0;
        while (libc.environ[j]) |ee| : (j += 1) {
            const s = std.mem.span(ee);
            if (std.mem.startsWith(u8, s, preload_var ++ "=")) {
                old = s[preload_var.len + 1 ..];
                break;
            }
        }
        const value = if (old) |o|
            try std.fmt.allocPrint(allocator, "{s}:{s}", .{ p, o })
        else
            p;
        try appendEnv(allocator, &envp_buf, preload_var, value);
    }

    try envp_buf.append(allocator, null);

    // ---- Build argv and exec ------------------------------------------------
    var argv_buf = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer argv_buf.deinit(allocator);
    for (cmd_args.items) |arg| {
        const z = try allocator.dupeZ(u8, arg);
        try argv_buf.append(allocator, z.ptr);
    }
    try argv_buf.append(allocator, null);

    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_buf.items.ptr);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(envp_buf.items.ptr);

    var exec_path_buf: [4096]u8 = undefined;
    const exec_path = findExecutable(cmd_args.items[0], &exec_path_buf) orelse {
        diag("failed to run command '{s}': No such file or directory\n", .{cmd_args.items[0]});
        std.process.exit(127);
    };

    _ = execve(exec_path, argv, envp);

    // execve only returns on failure.
    const err = libc._errno().*;
    diag("failed to run command '{s}': {s}\n", .{ cmd_args.items[0], std.mem.span(strerror(err)) });
    std.process.exit(if (err == ENOENT) 127 else 126);
}

/// Extract the argument of a `--long` option, supporting `--long=VALUE` and
/// `--long VALUE`. Errors (exit 125) if a required argument is missing.
fn longOptArg(arg: []const u8, comptime name: []const u8, args: *std.process.Args.Iterator) ![]const u8 {
    if (arg.len == name.len) {
        return args.next() orelse {
            diag("option '{s}' requires an argument\n", .{name});
            tryHelp();
            std.process.exit(125);
        };
    }
    if (arg[name.len] == '=') return arg[name.len + 1 ..];
    // e.g. "--inputX" — not our option.
    diag("unrecognized option '{s}'\n", .{arg});
    tryHelp();
    std.process.exit(125);
}

fn appendEnv(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(?[*:0]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    const z = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ name, value }, 0);
    try list.append(allocator, z.ptr);
}
