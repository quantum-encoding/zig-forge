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

// fd-relative (`*at`) syscalls — these are the TOCTOU- and symlink-safe
// primitives the recursive traversal is built on. Resolving every operation
// against a stable directory fd (rather than re-parsing a path string) means a
// concurrent attacker cannot swap a path component for a symlink between our
// stat and our chown, and AT_SYMLINK_NOFOLLOW means we never dereference a
// symlink encountered inside the tree (GNU's default `-P` semantics).
extern "c" fn openat(dirfd: c_int, path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn fstatat(dirfd: c_int, path: [*:0]const u8, buf: *Stat, flags: c_int) c_int;
extern "c" fn fchownat(dirfd: c_int, path: [*:0]const u8, owner: libc.uid_t, group: libc.gid_t, flags: c_int) c_int;
extern "c" fn fdopendir(fd: c_int) ?*libc.DIR;
extern "c" fn dirfd(dirp: *libc.DIR) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

// *at flag / open flag constants (per-OS).
const AT_FDCWD: c_int = switch (builtin.os.tag) {
    .linux => -100,
    else => -2,
};
const AT_SYMLINK_NOFOLLOW: c_int = switch (builtin.os.tag) {
    .linux => 0x100,
    else => 0x0020,
};
const O_RDONLY: c_int = 0;
const O_DIRECTORY: c_int = switch (builtin.os.tag) {
    .linux => 0o200000,
    else => 0x100000,
};
const O_NOFOLLOW: c_int = switch (builtin.os.tag) {
    .linux => 0o400000,
    else => 0x0100,
};
const O_CLOEXEC: c_int = switch (builtin.os.tag) {
    .linux => 0o2000000,
    else => 0x1000000,
};

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;

fn isDirMode(mode: u32) bool {
    return (mode & S_IFMT) == S_IFDIR;
}
fn isLnkMode(mode: u32) bool {
    return (mode & S_IFMT) == S_IFLNK;
}

/// The current errno, decoded to its libc message (GNU reports the real
/// strerror(3) text rather than a hardcoded string).
fn errnoString() []const u8 {
    return std.mem.span(strerror(std.c._errno().*));
}

/// How recursive traversal treats symbolic links to directories.
///  - P (default): never traverse, operate on the link itself (`chown -R` safe default)
///  - H: traverse only a symlink given directly on the command line
///  - L: traverse every symlink to a directory encountered
const Traverse = enum { P, H, L };

// Guards the native recursion against pathologically deep / hostile trees
// (the low-severity unbounded-recursion finding). Deep enough for any real
// filesystem, bounded against a fabricated one designed to blow the stack.
const MAX_RECURSION_DEPTH: u32 = 4096;

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
    traverse: Traverse = .P,
    preserve_root: bool = true, // default on with -R
    no_preserve_root: bool = false,
    reference_file: ?[]const u8 = null,
    reference_file_owned: bool = false,
    owner: ?u32 = null,
    group: ?u32 = null,
    owner_str: []const u8 = "",
    group_str: []const u8 = "",
    // Whether the OWNER / GROUP component was named in the spec — GNU's verbose
    // output shape depends on this (owner-only prints just the owner name).
    owner_specified: bool = false,
    group_specified: bool = false,
    // --from=CURRENT_OWNER:CURRENT_GROUP conditional change.
    from_owner: ?u32 = null,
    from_group: ?u32 = null,
    from_owner_set: bool = false,
    from_group_set: bool = false,
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

    // An all-digit spec is a numeric UID. Parse with an overflow guard: a value
    // that does not fit in uid_t (u32) is not a valid id, so we return null and
    // the caller reports "invalid user" (GNU behaviour) instead of overflowing.
    var all_digits = true;
    for (name) |ch| {
        if (ch < '0' or ch > '9') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) {
        return std.fmt.parseInt(u32, name, 10) catch return null;
    }

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

    // All-digit spec is a numeric GID; parse with an overflow guard (see
    // getUidByName). Over-range => null => caller reports "invalid group".
    var all_digits = true;
    for (name) |ch| {
        if (ch < '0' or ch > '9') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) {
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

/// stat a name relative to `dfd` (use AT_FDCWD for absolute/cwd-relative paths).
/// `nofollow` selects lstat vs stat semantics via AT_SYMLINK_NOFOLLOW.
fn statAt(dfd: c_int, name_z: [*:0]const u8, nofollow: bool) ?Stat {
    var st: Stat = undefined;
    const flags: c_int = if (nofollow) AT_SYMLINK_NOFOLLOW else 0;
    if (fstatat(dfd, name_z, &st, flags) != 0) return null;
    return st;
}

/// Emit GNU-shaped verbose / --changes diagnostics on stdout.
///
/// GNU's message shape depends on the SPEC, not on what actually differs:
///   - the OLD side always shows the owner, and shows ":group" iff a group was
///     specified in the spec;
///   - the NEW side shows the owner iff an owner was specified and ":group" iff
///     a group was specified (so `:grp` prints a leading colon with no owner).
/// Matches: `changed ownership of 'F' from director:wheel to :everyone`,
///          `ownership of 'F' retained as director` (owner-only spec), etc.
fn reportChange(
    path: []const u8,
    cur_uid: u32,
    cur_gid: u32,
    new_uid: u32,
    new_gid: u32,
    changed: bool,
    config: *const Config,
) void {
    if (!(config.verbose or (config.changes and changed))) return;

    const io = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = stdout.writer(io, &buf);
    const w = &writer.interface;

    if (changed) {
        w.print("changed ownership of '{s}' from ", .{path}) catch {};
        writeSpec(w, cur_uid, cur_gid, true, config.group_specified);
        w.writeAll(" to ") catch {};
        writeSpec(w, new_uid, new_gid, config.owner_specified, config.group_specified);
        w.writeAll("\n") catch {};
    } else if (config.verbose) {
        w.print("ownership of '{s}' retained as ", .{path}) catch {};
        writeSpec(w, cur_uid, cur_gid, true, config.group_specified);
        w.writeAll("\n") catch {};
    }
    w.flush() catch {};
}

fn writeSpec(w: anytype, uid: u32, gid: u32, show_owner: bool, show_group: bool) void {
    if (show_owner) w.print("{s}", .{getOwnerName(uid)}) catch {};
    if (show_group) w.print(":{s}", .{getGroupName(gid)}) catch {};
}

/// Apply the ownership change to a single entry named `name_z` relative to
/// `dfd`. `nofollow` picks fchownat's AT_SYMLINK_NOFOLLOW (operate on the link
/// itself) vs. following the referent. `path` is only for diagnostics.
fn applyChown(
    dfd: c_int,
    name_z: [*:0]const u8,
    path: []const u8,
    cur_uid: u32,
    cur_gid: u32,
    nofollow: bool,
    config: *const Config,
) ChownError!void {
    // --from=OWNER:GROUP: only change entries whose current owner/group match
    // every specified component; otherwise retain (no syscall, but -v reports
    // "retained as", matching GNU).
    var matches = true;
    if (config.from_owner_set) {
        if (cur_uid != (config.from_owner orelse cur_uid)) matches = false;
    }
    if (config.from_group_set) {
        if (cur_gid != (config.from_group orelse cur_gid)) matches = false;
    }

    const new_uid: u32 = if (matches) (config.owner orelse cur_uid) else cur_uid;
    const new_gid: u32 = if (matches) (config.group orelse cur_gid) else cur_gid;

    const changed = (new_uid != cur_uid or new_gid != cur_gid);
    if (changed) {
        const flags: c_int = if (nofollow) AT_SYMLINK_NOFOLLOW else 0;
        if (fchownat(dfd, name_z, new_uid, new_gid, flags) != 0) {
            if (!config.quiet) {
                std.debug.print("zchown: changing ownership of '{s}': {s}\n", .{ path, errnoString() });
            }
            return error.PermissionDenied;
        }
    }

    reportChange(path, cur_uid, cur_gid, new_uid, new_gid, changed, config);
}

/// Non-recursive single-operand path. Preserves the historical (GNU-matching)
/// behaviour of dereferencing a command-line symlink unless -h/--no-dereference.
fn chownOne(allocator: std.mem.Allocator, path: []const u8, config: *const Config) ChownError!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const st = statAt(AT_FDCWD, path_z.ptr, config.no_dereference) orelse {
        if (!config.quiet) {
            std.debug.print("zchown: cannot access '{s}': {s}\n", .{ path, errnoString() });
        }
        return error.FileNotFound;
    };

    try applyChown(AT_FDCWD, path_z.ptr, path, st.uid, st.gid, config.no_dereference, config);
}

/// Recursively descend `fd` (an open O_DIRECTORY fd we take ownership of and
/// close), chowning every entry. All operations are fd-relative (openat /
/// fstatat / fchownat) so the kernel resolves against a stable directory
/// handle — no path-string re-resolution, no TOCTOU window, and symlinks are
/// never dereferenced under the default -P semantics.
fn walkFd(
    allocator: std.mem.Allocator,
    fd: c_int,
    config: *const Config,
    dir_path: []const u8,
    depth: u32,
) void {
    // fdopendir takes ownership of `fd`; closedir closes it. dirfd() gives us
    // back the same fd for the *at calls while the stream is open.
    const dirp = fdopendir(fd) orelse {
        _ = close(fd);
        return;
    };
    defer _ = libc.closedir(dirp);
    const afd = dirfd(dirp);

    const follow = (config.traverse == .L);

    while (true) {
        const entry = libc.readdir(dirp) orelse break;
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        // Sentinel-terminated copy of the entry name for the *at calls.
        const name_z = allocator.dupeZ(u8, name) catch return;
        defer allocator.free(name_z);

        // Classify without following (we need to know if it's a symlink).
        const lst = statAt(afd, name_z.ptr, true) orelse continue;
        const is_link = isLnkMode(lst.mode);

        const child_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name }) catch return;
        defer allocator.free(child_path);

        // Ownership to report/apply against: under -L a symlink's referent, else
        // the entry itself.
        const st = if (is_link and follow)
            (statAt(afd, name_z.ptr, false) orelse lst)
        else
            lst;

        // GNU processes recursively in POST-ORDER: a directory's contents are
        // chowned before the directory itself (so `chown -Rv` reports children
        // first, parent last). Descend first, then chown this entry.
        const descend = if (is_link) (follow and isDirMode(st.mode)) else isDirMode(lst.mode);
        if (descend) {
            if (depth >= MAX_RECURSION_DEPTH) {
                if (!config.quiet) {
                    std.debug.print("zchown: maximum recursion depth exceeded at '{s}'\n", .{child_path});
                }
                continue;
            }
            // O_NOFOLLOW on the descent fd guarantees we never open through a
            // symlink under -P/-H; under -L we allow following.
            const open_flags: c_int = O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                (if (follow) @as(c_int, 0) else O_NOFOLLOW);
            const cfd = openat(afd, name_z.ptr, open_flags, 0);
            if (cfd >= 0) {
                walkFd(allocator, cfd, config, child_path, depth + 1);
            }
        }

        // Under -P (default) never dereference; under -L follow the referent.
        const nofollow = !(follow);
        applyChown(afd, name_z.ptr, child_path, st.uid, st.gid, nofollow, config) catch {};
    }
}

/// Recursive operand entry point (`-R`). Handles the command-line operand's
/// symlink/traversal semantics, then descends with `walkFd`.
fn chownRecursiveEntry(allocator: std.mem.Allocator, path: []const u8, config: *const Config) ChownError!void {
    // Preserve-root only applies with -R.
    if (!config.no_preserve_root and config.preserve_root and isRootPath(path)) {
        std.debug.print("zchown: it is dangerous to operate recursively on '/'\n", .{});
        std.debug.print("zchown: use --no-preserve-root to override this failsafe\n", .{});
        return error.PermissionDenied;
    }

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Classify the operand without following (lstat semantics).
    const lst = statAt(AT_FDCWD, path_z.ptr, true) orelse {
        if (!config.quiet) {
            std.debug.print("zchown: cannot access '{s}': {s}\n", .{ path, errnoString() });
        }
        return error.FileNotFound;
    };

    const operand_is_link = isLnkMode(lst.mode);
    // A command-line symlink is traversed under -L and -H (but not -P).
    const follow_operand = operand_is_link and (config.traverse == .L or config.traverse == .H);

    if (operand_is_link and !follow_operand) {
        // -P: operate on the link itself, do not descend. This is the critical
        // symlink-attack-safe default.
        try applyChown(AT_FDCWD, path_z.ptr, path, lst.uid, lst.gid, true, config);
        return;
    }

    if (follow_operand) {
        const rst = statAt(AT_FDCWD, path_z.ptr, false) orelse {
            if (!config.quiet) {
                std.debug.print("zchown: cannot access '{s}': {s}\n", .{ path, errnoString() });
            }
            return error.FileNotFound;
        };
        // Post-order: descend into the target directory first, chown it last.
        if (isDirMode(rst.mode)) {
            const fd = openat(AT_FDCWD, path_z.ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
            if (fd >= 0) walkFd(allocator, fd, config, path, 1);
        }
        try applyChown(AT_FDCWD, path_z.ptr, path, rst.uid, rst.gid, false, config);
        return;
    }

    // Real file or directory operand. Post-order: contents first, operand last.
    const nofollow = (config.traverse != .L);
    if (isDirMode(lst.mode)) {
        const fd = openat(AT_FDCWD, path_z.ptr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
        if (fd >= 0) walkFd(allocator, fd, config, path, 1);
    }
    try applyChown(AT_FDCWD, path_z.ptr, path, lst.uid, lst.gid, nofollow, config);
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
            config.owner_specified = true;
        }

        if (group_part.len > 0) {
            config.group = getGidByName(group_part) orelse {
                std.debug.print("zchown: invalid group: '{s}'\n", .{group_part});
                return error.InvalidGroup;
            };
            config.group_str = group_part;
            config.group_specified = true;
        } else if (owner_part.len > 0 and pos == spec.len - 1) {
            // "owner:" syntax - change group to the owner's login group.
            if (config.owner) |uid| {
                config.group = getUserPrimaryGroup(uid);
                config.group_specified = true;
            }
        }
    } else {
        // No colon - just owner
        config.owner = getUidByName(spec) orelse {
            std.debug.print("zchown: invalid user: '{s}'\n", .{spec});
            return error.InvalidOwner;
        };
        config.owner_str = spec;
        config.owner_specified = true;
    }
}

/// Parse a --from=CURRENT_OWNER:CURRENT_GROUP spec into the config's
/// conditional-match fields. Accepts OWNER, OWNER:GROUP, or :GROUP.
fn parseFrom(spec: []const u8, config: *Config) !void {
    const colon_pos = std.mem.indexOfScalar(u8, spec, ':');
    if (colon_pos) |pos| {
        const owner_part = spec[0..pos];
        const group_part = spec[pos + 1 ..];
        if (owner_part.len > 0) {
            config.from_owner = getUidByName(owner_part) orelse {
                std.debug.print("zchown: invalid user: '{s}'\n", .{owner_part});
                return error.InvalidOwner;
            };
            config.from_owner_set = true;
        }
        if (group_part.len > 0) {
            config.from_group = getGidByName(group_part) orelse {
                std.debug.print("zchown: invalid group: '{s}'\n", .{group_part});
                return error.InvalidGroup;
            };
            config.from_group_set = true;
        }
    } else if (spec.len > 0) {
        config.from_owner = getUidByName(spec) orelse {
            std.debug.print("zchown: invalid user: '{s}'\n", .{spec});
            return error.InvalidOwner;
        };
        config.from_owner_set = true;
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
    // GNU permutes options and operands: options are recognized wherever they
    // appear (before "--"), not just before the owner/group operand.
    var seen_dashdash = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // "--" terminates option processing; every following arg is an operand.
        if (!seen_dashdash and std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
            continue;
        }

        const is_option = !seen_dashdash and arg.len > 1 and arg[0] == '-';
        if (is_option) {
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
                } else if (std.mem.eql(u8, arg, "--dereference")) {
                    config.no_dereference = false;
                } else if (std.mem.eql(u8, arg, "--preserve-root")) {
                    config.preserve_root = true;
                    config.no_preserve_root = false;
                } else if (std.mem.eql(u8, arg, "--no-preserve-root")) {
                    config.no_preserve_root = true;
                } else if (std.mem.startsWith(u8, arg, "--reference=")) {
                    config.reference_file = try allocator.dupe(u8, arg["--reference=".len..]);
                    config.reference_file_owned = true;
                } else if (std.mem.startsWith(u8, arg, "--from=")) {
                    try parseFrom(arg["--from=".len..], &config);
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
                        // Recursion traversal control (GNU -H/-L/-P).
                        'H' => config.traverse = .H,
                        'L' => config.traverse = .L,
                        'P' => config.traverse = .P,
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
            std.debug.print("zchown: cannot stat reference file '{s}': {s}\n", .{ ref_file, errnoString() });
            std.process.exit(1);
        }
        config.owner = ref_stat.uid;
        config.group = ref_stat.gid;
        // --reference sets both owner and group; verbose output shows both.
        config.owner_specified = true;
        config.group_specified = true;
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
        \\      --dereference   affect the referent of each symlink (default)
        \\      --from=CURRENT_OWNER:CURRENT_GROUP  change only if current matches
        \\  -R, --recursive     operate recursively
        \\  -H                  with -R, follow a command-line symlink to a directory
        \\  -L                  with -R, follow every symlink to a directory
        \\  -P                  with -R, do not follow symlinks (default)
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
        const result = if (config.recursive)
            chownRecursiveEntry(allocator, file, &config)
        else
            chownOne(allocator, file, &config);
        result catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
