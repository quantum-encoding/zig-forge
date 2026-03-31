//! zchmod - Change file mode bits
//!
//! Compatible with GNU chmod:
//! - Octal mode: chmod 755 file
//! - Symbolic mode: chmod u+x,go-w file
//! - -R, --recursive: change files and directories recursively
//! - -v, --verbose: output a diagnostic for every file processed
//! - -c, --changes: like verbose but report only when a change is made
//! - -f, --silent, --quiet: suppress most error messages
//! - --preserve-root: refuse to operate recursively on '/' (default with -R)
//! - --no-preserve-root: override --preserve-root
//! - --reference=RFILE: use RFILE's mode instead of MODE

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const Io = std.Io;

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64, ino: u64, nlink: u64, mode: u32, uid: u32, gid: u32,
        __pad0: u32 = 0, rdev: u64, size: i64, blksize: i64, blocks: i64,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec, birthtim: libc.timespec,
        size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, lspare: i32, qspare: [2]i64,
    },
    else => libc.Stat,
};

// External C functions
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: libc.mode_t) c_int;

const Config = struct {
    recursive: bool = false,
    verbose: bool = false,
    changes: bool = false,
    quiet: bool = false,
    preserve_root: bool = true, // default on with -R
    no_preserve_root: bool = false,
    reference_file: ?[]const u8 = null,
    reference_file_owned: bool = false,
    mode_str: []const u8 = "",
    mode_str_owned: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.mode_str_owned and self.mode_str.len > 0) {
            allocator.free(self.mode_str);
        }
        if (self.reference_file_owned) {
            if (self.reference_file) |r| allocator.free(r);
        }
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

const ModeOp = enum { set, add, remove };

const ModeChange = struct {
    who: u32, // bitmask: 4=user, 2=group, 1=other, 7=all
    op: ModeOp,
    perms: u32, // permission bits (rwx) to apply
    special: u32, // special bits (setuid=0o4000, setgid=0o2000, sticky=0o1000)
};

fn parseOctalMode(s: []const u8) ?u32 {
    var mode: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '7') return null;
        mode = mode * 8 + (ch - '0');
    }
    return mode;
}

fn parseSymbolicMode(allocator: std.mem.Allocator, mode_str: []const u8, current_mode: u32) !u32 {
    var new_mode = current_mode;

    // Split by comma for multiple clauses
    var clauses = std.mem.splitScalar(u8, mode_str, ',');

    while (clauses.next()) |clause| {
        if (clause.len == 0) continue;

        var changes: std.ArrayListUnmanaged(ModeChange) = .empty;
        defer changes.deinit(allocator);

        var i: usize = 0;

        // Parse who (u, g, o, a)
        var who: u32 = 0;
        while (i < clause.len) {
            switch (clause[i]) {
                'u' => who |= 4,
                'g' => who |= 2,
                'o' => who |= 1,
                'a' => who = 7,
                else => break,
            }
            i += 1;
        }

        // Default to 'a' if no who specified
        if (who == 0) who = 7;

        // Parse operator and permissions (can have multiple: u+x-w)
        while (i < clause.len) {
            const op: ModeOp = switch (clause[i]) {
                '+' => .add,
                '-' => .remove,
                '=' => .set,
                else => break,
            };
            i += 1;

            // Parse permissions
            var perms: u32 = 0;
            var special: u32 = 0;
            while (i < clause.len) {
                switch (clause[i]) {
                    'r' => perms |= 4,
                    'w' => perms |= 2,
                    'x' => perms |= 1,
                    'X' => {
                        // Execute only if directory or already has execute
                        if ((current_mode & 0o111) != 0 or (current_mode & 0o40000) != 0) {
                            perms |= 1;
                        }
                    },
                    's' => {
                        if ((who & 4) != 0) special |= 0o4000;
                        if ((who & 2) != 0) special |= 0o2000;
                    },
                    't' => special |= 0o1000,
                    '+', '-', '=' => break, // next operation
                    else => break,
                }
                i += 1;
            }

            try changes.append(allocator, .{ .who = who, .op = op, .perms = perms, .special = special });
        }

        // Apply changes
        for (changes.items) |change| {
            var mask: u32 = 0;
            var bits: u32 = 0;

            if ((change.who & 4) != 0) { // user
                mask |= 0o700;
                bits |= (change.perms & 7) << 6;
            }
            if ((change.who & 2) != 0) { // group
                mask |= 0o070;
                bits |= (change.perms & 7) << 3;
            }
            if ((change.who & 1) != 0) { // other
                mask |= 0o007;
                bits |= (change.perms & 7);
            }

            // Add special bits
            bits |= change.special;

            switch (change.op) {
                .set => {
                    // For '=' operator, also clear special bits based on who
                    var special_mask: u32 = 0;
                    if ((change.who & 4) != 0) special_mask |= 0o4000;
                    if ((change.who & 2) != 0) special_mask |= 0o2000;
                    if ((change.who & 1) != 0) special_mask |= 0o1000;
                    new_mode = (new_mode & ~(mask | special_mask)) | bits;
                },
                .add => {
                    new_mode |= bits;
                },
                .remove => {
                    new_mode &= ~(bits | change.special);
                },
            }
        }
    }

    return new_mode;
}

const ChmodError = error{
    FileNotFound,
    PermissionDenied,
    CannotOpenDirectory,
    OutOfMemory,
};

fn isRootPath(path: []const u8) bool {
    // Normalize: "/" or "//" etc
    if (path.len == 0) return false;
    for (path) |ch| {
        if (ch != '/') return false;
    }
    return true;
}

fn chmodFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config) ChmodError!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Preserve-root check: refuse to operate recursively on '/'
    if (config.recursive and !config.no_preserve_root and config.preserve_root) {
        if (isRootPath(path)) {
            std.debug.print("zchmod: it is dangerous to operate recursively on '/'\n", .{});
            std.debug.print("zchmod: use --no-preserve-root to override this failsafe\n", .{});
            return error.PermissionDenied;
        }
    }

    // Get current mode
    var stat_buf: Stat = undefined;
    const stat_result = stat(path_z.ptr, &stat_buf);

    if (stat_result != 0) {
        if (!config.quiet) {
            std.debug.print("zchmod: cannot access '{s}': No such file or directory\n", .{path});
        }
        return error.FileNotFound;
    }

    const current_mode = stat_buf.mode & 0o7777;
    const is_dir = (stat_buf.mode & 0o170000) == 0o40000;

    // Calculate new mode
    const new_mode = if (config.reference_file) |ref_file| blk: {
        // Use mode from reference file
        const ref_z = allocator.dupeZ(u8, ref_file) catch return error.OutOfMemory;
        defer allocator.free(ref_z);
        var ref_stat: Stat = undefined;
        const ref_result = stat(ref_z.ptr, &ref_stat);
        if (ref_result != 0) {
            if (!config.quiet) {
                std.debug.print("zchmod: cannot stat reference file '{s}': No such file or directory\n", .{ref_file});
            }
            return error.FileNotFound;
        }
        break :blk ref_stat.mode & 0o7777;
    } else if (parseOctalMode(config.mode_str)) |octal|
        octal
    else
        try parseSymbolicMode(allocator, config.mode_str, current_mode);

    // Handle recursive BEFORE changing directory permissions
    if (config.recursive and is_dir) {
        try chmodRecursive(allocator, path, config);
    }

    // Apply chmod
    const chmod_result = chmod(path_z.ptr, @intCast(new_mode));

    if (chmod_result != 0) {
        if (!config.quiet) {
            std.debug.print("zchmod: changing permissions of '{s}': Operation not permitted\n", .{path});
        }
        return error.PermissionDenied;
    }

    // Report changes
    if (config.verbose or (config.changes and new_mode != current_mode)) {
        const io = Io.Threaded.global_single_threaded.io();
        const stdout = Io.File.stdout();
        var buf: [256]u8 = undefined;
        var writer = stdout.writer(io, &buf);

        if (new_mode != current_mode) {
            writer.interface.print("mode of '{s}' changed from {o:0>4} to {o:0>4}\n", .{
                path,
                current_mode,
                new_mode,
            }) catch {};
        } else if (config.verbose) {
            writer.interface.print("mode of '{s}' retained as {o:0>4}\n", .{ path, current_mode }) catch {};
        }
        writer.interface.flush() catch {};
    }
}

fn chmodRecursive(allocator: std.mem.Allocator, dir_path: []const u8, config: *const Config) ChmodError!void {
    const dir_path_z = try allocator.dupeZ(u8, dir_path);
    defer allocator.free(dir_path_z);

    const dir = libc.opendir(dir_path_z.ptr) orelse {
        if (!config.quiet) {
            std.debug.print("zchmod: cannot open directory '{s}'\n", .{dir_path});
        }
        return error.CannotOpenDirectory;
    };
    defer _ = libc.closedir(dir);

    while (true) {
        const entry = libc.readdir(dir) orelse break;

        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);

        // Skip . and ..
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        // Build full path
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
        defer allocator.free(full_path);

        chmodFile(allocator, full_path, config) catch {};
    }
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;
    var mode_found = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and !mode_found) {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--recursive")) {
                    config.recursive = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.eql(u8, arg, "--changes")) {
                    config.changes = true;
                } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                    config.quiet = true;
                } else if (std.mem.eql(u8, arg, "--preserve-root")) {
                    config.preserve_root = true;
                    config.no_preserve_root = false;
                } else if (std.mem.eql(u8, arg, "--no-preserve-root")) {
                    config.no_preserve_root = true;
                } else if (std.mem.startsWith(u8, arg, "--reference=")) {
                    config.reference_file = try allocator.dupe(u8, arg["--reference=".len..]);
                    config.reference_file_owned = true;
                } else {
                    std.debug.print("zchmod: unrecognized option '{s}'\n", .{arg});
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'R' => config.recursive = true,
                        'v' => config.verbose = true,
                        'c' => config.changes = true,
                        'f' => config.quiet = true,
                        else => {
                            std.debug.print("zchmod: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else if (!mode_found) {
            config.mode_str = try allocator.dupe(u8, arg);
            config.mode_str_owned = true;
            mode_found = true;
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // When --reference is used, mode_str is not needed; if we consumed a mode_str,
    // it was actually a file path, so move it to the files list.
    if (config.reference_file != null) {
        if (mode_found and config.mode_str.len > 0) {
            // The "mode_str" was actually a filename
            try config.files.insert(allocator, 0, config.mode_str);
            config.mode_str = "";
            config.mode_str_owned = false;
        }
    } else if (!mode_found) {
        std.debug.print("zchmod: missing operand\n", .{});
        std.debug.print("Try 'zchmod --help' for more information.\n", .{});
        std.process.exit(1);
    }

    if (config.files.items.len == 0) {
        if (config.mode_str.len > 0) {
            std.debug.print("zchmod: missing operand after '{s}'\n", .{config.mode_str});
        } else {
            std.debug.print("zchmod: missing operand\n", .{});
        }
        std.process.exit(1);
    }

    return config;
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zchmod [OPTION]... MODE[,MODE]... FILE...
        \\   or: zchmod [OPTION]... --reference=RFILE FILE...
        \\Change the mode of each FILE to MODE.
        \\
        \\  -c, --changes       like verbose but report only when a change is made
        \\  -f, --silent, --quiet  suppress most error messages
        \\  -v, --verbose       output a diagnostic for every file processed
        \\  -R, --recursive     change files and directories recursively
        \\      --preserve-root    fail to operate recursively on '/' (default)
        \\      --no-preserve-root do not treat '/' specially
        \\      --reference=RFILE  use RFILE's mode instead of MODE values
        \\      --help          display this help and exit
        \\      --version       output version information and exit
        \\
        \\MODE is of the form '[ugoa]*([-+=]([rwxXst]*|[ugo]))+' or an octal number.
        \\
        \\Examples:
        \\  zchmod 755 file        Set file to rwxr-xr-x
        \\  zchmod u+x file        Add execute for owner
        \\  zchmod go-w file       Remove write for group and others
        \\  zchmod a=rw file       Set read/write for all, remove execute
        \\  zchmod -R 644 dir      Recursively set permissions
        \\
        \\zchmod - High-performance chmod utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zchmod 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.debug.print("zchmod: failed to parse arguments\n", .{});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var error_occurred = false;
    for (config.files.items) |file| {
        chmodFile(allocator, file, &config) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
