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
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: libc.mode_t) c_int;

// File-type bits (S_IFMT masks)
const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;

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

const ModeError = error{ InvalidMode, OutOfMemory };

// A mode operand is either numeric (octal) or symbolic. GNU treats an operand
// whose first character is a decimal digit as numeric; anything else is symbolic.
const ModeKind = union(enum) {
    octal: u32,
    symbolic,
    invalid,
};

// Classify the mode operand and, for numeric modes, validate + parse it.
// GNU accepts octal values <= 0o7777 (leading zeros allowed, e.g. "00755"),
// and rejects anything larger ("010000", "200000"), overlong overflowing
// digit runs, and non-octal digits ("888"). Empty operands are invalid.
fn classifyMode(s: []const u8) ModeKind {
    if (s.len == 0) return .invalid;
    // First char a decimal digit => numeric operand (per GNU).
    if (s[0] >= '0' and s[0] <= '9') {
        var mode: u32 = 0;
        for (s) |ch| {
            if (ch < '0' or ch > '7') return .invalid; // '8'/'9'/letters => invalid
            mode = std.math.mul(u32, mode, 8) catch return .invalid;
            mode = std.math.add(u32, mode, ch - '0') catch return .invalid;
            if (mode > 0o7777) return .invalid; // out of range (e.g. 010000)
        }
        return .{ .octal = mode };
    }
    return .symbolic;
}

fn parseSymbolicMode(allocator: std.mem.Allocator, mode_str: []const u8, current_mode: u32, is_dir: bool) ModeError!u32 {
    var new_mode = current_mode & 0o7777;

    // Split by comma for multiple clauses
    var clauses = std.mem.splitScalar(u8, mode_str, ',');

    var any_clause = false;
    while (clauses.next()) |clause| {
        if (clause.len == 0) continue;
        any_clause = true;

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
        const who_masked = if (who == 0) 7 else who;

        // Parse operator and permissions (can have multiple: u+x-w).
        // A clause MUST contain at least one operator, and any character
        // that is neither an operator nor a valid permission is a hard
        // error (matches GNU: "u+xZ" -> invalid mode).
        while (i < clause.len) {
            const op: ModeOp = switch (clause[i]) {
                '+' => .add,
                '-' => .remove,
                '=' => .set,
                else => return error.InvalidMode,
            };
            i += 1;

            // Parse permissions
            var perms: u32 = 0;
            var special: u32 = 0;
            perm_loop: while (i < clause.len) {
                switch (clause[i]) {
                    'r' => perms |= 4,
                    'w' => perms |= 2,
                    'x' => perms |= 1,
                    'X' => {
                        // Execute only if a directory or already has execute
                        if ((current_mode & 0o111) != 0 or is_dir) {
                            perms |= 1;
                        }
                    },
                    's' => {
                        if ((who_masked & 4) != 0) special |= 0o4000;
                        if ((who_masked & 2) != 0) special |= 0o2000;
                    },
                    't' => special |= 0o1000,
                    '+', '-', '=' => break :perm_loop, // next operation
                    else => return error.InvalidMode,
                }
                i += 1;
            }

            try changes.append(allocator, .{ .who = who_masked, .op = op, .perms = perms, .special = special });
        }

        // A clause with a who but no operator (e.g. "a", "zzz") is invalid.
        if (changes.items.len == 0) return error.InvalidMode;

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

    // An operand of only empty clauses (e.g. "" or ",,") is invalid.
    if (!any_clause) return error.InvalidMode;

    return new_mode;
}

// Render the low 12 mode bits as the 9-char "rwxr-xr-x" string GNU appends to
// -v/-c diagnostics, honouring setuid/setgid (s/S) and sticky (t/T).
fn permString(mode: u32) [9]u8 {
    var b: [9]u8 = undefined;
    b[0] = if (mode & 0o400 != 0) 'r' else '-';
    b[1] = if (mode & 0o200 != 0) 'w' else '-';
    b[2] = execChar(mode & 0o100 != 0, mode & 0o4000 != 0, 's', 'S');
    b[3] = if (mode & 0o040 != 0) 'r' else '-';
    b[4] = if (mode & 0o020 != 0) 'w' else '-';
    b[5] = execChar(mode & 0o010 != 0, mode & 0o2000 != 0, 's', 'S');
    b[6] = if (mode & 0o004 != 0) 'r' else '-';
    b[7] = if (mode & 0o002 != 0) 'w' else '-';
    b[8] = execChar(mode & 0o001 != 0, mode & 0o1000 != 0, 't', 'T');
    return b;
}

fn execChar(exec: bool, special: bool, special_on: u8, special_off: u8) u8 {
    if (special) return if (exec) special_on else special_off;
    return if (exec) 'x' else '-';
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

fn chmodFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config, had_error: *bool) ChmodError!void {
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
    } else switch (classifyMode(config.mode_str)) {
        .octal => |octal| octal,
        // The mode string is validated once up front in main(); by the time
        // we get here it is known-good, so a parse error is unreachable.
        .symbolic => parseSymbolicMode(allocator, config.mode_str, current_mode, is_dir) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidMode => unreachable,
        },
        .invalid => unreachable,
    };

    // Handle recursive BEFORE changing directory permissions
    if (config.recursive and is_dir) {
        try chmodRecursive(allocator, path, config, had_error);
    }

    // Apply chmod. new_mode is bounded to the low 12 bits, so the cast to
    // mode_t (u16 on macOS) cannot overflow.
    const chmod_result = chmod(path_z.ptr, @intCast(new_mode & 0o7777));

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

        const new_bits = new_mode & 0o7777;
        if (new_bits != current_mode) {
            const from = permString(current_mode);
            const to = permString(new_bits);
            writer.interface.print("mode of '{s}' changed from {o:0>4} ({s}) to {o:0>4} ({s})\n", .{
                path,
                current_mode,
                from[0..],
                new_bits,
                to[0..],
            }) catch {};
        } else if (config.verbose) {
            const cur = permString(current_mode);
            writer.interface.print("mode of '{s}' retained as {o:0>4} ({s})\n", .{ path, current_mode, cur[0..] }) catch {};
        }
        writer.interface.flush() catch {};
    }
}

fn chmodRecursive(allocator: std.mem.Allocator, dir_path: []const u8, config: *const Config, had_error: *bool) ChmodError!void {
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

        // Do NOT follow symlinks encountered during traversal. GNU chmod's
        // default (-P) semantics never dereference or descend into a symlink
        // found while walking the tree; doing so would let an attacker who
        // controls a directory redirect our (possibly root) mode changes onto
        // arbitrary files outside it. Classify with lstat and skip symlinks.
        const full_path_z = allocator.dupeZ(u8, full_path) catch return error.OutOfMemory;
        defer allocator.free(full_path_z);
        var lst: Stat = undefined;
        if (lstat(full_path_z.ptr, &lst) == 0 and (@as(u32, lst.mode) & S_IFMT) == S_IFLNK) {
            continue;
        }

        chmodFile(allocator, full_path, config, had_error) catch {
            // A failure on any entry must be reflected in the exit status
            // (GNU chmod -R returns non-zero if any entry fails).
            had_error.* = true;
        };
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

    // Validate the mode operand exactly once, before touching any file — GNU
    // chmod rejects an invalid mode (empty, "888", "zzz", ">0o7777", trailing
    // garbage) with exit 1 and never processes the operands. A symbolic mode's
    // validity is independent of the target file, so a syntax check with a
    // dummy current mode is sufficient.
    if (config.reference_file == null) {
        const bad = switch (classifyMode(config.mode_str)) {
            .octal => false,
            .invalid => true,
            .symbolic => blk: {
                _ = parseSymbolicMode(allocator, config.mode_str, 0, false) catch |e| switch (e) {
                    error.InvalidMode => break :blk true,
                    error.OutOfMemory => {
                        std.debug.print("zchmod: out of memory\n", .{});
                        std.process.exit(1);
                    },
                };
                break :blk false;
            },
        };
        if (bad) {
            std.debug.print("zchmod: invalid mode: '{s}'\n", .{config.mode_str});
            std.debug.print("Try 'zchmod --help' for more information.\n", .{});
            std.process.exit(1);
        }
    }

    var error_occurred = false;
    for (config.files.items) |file| {
        chmodFile(allocator, file, &config, &error_occurred) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
