//! zlink - Create links between files
//!
//! A Zig implementation of ln.
//! Creates hard or symbolic links.
//!
//! Usage: zlink [OPTIONS] TARGET LINK_NAME
//!        zlink [OPTIONS] TARGET... DIRECTORY

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Options
    var symbolic = false;
    var force = false;
    var verbose = false;
    var no_dereference = false;
    var relative = false;
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer targets.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            writeStdout("zlink {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--symbolic")) {
            symbolic = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-dereference")) {
            no_dereference = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--relative")) {
            relative = true;
            symbolic = true; // -r implies -s
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Combined short options
            for (arg[1..]) |ch| {
                switch (ch) {
                    's' => symbolic = true,
                    'f' => force = true,
                    'v' => verbose = true,
                    'n' => no_dereference = true,
                    'r' => {
                        relative = true;
                        symbolic = true;
                    },
                    else => {
                        writeStderr("zlink: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            try targets.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            // Rest are targets
            i += 1;
            while (i < args.len) : (i += 1) {
                try targets.append(allocator, args[i]);
            }
        } else {
            writeStderr("zlink: invalid option: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    if (targets.items.len < 2) {
        writeStderr("zlink: missing file operand\n", .{});
        writeStderr("Try 'zlink --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Last argument is destination
    const dest = targets.items[targets.items.len - 1];
    const sources = targets.items[0 .. targets.items.len - 1];

    // Check if dest is a directory
    const dest_is_dir = isDirectory(dest);

    if (sources.len > 1 and !dest_is_dir) {
        writeStderr("zlink: target '{s}' is not a directory\n", .{dest});
        std.process.exit(1);
    }

    var errors: u32 = 0;

    for (sources) |source| {
        var link_path_buf: [4096]u8 = undefined;
        const link_path: []const u8 = if (dest_is_dir) blk: {
            // Append source basename to dest directory
            const basename = std.fs.path.basename(source);
            const len = std.fmt.bufPrint(&link_path_buf, "{s}/{s}", .{ dest, basename }) catch {
                writeStderr("zlink: path too long\n", .{});
                errors += 1;
                continue;
            };
            break :blk len;
        } else dest;

        // Create null-terminated strings
        var source_z: [4097]u8 = undefined;
        var link_z: [4097]u8 = undefined;

        if (source.len >= source_z.len or link_path.len >= link_z.len) {
            writeStderr("zlink: path too long\n", .{});
            errors += 1;
            continue;
        }

        @memcpy(source_z[0..source.len], source);
        source_z[source.len] = 0;
        @memcpy(link_z[0..link_path.len], link_path);
        link_z[link_path.len] = 0;

        // Remove existing if force
        if (force) {
            _ = unlink(@ptrCast(&link_z));
        }

        // Create the link
        const result = if (symbolic)
            symlink(@ptrCast(&source_z), @ptrCast(&link_z))
        else
            link(@ptrCast(&source_z), @ptrCast(&link_z));

        if (result != 0) {
            const errno = std.posix.errno(result);
            const err_msg: []const u8 = switch (errno) {
                .EXIST => "File exists",
                .NOENT => "No such file or directory",
                .ACCES => "Permission denied",
                .PERM => "Operation not permitted",
                .XDEV => "Invalid cross-device link",
                .LOOP => "Too many symbolic links",
                .NAMETOOLONG => "File name too long",
                .NOSPC => "No space left on device",
                .ROFS => "Read-only file system",
                else => "Unknown error",
            };
            writeStderr("zlink: failed to create {s} link '{s}' -> '{s}': {s}\n", .{
                if (symbolic) "symbolic" else "hard",
                link_path,
                source,
                err_msg,
            });
            errors += 1;
        } else if (verbose) {
            writeStdout("'{s}' -> '{s}'\n", .{ link_path, source });
        }
    }

    if (errors > 0) {
        std.process.exit(1);
    }
}

const stat_t = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atime: i64,
    st_atime_nsec: i64,
    st_mtime: i64,
    st_mtime_nsec: i64,
    st_ctime: i64,
    st_ctime_nsec: i64,
    __unused: [3]i64,
};

extern "c" fn stat(path: [*:0]const u8, buf: *stat_t) c_int;

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;

fn isDirectory(path: []const u8) bool {
    var path_z: [4097]u8 = undefined;
    if (path.len >= path_z.len) return false;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var stat_buf: stat_t = undefined;
    const result = stat(@ptrCast(&path_z), &stat_buf);

    if (result != 0) return false;
    return (stat_buf.st_mode & S_IFMT) == S_IFDIR;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zlink [OPTIONS] TARGET LINK_NAME
        \\       zlink [OPTIONS] TARGET... DIRECTORY
        \\
        \\Create links between files.
        \\
        \\Options:
        \\  -s, --symbolic       create symbolic links instead of hard links
        \\  -f, --force          remove existing destination files
        \\  -v, --verbose        print name of each linked file
        \\  -n, --no-dereference treat destination as normal file if symbolic link
        \\  -r, --relative       create relative symbolic links
        \\  -h, --help           display this help
        \\  -V, --version        display version
        \\
        \\By default, zlink creates hard links.
        \\Use -s for symbolic (soft) links.
        \\
        \\Examples:
        \\  zlink file.txt link.txt           Create hard link
        \\  zlink -s file.txt link.txt        Create symbolic link
        \\  zlink -sf file.txt link.txt       Force create symbolic link
        \\  zlink -sv file1 file2 dir/        Link multiple files to directory
        \\  zlink -s /path/to/file link       Absolute symlink
        \\  zlink -rs ../file link            Relative symlink
        \\
    , .{});
}
