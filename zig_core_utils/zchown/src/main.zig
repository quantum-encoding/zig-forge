//! zchown - Change file owner and group
//!
//! Compatible with GNU chown:
//! - OWNER: change owner only
//! - OWNER:GROUP: change owner and group
//! - OWNER:: change owner and group to owner's login group
//! - :GROUP: change group only
//! - -R, --recursive: operate recursively
//! - -v, --verbose: output a diagnostic for every file processed
//! - -c, --changes: like verbose but report only when a change is made
//! - -f, --silent, --quiet: suppress most error messages
//! - -h, --no-dereference: affect symlinks instead of referenced files
//! - --preserve-root: refuse to operate recursively on '/' (default with -R)
//! - --no-preserve-root: override --preserve-root
//! - --reference=RFILE: use RFILE's owner and group

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

const CPasswd = extern struct {
    pw_name: [*:0]const u8,
    pw_passwd: [*:0]const u8,
    pw_uid: libc.uid_t,
    pw_gid: libc.gid_t,
    pw_gecos: [*:0]const u8,
    pw_dir: [*:0]const u8,
    pw_shell: [*:0]const u8,
};

extern "c" fn getgrnam(name: [*:0]const u8) ?*CGroup;
extern "c" fn getgrgid(gid: libc.gid_t) ?*CGroup;
extern "c" fn getpwnam(name: [*:0]const u8) ?*CPasswd;
extern "c" fn getpwuid(uid: libc.uid_t) ?*CPasswd;

const Config = struct {
    recursive: bool = false,
    verbose: bool = false,
    changes: bool = false,
    quiet: bool = false,
    no_dereference: bool = false,
    preserve_root: bool = true, // default on with -R
    no_preserve_root: bool = false,
    reference_file: ?[]const u8 = null,
    reference_file_owned: bool = false,
    owner: ?u32 = null,
    group: ?u32 = null,
    owner_str: []const u8 = "",
    group_str: []const u8 = "",
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.reference_file_owned) {
            if (self.reference_file) |r| allocator.free(r);
        }
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

const ChownError = error{
    FileNotFound,
    PermissionDenied,
    CannotOpenDirectory,
    InvalidOwner,
    InvalidGroup,
    OutOfMemory,
};

fn getUidByName(name: []const u8) ?u32 {
    if (name.len == 0) return null;

    // Try parsing as numeric UID first
    var uid: u32 = 0;
    var is_numeric = true;
    for (name) |ch| {
        if (ch < '0' or ch > '9') {
            is_numeric = false;
            break;
        }
        uid = uid * 10 + (ch - '0');
    }
    if (is_numeric) return uid;

    // Look up by name using getpwnam
    var name_buf: [256]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;

    const pw = getpwnam(@ptrCast(&name_buf)) orelse return null;
    return pw.pw_uid;
}

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

fn getUserPrimaryGroup(uid: u32) ?u32 {
    const pw = getpwuid(uid) orelse return null;
    return pw.pw_gid;
}

fn getOwnerName(uid: u32) []const u8 {
    const pw = getpwuid(uid) orelse return "unknown";
    return std.mem.span(pw.pw_name);
}

fn getGroupName(gid: u32) []const u8 {
    const gr = getgrgid(gid) orelse return "unknown";
    return std.mem.span(gr.gr_name);
}

fn isRootPath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |ch| {
        if (ch != '/') return false;
    }
    return true;
}

fn chownFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config) ChownError!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Preserve-root check
    if (config.recursive and !config.no_preserve_root and config.preserve_root) {
        if (isRootPath(path)) {
            std.debug.print("zchown: it is dangerous to operate recursively on '/'\n", .{});
            std.debug.print("zchown: use --no-preserve-root to override this failsafe\n", .{});
            return error.PermissionDenied;
        }
    }

    // Get current owner/group using stat/lstat
    var stat_buf: Stat = undefined;
    const stat_result = if (config.no_dereference)
        lstat(path_z.ptr, &stat_buf)
    else
        stat(path_z.ptr, &stat_buf);

    if (stat_result != 0) {
        if (!config.quiet) {
            std.debug.print("zchown: cannot access '{s}': No such file or directory\n", .{path});
        }
        return error.FileNotFound;
    }

    const current_uid = stat_buf.uid;
    const current_gid = stat_buf.gid;
    const is_dir = (stat_buf.mode & 0o170000) == 0o40000;

    // Determine new owner and group
    const new_uid: u32 = config.owner orelse current_uid;
    const new_gid: u32 = config.group orelse current_gid;

    // Handle recursive BEFORE changing directory
    if (config.recursive and is_dir) {
        chownRecursive(allocator, path, config) catch {};
    }

    // Apply chown
    const chown_result = if (config.no_dereference)
        lchown(path_z.ptr, new_uid, new_gid)
    else
        chown(path_z.ptr, new_uid, new_gid);

    if (chown_result != 0) {
        if (!config.quiet) {
            std.debug.print("zchown: changing ownership of '{s}': Operation not permitted\n", .{path});
        }
        return error.PermissionDenied;
    }

    // Report changes
    const changed = (new_uid != current_uid or new_gid != current_gid);
    if (config.verbose or (config.changes and changed)) {
        const io = Io.Threaded.global_single_threaded.io();
        const stdout = Io.File.stdout();
        var buf: [512]u8 = undefined;
        var writer = stdout.writer(io, &buf);

        if (changed) {
            writer.interface.print("ownership of '{s}' changed from {s}:{s} to {s}:{s}\n", .{
                path,
                getOwnerName(current_uid),
                getGroupName(current_gid),
                getOwnerName(new_uid),
                getGroupName(new_gid),
            }) catch {};
        } else if (config.verbose) {
            writer.interface.print("ownership of '{s}' retained as {s}:{s}\n", .{
                path,
                getOwnerName(current_uid),
                getGroupName(current_gid),
            }) catch {};
        }
        writer.interface.flush() catch {};
    }
}

fn chownRecursive(allocator: std.mem.Allocator, dir_path: []const u8, config: *const Config) ChownError!void {
    const dir_path_z = try allocator.dupeZ(u8, dir_path);
    defer allocator.free(dir_path_z);

    const dir = libc.opendir(dir_path_z.ptr) orelse {
        if (!config.quiet) {
            std.debug.print("zchown: cannot open directory '{s}'\n", .{dir_path});
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

        chownFile(allocator, full_path, config) catch {};
    }
}

fn parseOwnerGroup(allocator: std.mem.Allocator, spec: []const u8, config: *Config) !void {
    _ = allocator;

    // Find the colon separator
    const colon_pos = std.mem.indexOfScalar(u8, spec, ':');

    if (colon_pos) |pos| {
        // Has colon - parse owner:group or owner: or :group
        const owner_part = spec[0..pos];
        const group_part = spec[pos + 1 ..];

        if (owner_part.len > 0) {
            config.owner = getUidByName(owner_part) orelse {
                std.debug.print("zchown: invalid user: '{s}'\n", .{owner_part});
                return error.InvalidOwner;
            };
            config.owner_str = owner_part;

            // Handle owner: (set group to owner's primary group)
            if (group_part.len == 0 and pos < spec.len - 1) {
                // This is "owner:" syntax - use owner's primary group
                // Actually in standard chown, "owner:" means use owner's login group
                // But if it's just "owner" with no colon, we don't change group
            }
        }

        if (group_part.len > 0) {
            config.group = getGidByName(group_part) orelse {
                std.debug.print("zchown: invalid group: '{s}'\n", .{group_part});
                return error.InvalidGroup;
            };
            config.group_str = group_part;
        } else if (owner_part.len > 0 and pos == spec.len - 1) {
            // "owner:" syntax - use owner's login group
            if (config.owner) |uid| {
                config.group = getUserPrimaryGroup(uid);
            }
        }
    } else {
        // No colon - just owner
        config.owner = getUidByName(spec) orelse {
            std.debug.print("zchown: invalid user: '{s}'\n", .{spec});
            return error.InvalidOwner;
        };
        config.owner_str = spec;
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
    var owner_group_found = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and !owner_group_found) {
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
                } else if (std.mem.eql(u8, arg, "--preserve-root")) {
                    config.preserve_root = true;
                    config.no_preserve_root = false;
                } else if (std.mem.eql(u8, arg, "--no-preserve-root")) {
                    config.no_preserve_root = true;
                } else if (std.mem.startsWith(u8, arg, "--reference=")) {
                    config.reference_file = try allocator.dupe(u8, arg["--reference=".len..]);
                    config.reference_file_owned = true;
                } else {
                    std.debug.print("zchown: unrecognized option '{s}'\n", .{arg});
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
                            std.debug.print("zchown: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else if (!owner_group_found and config.reference_file == null) {
            try parseOwnerGroup(allocator, arg, &config);
            owner_group_found = true;
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // When --reference is used, resolve owner/group from the reference file
    if (config.reference_file) |ref_file| {
        const ref_z = try allocator.dupeZ(u8, ref_file);
        defer allocator.free(ref_z);
        var ref_stat: Stat = undefined;
        const ref_result = stat(ref_z.ptr, &ref_stat);
        if (ref_result != 0) {
            std.debug.print("zchown: cannot stat reference file '{s}': No such file or directory\n", .{ref_file});
            std.process.exit(1);
        }
        config.owner = ref_stat.uid;
        config.group = ref_stat.gid;
    } else if (!owner_group_found) {
        std.debug.print("zchown: missing operand\n", .{});
        std.debug.print("Try 'zchown --help' for more information.\n", .{});
        std.process.exit(1);
    }

    if (config.files.items.len == 0) {
        std.debug.print("zchown: missing operand after '{s}'\n", .{args[args.len - 1]});
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
        \\Usage: zchown [OPTION]... [OWNER][:[GROUP]] FILE...
        \\   or: zchown [OPTION]... --reference=RFILE FILE...
        \\Change the owner and/or group of each FILE.
        \\
        \\  -c, --changes       like verbose but report only when a change is made
        \\  -f, --silent, --quiet  suppress most error messages
        \\  -v, --verbose       output a diagnostic for every file processed
        \\  -h, --no-dereference   affect symlinks instead of referenced files
        \\  -R, --recursive     operate recursively
        \\      --preserve-root    fail to operate recursively on '/' (default)
        \\      --no-preserve-root do not treat '/' specially
        \\      --reference=RFILE  use RFILE's owner and group
        \\      --help          display this help and exit
        \\      --version       output version information and exit
        \\
        \\Owner/group format:
        \\  OWNER          change owner only
        \\  OWNER:GROUP    change owner and group
        \\  OWNER:         change owner and group to owner's login group
        \\  :GROUP         change group only
        \\
        \\Examples:
        \\  zchown root file       Change owner to root
        \\  zchown root:staff file Change owner to root and group to staff
        \\  zchown :staff file     Change group to staff only
        \\  zchown -R user dir     Recursively change owner
        \\
        \\zchown - High-performance chown utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zchown 0.1.0\n") catch {};
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
        chownFile(allocator, file, &config) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
