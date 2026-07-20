//! zchgrp - Change group ownership
//!
//! Compatible with GNU chgrp:
//! - GROUP: change group
//! - -R, --recursive: operate recursively
//! - -v, --verbose: output a diagnostic for every file processed
//! - -c, --changes: like verbose but report only when a change is made
//! - -f, --silent, --quiet: suppress most error messages
//! - -h, --no-dereference: affect symlinks instead of referenced files
//! - -H, -L, -P: recursive symlink-traversal policy (default -P, no traversal)
//! - --dereference: affect referenced files (opposite of -h)
//! - --reference=RFILE: use RFILE's group instead of a GROUP operand
//! - --preserve-root / --no-preserve-root: refuse (or allow) recursion on '/'

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const Io = std.Io;

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        __pad0: u32 = 0,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atim: libc.timespec,
        mtim: libc.timespec,
        ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32,
        mode: u16,
        nlink: u16,
        ino: u64,
        uid: u32,
        gid: u32,
        rdev: i32,
        atim: libc.timespec,
        mtim: libc.timespec,
        ctim: libc.timespec,
        birthtim: libc.timespec,
        size: i64,
        blocks: i64,
        blksize: i32,
        flags: u32,
        gen: u32,
        lspare: i32,
        qspare: [2]i64,
    },
    else => libc.Stat,
};

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;

// Libc functions
extern "c" fn chown(path: [*:0]const u8, owner: libc.uid_t, group: libc.gid_t) c_int;
extern "c" fn lchown(path: [*:0]const u8, owner: libc.uid_t, group: libc.gid_t) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

fn currentErrno() c_int {
    return std.c._errno().*;
}

fn errnoMsg() []const u8 {
    return std.mem.span(strerror(currentErrno()));
}

// Custom struct definitions to work around Zig std lib layout issues
const CGroup = extern struct {
    gr_name: [*:0]const u8,
    gr_passwd: [*:0]const u8,
    gr_gid: libc.gid_t,
    gr_mem: [*:null]?[*:0]const u8,
};

extern "c" fn getgrnam(name: [*:0]const u8) ?*CGroup;
extern "c" fn getgrgid(gid: libc.gid_t) ?*CGroup;

const Traverse = enum { p, h, l };

const Config = struct {
    recursive: bool = false,
    verbose: bool = false,
    changes: bool = false,
    quiet: bool = false,
    no_dereference: bool = false,
    dereference_forced: bool = false,
    traverse: Traverse = .p,
    preserve_root: bool = true,
    // group == null means "no change" (empty group operand, GNU no-op)
    group: ?u32 = 0,
    // As-typed group operand, OR (for --reference) the resolved group name in
    // ref_name_owned. Operand strings point into the stable process argv.
    group_str: []const u8 = "",
    ref_name_owned: ?[]u8 = null,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.ref_name_owned) |n| allocator.free(n);
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

const ChgrpError = error{
    FileNotFound,
    PermissionDenied,
    CannotOpenDirectory,
    InvalidGroup,
    OutOfMemory,
};

/// Resolve a GROUP operand to a numeric gid. Returns null for an invalid group
/// (unknown name, or a numeric value that overflows gid_t). GNU accepts an
/// all-digit operand as a raw numeric gid even if no such group exists.
fn getGidByName(name: []const u8) ?u32 {
    if (name.len == 0) return null;

    // All-digit operands are numeric gids (parsed with an overflow guard).
    var all_digits = true;
    for (name) |ch| {
        if (ch < '0' or ch > '9') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) {
        // std.fmt.parseInt rejects overflow (error.Overflow) -> invalid group,
        // matching GNU instead of a Zig integer-overflow panic.
        return std.fmt.parseInt(u32, name, 10) catch return null;
    }

    // Look up by name using getgrnam
    var name_buf: [256]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;

    const gr = getgrnam(@ptrCast(&name_buf)) orelse return null;
    return gr.gr_gid;
}

fn getGroupName(gid: u32) []const u8 {
    const gr = getgrgid(gid) orelse return "unknown";
    return std.mem.span(gr.gr_name);
}

/// Process one path. `deref` selects follow (stat/chown) vs no-follow
/// (lstat/lchown) semantics. `had_error` is set on any failure so the process
/// exit code becomes 1, matching GNU.
fn chgrpFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config, deref: bool, had_error: *bool) void {
    const path_z = allocator.dupeZ(u8, path) catch {
        had_error.* = true;
        return;
    };
    defer allocator.free(path_z);

    // Get current owner/group using stat/lstat
    var stat_buf: Stat = undefined;
    const stat_result = if (deref)
        stat(path_z.ptr, &stat_buf)
    else
        lstat(path_z.ptr, &stat_buf);

    if (stat_result != 0) {
        const msg = errnoMsg();
        if (!config.quiet) {
            std.debug.print("zchgrp: cannot access '{s}': {s}\n", .{ path, msg });
        }
        had_error.* = true;
        return;
    }

    const current_uid = stat_buf.uid;
    const current_gid = stat_buf.gid;
    const fmt = @as(u32, stat_buf.mode) & S_IFMT;
    const is_dir = fmt == S_IFDIR;

    // No change requested (empty group operand): still descend for -R, but never
    // chown. GNU treats an empty group as a successful no-op.
    const new_gid = config.group orelse current_gid;
    const no_change_requested = config.group == null;

    // Recurse into REAL directories only (deref==false means a symlinked dir was
    // lstat'd as a symlink, so is_dir is false and we never traverse it -> GNU -P).
    if (config.recursive and is_dir) {
        chgrpRecursive(allocator, path, config, had_error);
    }

    if (!no_change_requested) {
        // Apply chown (just changing group, keep owner the same)
        const chown_result = if (deref)
            chown(path_z.ptr, current_uid, new_gid)
        else
            lchown(path_z.ptr, current_uid, new_gid);

        if (chown_result != 0) {
            const msg = errnoMsg();
            if (!config.quiet) {
                std.debug.print("zchgrp: changing group of '{s}': {s}\n", .{ path, msg });
            }
            had_error.* = true;
            return;
        }
    }

    // Report changes
    const changed = (!no_change_requested) and (new_gid != current_gid);
    if (config.verbose or (config.changes and changed)) {
        const io = Io.Threaded.global_single_threaded.io();
        const stdout = Io.File.stdout();
        var buf: [512]u8 = undefined;
        var writer = stdout.writer(io, &buf);

        if (changed) {
            // GNU echoes the group operand exactly as typed in the "to" field
            // (a numeric operand prints the number, a name prints the name); the
            // "from" field is the old gid resolved to a name. group_str holds the
            // as-typed operand (or, for --reference, the resolved group name).
            writer.interface.print("changed group of '{s}' from {s} to {s}\n", .{
                path,
                getGroupName(current_gid),
                config.group_str,
            }) catch {};
        } else if (config.verbose) {
            writer.interface.print("group of '{s}' retained as {s}\n", .{
                path,
                getGroupName(current_gid),
            }) catch {};
        }
        writer.interface.flush() catch {};
    }
}

fn chgrpRecursive(allocator: std.mem.Allocator, dir_path: []const u8, config: *const Config, had_error: *bool) void {
    const dir_path_z = allocator.dupeZ(u8, dir_path) catch {
        had_error.* = true;
        return;
    };
    defer allocator.free(dir_path_z);

    const dir = libc.opendir(dir_path_z.ptr) orelse {
        const msg = errnoMsg();
        if (!config.quiet) {
            std.debug.print("zchgrp: cannot read directory '{s}': {s}\n", .{ dir_path, msg });
        }
        had_error.* = true;
        return;
    };
    defer _ = libc.closedir(dir);

    // Entries inside the tree follow the traversal policy: -P/-H never follow a
    // symlink encountered during descent (lchown the link, don't traverse);
    // only -L dereferences them.
    const entry_deref = !config.no_dereference and config.traverse == .l;

    while (true) {
        const entry = libc.readdir(dir) orelse break;

        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);

        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name }) catch {
            had_error.* = true;
            return;
        };
        defer allocator.free(full_path);

        chgrpFile(allocator, full_path, config, entry_deref, had_error);
    }
}

/// Whether a command-line operand should be dereferenced.
fn topLevelDeref(config: *const Config) bool {
    if (config.no_dereference) return false;
    if (config.dereference_forced) return true;
    if (!config.recursive) return true;
    // Recursive: a command-line symlink is followed only under -H or -L.
    return switch (config.traverse) {
        .p => false,
        .h, .l => true,
    };
}

fn isRootPath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |ch| {
        if (ch != '/') return false;
    }
    return true;
}

fn gidFromReference(allocator: std.mem.Allocator, ref: []const u8) ?u32 {
    const ref_z = allocator.dupeZ(u8, ref) catch return null;
    defer allocator.free(ref_z);
    var stat_buf: Stat = undefined;
    if (stat(ref_z.ptr, &stat_buf) != 0) {
        std.debug.print("zchgrp: failed to get attributes of '{s}': {s}\n", .{ ref, errnoMsg() });
        return null;
    }
    return stat_buf.gid;
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
    var group_found = false;
    var reference: ?[]const u8 = null;
    var end_of_options = false;
    var last_operand: []const u8 = "";

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        const is_option = !end_of_options and arg.len > 1 and arg[0] == '-';

        if (is_option) {
            if (std.mem.eql(u8, arg, "--")) {
                end_of_options = true;
                continue;
            }
            if (arg[1] == '-') {
                // Long options (options are permitted before AND after the group).
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
                } else if (std.mem.eql(u8, arg, "--no-dereference")) {
                    config.no_dereference = true;
                    config.dereference_forced = false;
                } else if (std.mem.eql(u8, arg, "--dereference")) {
                    config.dereference_forced = true;
                    config.no_dereference = false;
                } else if (std.mem.eql(u8, arg, "--preserve-root")) {
                    config.preserve_root = true;
                } else if (std.mem.eql(u8, arg, "--no-preserve-root")) {
                    config.preserve_root = false;
                } else if (std.mem.startsWith(u8, arg, "--reference=")) {
                    reference = arg["--reference=".len..];
                } else {
                    std.debug.print("zchgrp: unrecognized option '{s}'\n", .{arg});
                    std.debug.print("Try 'zchgrp --help' for more information.\n", .{});
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'R' => config.recursive = true,
                        'v' => config.verbose = true,
                        'c' => config.changes = true,
                        'f' => config.quiet = true,
                        'h' => {
                            config.no_dereference = true;
                            config.dereference_forced = false;
                        },
                        'H' => config.traverse = .h,
                        'L' => config.traverse = .l,
                        'P' => config.traverse = .p,
                        else => {
                            std.debug.print("zchgrp: invalid option -- '{c}'\n", .{ch});
                            std.debug.print("Try 'zchgrp --help' for more information.\n", .{});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            last_operand = arg;
            // With --reference, there is no GROUP operand: every positional is a file.
            if (!group_found and reference == null) {
                config.group = getGidByName(arg) orelse {
                    // Empty group operand is a no-op success in GNU chgrp.
                    if (arg.len == 0) {
                        config.group = null;
                        config.group_str = arg;
                        group_found = true;
                        continue;
                    }
                    std.debug.print("zchgrp: invalid group: '{s}'\n", .{arg});
                    std.process.exit(1);
                };
                config.group_str = arg;
                group_found = true;
            } else {
                try config.files.append(allocator, try allocator.dupe(u8, arg));
            }
        }
    }

    if (reference) |ref| {
        const ref_gid = gidFromReference(allocator, ref) orelse {
            std.process.exit(1);
        };
        config.group = ref_gid;
        // GNU displays the reference file's group by NAME in -v/-c diagnostics.
        const owned = try allocator.dupe(u8, getGroupName(ref_gid));
        config.ref_name_owned = owned;
        config.group_str = owned;
        group_found = true;
    }

    if (!group_found) {
        std.debug.print("zchgrp: missing operand\n", .{});
        std.debug.print("Try 'zchgrp --help' for more information.\n", .{});
        std.process.exit(1);
    }

    if (config.files.items.len == 0) {
        std.debug.print("zchgrp: missing operand after '{s}'\n", .{last_operand});
        std.debug.print("Try 'zchgrp --help' for more information.\n", .{});
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
        \\Usage: zchgrp [OPTION]... GROUP FILE...
        \\  or:  zchgrp [OPTION]... --reference=RFILE FILE...
        \\Change the group of each FILE to GROUP.
        \\
        \\  -c, --changes          like verbose but report only when a change is made
        \\  -f, --silent, --quiet  suppress most error messages
        \\  -v, --verbose          output a diagnostic for every file processed
        \\      --dereference      affect the referent of each symbolic link
        \\  -h, --no-dereference   affect symbolic links instead of referenced files
        \\      --reference=RFILE  use RFILE's group rather than a GROUP value
        \\      --preserve-root    fail to operate recursively on '/'
        \\      --no-preserve-root do not treat '/' specially (the default)
        \\  -R, --recursive        operate on files and directories recursively
        \\  -H                     if a command line argument is a symlink to a
        \\                           directory, traverse it
        \\  -L                     traverse every symbolic link to a directory
        \\  -P                     do not traverse any symbolic links (default)
        \\      --help          display this help and exit
        \\      --version       output version information and exit
        \\
        \\Examples:
        \\  zchgrp staff file      Change group to staff
        \\  zchgrp -R users dir    Recursively change group
        \\  zchgrp 1000 file       Change group by GID
        \\
        \\zchgrp - High-performance chgrp utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zchgrp 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var had_error = false;

    // --preserve-root (default): refuse to recurse on '/'.
    if (config.recursive and config.preserve_root) {
        for (config.files.items) |file| {
            if (isRootPath(file)) {
                std.debug.print("zchgrp: it is dangerous to operate recursively on '{s}'\n", .{file});
                std.debug.print("zchgrp: use --no-preserve-root to override this failsafe\n", .{});
                std.process.exit(1);
            }
        }
    }

    const deref = topLevelDeref(&config);
    for (config.files.items) |file| {
        chgrpFile(allocator, file, &config, deref, &had_error);
    }

    if (had_error) {
        std.process.exit(1);
    }
}
