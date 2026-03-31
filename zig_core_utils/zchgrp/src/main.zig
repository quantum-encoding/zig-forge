//! zchgrp - Change group ownership
//!
//! Compatible with GNU chgrp:
//! - GROUP: change group
//! - -R, --recursive: operate recursively
//! - -v, --verbose: output a diagnostic for every file processed
//! - -c, --changes: like verbose but report only when a change is made
//! - -f, --silent, --quiet: suppress most error messages
//! - -h, --no-dereference: affect symlinks instead of referenced files

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

// Libc functions
extern "c" fn chown(path: [*:0]const u8, owner: libc.uid_t, group: libc.gid_t) c_int;
extern "c" fn lchown(path: [*:0]const u8, owner: libc.uid_t, group: libc.gid_t) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;

// Custom struct definitions to work around Zig std lib layout issues
const CGroup = extern struct {
    gr_name: [*:0]const u8,
    gr_passwd: [*:0]const u8,
    gr_gid: libc.gid_t,
    gr_mem: [*:null]?[*:0]const u8,
};

extern "c" fn getgrnam(name: [*:0]const u8) ?*CGroup;
extern "c" fn getgrgid(gid: libc.gid_t) ?*CGroup;

const Config = struct {
    recursive: bool = false,
    verbose: bool = false,
    changes: bool = false,
    quiet: bool = false,
    no_dereference: bool = false,
    group: u32 = 0,
    group_str: []const u8 = "",
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
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

fn getGidByName(name: []const u8) ?u32 {
    if (name.len == 0) return null;

    // Try parsing as numeric GID first
    var gid: u32 = 0;
    var is_numeric = true;
    for (name) |ch| {
        if (ch < '0' or ch > '9') {
            is_numeric = false;
            break;
        }
        gid = gid * 10 + (ch - '0');
    }
    if (is_numeric) return gid;

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

fn chgrpFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config) ChgrpError!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Get current owner/group using stat/lstat
    var stat_buf: Stat = undefined;
    const stat_result = if (config.no_dereference)
        lstat(path_z.ptr, &stat_buf)
    else
        stat(path_z.ptr, &stat_buf);

    if (stat_result != 0) {
        if (!config.quiet) {
            std.debug.print("zchgrp: cannot access '{s}': No such file or directory\n", .{path});
        }
        return error.FileNotFound;
    }

    const current_uid = stat_buf.uid;
    const current_gid = stat_buf.gid;
    const is_dir = (stat_buf.mode & 0o170000) == 0o40000;

    const new_gid = config.group;

    // Handle recursive BEFORE changing directory
    if (config.recursive and is_dir) {
        chgrpRecursive(allocator, path, config) catch {};
    }

    // Apply chown (just changing group, keep owner the same)
    const chown_result = if (config.no_dereference)
        lchown(path_z.ptr, current_uid, new_gid)
    else
        chown(path_z.ptr, current_uid, new_gid);

    if (chown_result != 0) {
        if (!config.quiet) {
            std.debug.print("zchgrp: changing group of '{s}': Operation not permitted\n", .{path});
        }
        return error.PermissionDenied;
    }

    // Report changes
    const changed = (new_gid != current_gid);
    if (config.verbose or (config.changes and changed)) {
        const io = Io.Threaded.global_single_threaded.io();
        const stdout = Io.File.stdout();
        var buf: [512]u8 = undefined;
        var writer = stdout.writer(io, &buf);

        if (changed) {
            writer.interface.print("group of '{s}' changed from {s} to {s}\n", .{
                path,
                getGroupName(current_gid),
                getGroupName(new_gid),
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

fn chgrpRecursive(allocator: std.mem.Allocator, dir_path: []const u8, config: *const Config) ChgrpError!void {
    const dir_path_z = try allocator.dupeZ(u8, dir_path);
    defer allocator.free(dir_path_z);

    const dir = libc.opendir(dir_path_z.ptr) orelse {
        if (!config.quiet) {
            std.debug.print("zchgrp: cannot open directory '{s}'\n", .{dir_path});
        }
        return error.CannotOpenDirectory;
    };
    defer _ = libc.closedir(dir);

    while (true) {
        const entry = libc.readdir(dir) orelse break;

        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);

        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name }) catch {
            return error.OutOfMemory;
        };
        defer allocator.free(full_path);

        chgrpFile(allocator, full_path, config) catch {};
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
    var group_found = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and !group_found) {
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
                } else if (std.mem.eql(u8, arg, "--no-dereference")) {
                    config.no_dereference = true;
                } else {
                    std.debug.print("zchgrp: unrecognized option '{s}'\n", .{arg});
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'R' => config.recursive = true,
                        'v' => config.verbose = true,
                        'c' => config.changes = true,
                        'f' => config.quiet = true,
                        'h' => config.no_dereference = true,
                        else => {
                            std.debug.print("zchgrp: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else if (!group_found) {
            config.group = getGidByName(arg) orelse {
                std.debug.print("zchgrp: invalid group: '{s}'\n", .{arg});
                std.process.exit(1);
            };
            config.group_str = arg;
            group_found = true;
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (!group_found) {
        std.debug.print("zchgrp: missing operand\n", .{});
        std.debug.print("Try 'zchgrp --help' for more information.\n", .{});
        std.process.exit(1);
    }

    if (config.files.items.len == 0) {
        std.debug.print("zchgrp: missing operand after '{s}'\n", .{args[args.len - 1]});
        std.process.exit(1);
    }

    return config;
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [1536]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zchgrp [OPTION]... GROUP FILE...
        \\Change the group of each FILE to GROUP.
        \\
        \\  -c, --changes       like verbose but report only when a change is made
        \\  -f, --silent, --quiet  suppress most error messages
        \\  -v, --verbose       output a diagnostic for every file processed
        \\  -h, --no-dereference   affect symlinks instead of referenced files
        \\  -R, --recursive     operate recursively
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

    var error_occurred = false;
    for (config.files.items) |file| {
        chgrpFile(allocator, file, &config) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
