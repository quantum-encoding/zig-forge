//! ztar - High-performance tar archive utility
//!
//! Create, extract, and list tar archives with optional compression.
//!
//! Usage: ztar [OPTION]... [FILE]...

const std = @import("std");
const libc = std.c;
const flate = std.compress.flate;

extern "c" fn chdir(path: [*:0]const u8) c_int;

const VERSION = "1.1.0"; // Added native gzip support

// USTAR tar header structure (512 bytes)
const TarHeader = extern struct {
    name: [100]u8,      // File name
    mode: [8]u8,        // File mode (octal)
    uid: [8]u8,         // Owner user ID (octal)
    gid: [8]u8,         // Owner group ID (octal)
    size: [12]u8,       // File size in bytes (octal)
    mtime: [12]u8,      // Modification time (octal)
    checksum: [8]u8,    // Header checksum
    typeflag: u8,       // Type flag
    linkname: [100]u8,  // Name of linked file
    magic: [6]u8,       // USTAR magic "ustar\0"
    version: [2]u8,     // USTAR version "00"
    uname: [32]u8,      // Owner user name
    gname: [32]u8,      // Owner group name
    devmajor: [8]u8,    // Device major number
    devminor: [8]u8,    // Device minor number
    prefix: [155]u8,    // Prefix for long names
    padding: [12]u8,    // Padding to 512 bytes

    const BLOCK_SIZE = 512;
    const MAGIC = "ustar\x00";
    const VERSION_STR = "00";

    // Type flags
    const TYPE_REGULAR = '0';
    const TYPE_REGULAR_ALT = 0;
    const TYPE_HARDLINK = '1';
    const TYPE_SYMLINK = '2';
    const TYPE_CHARDEV = '3';
    const TYPE_BLOCKDEV = '4';
    const TYPE_DIRECTORY = '5';
    const TYPE_FIFO = '6';

    fn init() TarHeader {
        var header: TarHeader = undefined;
        @memset(@as([*]u8, @ptrCast(&header))[0..512], 0);
        @memcpy(header.magic[0..6], MAGIC);
        @memcpy(header.version[0..2], VERSION_STR);
        return header;
    }

    fn setName(self: *TarHeader, path: []const u8) void {
        if (path.len <= 100) {
            @memcpy(self.name[0..path.len], path);
            return;
        }
        // USTAR name/prefix split (POSIX.1-1988): store the trailing
        // component(s) in `name` (<= 100 bytes) and the leading directory
        // portion in `prefix` (<= 155 bytes), split on a '/' boundary. Prefer
        // the split with the longest possible `name` (smallest prefix) so the
        // widest range of paths fits. The two are rejoined as prefix + "/" +
        // name on read.
        var split: ?usize = null;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '/') {
                const suffix_len = path.len - i - 1;
                if (suffix_len > 0 and suffix_len <= 100 and i <= 155) {
                    split = i;
                    break;
                }
            }
        }
        if (split) |s| {
            @memcpy(self.prefix[0..s], path[0..s]);
            const suffix = path[s + 1 ..];
            @memcpy(self.name[0..suffix.len], suffix);
        } else {
            // No usable split point (single component > 100 bytes or prefix
            // > 155): fall back to a best-effort truncation of the tail. GNU
            // 'L' long-name records would be needed for full fidelity here.
            const len = @min(path.len, 100);
            @memcpy(self.name[0..len], path[0..len]);
        }
    }

    /// Reconstruct the full member path, joining the USTAR `prefix` field
    /// (paths split across name+prefix for lengths > 100) with `name`. Returns
    /// a slice into `buf`.
    fn getName(self: *const TarHeader, buf: *[257]u8) []const u8 {
        var name_len: usize = 0;
        while (name_len < 100 and self.name[name_len] != 0) : (name_len += 1) {}

        // USTAR prefix only applies when the magic says "ustar". Old-style
        // (v7) tar headers have arbitrary bytes there and must be ignored.
        const is_ustar = std.mem.eql(u8, self.magic[0..5], "ustar");
        var prefix_len: usize = 0;
        if (is_ustar) {
            while (prefix_len < 155 and self.prefix[prefix_len] != 0) : (prefix_len += 1) {}
        }

        if (prefix_len == 0) {
            @memcpy(buf[0..name_len], self.name[0..name_len]);
            return buf[0..name_len];
        }
        @memcpy(buf[0..prefix_len], self.prefix[0..prefix_len]);
        buf[prefix_len] = '/';
        @memcpy(buf[prefix_len + 1 ..][0..name_len], self.name[0..name_len]);
        return buf[0 .. prefix_len + 1 + name_len];
    }

    fn setOctal(buf: []u8, value: u64) void {
        var v = value;
        var i: usize = buf.len - 1;
        buf[i] = 0; // Null terminator
        if (i > 0) {
            i -= 1;
            while (i > 0) : (i -= 1) {
                buf[i] = '0' + @as(u8, @intCast(v & 7));
                v >>= 3;
            }
            buf[0] = '0' + @as(u8, @intCast(v & 7));
        }
    }

    fn getOctal(buf: []const u8) u64 {
        var result: u64 = 0;
        for (buf) |c| {
            if (c == 0 or c == ' ') break;
            if (c >= '0' and c <= '7') {
                result = (result << 3) | (c - '0');
            }
        }
        return result;
    }

    fn setMode(self: *TarHeader, mode: u32) void {
        setOctal(&self.mode, mode);
    }

    fn getMode(self: *const TarHeader) u32 {
        return @intCast(getOctal(&self.mode));
    }

    fn setSize(self: *TarHeader, size: u64) void {
        setOctal(&self.size, size);
    }

    fn getSize(self: *const TarHeader) u64 {
        return getOctal(&self.size);
    }

    fn setMtime(self: *TarHeader, mtime: i64) void {
        // Clamp negative timestamps (pre-1970 or garbage) to 0 rather than
        // panicking in @intCast on a negative value.
        setOctal(&self.mtime, if (mtime < 0) 0 else @intCast(mtime));
    }

    fn getMtime(self: *const TarHeader) i64 {
        return @intCast(getOctal(&self.mtime));
    }

    fn setUid(self: *TarHeader, uid: u32) void {
        setOctal(&self.uid, uid);
    }

    fn setGid(self: *TarHeader, gid: u32) void {
        setOctal(&self.gid, gid);
    }

    fn setUname(self: *TarHeader, name: []const u8) void {
        const len = @min(name.len, 32);
        @memcpy(self.uname[0..len], name[0..len]);
    }

    fn setGname(self: *TarHeader, name: []const u8) void {
        const len = @min(name.len, 32);
        @memcpy(self.gname[0..len], name[0..len]);
    }

    fn computeChecksum(self: *TarHeader) void {
        // Set checksum field to spaces first
        @memset(&self.checksum, ' ');

        // Sum all bytes
        var sum: u32 = 0;
        const bytes = @as([*]const u8, @ptrCast(self))[0..512];
        for (bytes) |b| {
            sum += b;
        }

        // Write checksum as octal with trailing space and null
        setOctal(self.checksum[0..7], sum);
        self.checksum[7] = ' ';
    }

    fn verifyChecksum(self: *const TarHeader) bool {
        // Save and clear checksum field
        var saved_checksum: [8]u8 = undefined;
        @memcpy(&saved_checksum, &self.checksum);

        // Calculate checksum with spaces in checksum field
        var sum: u32 = 0;
        const bytes = @as([*]const u8, @ptrCast(self))[0..512];
        for (bytes, 0..) |b, i| {
            if (i >= 148 and i < 156) {
                sum += ' '; // Checksum field treated as spaces
            } else {
                sum += b;
            }
        }

        const stored = getOctal(&saved_checksum);
        return sum == stored;
    }

    fn isZeroBlock(self: *const TarHeader) bool {
        const bytes = @as([*]const u8, @ptrCast(self))[0..512];
        for (bytes) |b| {
            if (b != 0) return false;
        }
        return true;
    }
};

const Compression = enum {
    none,
    gzip,
    bzip2,
    xz,
    zstd,

    fn getExtension(self: Compression) []const u8 {
        return switch (self) {
            .none => "",
            .gzip => ".gz",
            .bzip2 => ".bz2",
            .xz => ".xz",
            .zstd => ".zst",
        };
    }

    fn getCompressCmd(self: Compression) ?[]const u8 {
        return switch (self) {
            .none => null,
            .gzip => "gzip",
            .bzip2 => "bzip2",
            .xz => "xz",
            .zstd => "zstd",
        };
    }

    fn getDecompressCmd(self: Compression) ?[]const u8 {
        return switch (self) {
            .none => null,
            .gzip => "gunzip",
            .bzip2 => "bunzip2",
            .xz => "unxz",
            .zstd => "unzstd",
        };
    }

    fn detectFromFilename(name: []const u8) Compression {
        if (std.mem.endsWith(u8, name, ".tar.gz") or std.mem.endsWith(u8, name, ".tgz")) {
            return .gzip;
        } else if (std.mem.endsWith(u8, name, ".tar.bz2") or std.mem.endsWith(u8, name, ".tbz2")) {
            return .bzip2;
        } else if (std.mem.endsWith(u8, name, ".tar.xz") or std.mem.endsWith(u8, name, ".txz")) {
            return .xz;
        } else if (std.mem.endsWith(u8, name, ".tar.zst") or std.mem.endsWith(u8, name, ".tzst")) {
            return .zstd;
        }
        return .none;
    }
};

const Mode = enum {
    none,
    create,
    extract,
    list,
};

const Config = struct {
    mode: Mode = .none,
    archive_file: ?[]const u8 = null,
    compression: Compression = .none,
    verbose: bool = false,
    preserve_permissions: bool = false,
    keep_old_files: bool = false,
    directory: ?[]const u8 = null,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
    auto_compress: bool = true,
};

// Gzip magic bytes
const GZIP_MAGIC: [2]u8 = .{ 0x1f, 0x8b };

/// Compress data using gzip format (native Zig implementation)
fn compressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Create allocating writer with initial capacity
    var out: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    errdefer out.deinit();

    // Create compression buffer
    var comp_buffer: [flate.max_window_len]u8 = undefined;

    // Initialize compressor with gzip container
    var comp = try flate.Compress.init(&out.writer, &comp_buffer, .gzip, flate.Compress.Options.level_6);

    // Write input data through compressor
    try comp.writer.writeAll(data);

    // Finalize the deflate stream: emit the final block and the gzip trailer
    // (CRC32 + ISIZE). writer.flush() only byte-aligns buffered bytes and does
    // NOT write the terminating block/footer, which produced a truncated .gz
    // that no tool (including ztar itself) could decompress. finish() does.
    try comp.finish();

    // Return owned slice
    return try out.toOwnedSlice();
}

/// Decompress gzip data (native Zig implementation)
fn decompressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len < 18) return error.InvalidGzipData;

    // Verify gzip magic
    if (data[0] != GZIP_MAGIC[0] or data[1] != GZIP_MAGIC[1]) {
        return error.NotGzipFormat;
    }

    // Create allocating writer for output
    var out: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    errdefer out.deinit();

    // Create fixed reader from input data
    var input: std.Io.Reader = .fixed(data);

    // Create decompression buffer
    var decomp_buffer: [flate.max_window_len]u8 = undefined;

    // Initialize decompressor with gzip container
    var decomp = flate.Decompress.init(&input, .gzip, &decomp_buffer);

    // Stream all decompressed data to output
    _ = try decomp.reader.streamRemaining(&out.writer);

    // Return owned slice
    return try out.toOwnedSlice();
}

/// Check if data starts with gzip magic bytes
fn isGzipData(data: []const u8) bool {
    return data.len >= 2 and data[0] == GZIP_MAGIC[0] and data[1] == GZIP_MAGIC[1];
}

/// True if any component of `path` is exactly "..". Such members can escape
/// the extraction directory and MUST be refused (GNU tar / libarchive refuse
/// them by default). `path` is expected to already have had leading '/'
/// stripped; an absolute path is also unsafe.
fn pathHasParentRef(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return true;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

/// True if a symlink target is unsafe: absolute (escapes the destination
/// root) or contains a ".." component (can traverse upward out of it).
fn linkTargetUnsafe(target: []const u8) bool {
    if (target.len == 0) return false;
    if (target[0] == '/') return true;
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

/// gzip is the only codec ztar implements natively. If the user requested
/// bzip2/xz/zstd, fail loudly instead of silently producing (or trying to
/// read) a mislabeled uncompressed tar. Returns true if the operation should
/// abort.
fn rejectUnsupportedCompression(c: Compression) bool {
    switch (c) {
        .none, .gzip => return false,
        .bzip2, .xz, .zstd => {
            const name = switch (c) {
                .bzip2 => "bzip2",
                .xz => "xz",
                .zstd => "zstd",
                else => unreachable,
            };
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "ztar: {s} compression is not supported (only gzip); refusing rather than writing a mislabeled uncompressed archive\n", .{name}) catch "ztar: compression not supported\n";
            writeStderr(msg);
            return true;
        },
    }
}

// C functions
extern "c" fn getuid() u32;
extern "c" fn getgid() u32;
extern "c" fn getpwuid(uid: u32) ?*const Passwd;
extern "c" fn getgrgid(gid: u32) ?*const Group;
extern "c" fn chown(path: [*:0]const u8, owner: u32, group: u32) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: u32) c_int;
extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
extern "c" fn mkdir(path: [*:0]const u8, mode: u32) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn closedir(dir: *anyopaque) c_int;
extern "c" fn readdir(dir: *anyopaque) ?*Dirent;

// Per-target open() flags. These are computed from std.c.O (a per-OS packed
// struct) rather than hardcoded Linux octal values — the previous hardcoded
// values (O_CREAT = 0o100, O_TRUNC = 0o1000) are Linux-specific and mean
// entirely different things on Darwin (0o100 == O_ASYNC, 0o200 == O_CREAT),
// so extraction silently failed to truncate existing files on macOS.
const O_RDONLY: c_int = @bitCast(std.c.O{ .ACCMODE = .RDONLY });
// Write + create + truncate, and refuse to follow a symlink at the final
// component (defense against symlink-target file overwrite during extract).
const O_WRONLY_CREAT_TRUNC_NOFOLLOW: c_int = @bitCast(std.c.O{
    .ACCMODE = .WRONLY,
    .CREAT = true,
    .TRUNC = true,
    .NOFOLLOW = true,
});
// Archive-creation output (following a symlinked archive path is fine here).
const O_WRONLY_CREAT_TRUNC: c_int = @bitCast(std.c.O{
    .ACCMODE = .WRONLY,
    .CREAT = true,
    .TRUNC = true,
});
const SEEK_CUR: c_int = 1;

// Per-target `struct stat`. The previous hand-declared Linux x86-64 layout put
// every field at the wrong offset on macOS, so size/mode/uid/mtime came out
// garbage and every created archive was corrupt. std.c.Stat is the correct
// layout for the compilation target.
const Stat = std.c.Stat;

// Per-target `struct dirent`. The previous hand-declared Linux layout put the
// d_name field at the wrong offset on macOS (macOS interposes a 2-byte
// d_namlen before d_type), so directory entry names were read as garbage /
// empty strings. An empty name made the recursive walker descend into
// "dir/" -> "dir//" -> ... forever, overflowing the stack on ANY archive that
// contained a directory. std.c.dirent is the correct per-OS layout.
const Dirent = std.c.dirent;

const Passwd = extern struct {
    pw_name: ?[*:0]const u8,
    pw_passwd: ?[*:0]const u8,
    pw_uid: u32,
    pw_gid: u32,
    pw_gecos: ?[*:0]const u8,
    pw_dir: ?[*:0]const u8,
    pw_shell: ?[*:0]const u8,
};

const Group = extern struct {
    gr_name: ?[*:0]const u8,
    gr_passwd: ?[*:0]const u8,
    gr_gid: u32,
    gr_mem: ?[*]?[*:0]const u8,
};

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: ztar [OPTION]... [FILE]...
        \\
        \\Create, extract, or list tar archives.
        \\
        \\Main operation modes:
        \\  -c, --create            Create a new archive
        \\  -x, --extract           Extract files from an archive
        \\  -t, --list              List the contents of an archive
        \\
        \\Options:
        \\  -f, --file=ARCHIVE      Use archive file
        \\  -C, --directory=DIR     Change to DIR before performing operations
        \\  -v, --verbose           Verbosely list files processed
        \\  -p, --preserve-permissions  Preserve file permissions
        \\  -k, --keep-old-files    Don't overwrite existing files
        \\
        \\Compression options:
        \\  -z, --gzip              Filter through gzip
        \\  -j, --bzip2             Filter through bzip2
        \\  -J, --xz                Filter through xz
        \\      --zstd              Filter through zstd
        \\  -a, --auto-compress     Use archive suffix to determine compression
        \\
        \\Other options:
        \\      --help              Display this help and exit
        \\      --version           Display version information
        \\
        \\Examples:
        \\  ztar -cvf archive.tar dir/      # Create archive
        \\  ztar -czvf archive.tar.gz dir/  # Create gzip-compressed archive
        \\  ztar -xvf archive.tar           # Extract archive
        \\  ztar -xvf archive.tar.gz        # Extract (auto-detects compression)
        \\  ztar -tvf archive.tar           # List contents
        \\  ztar -xvf archive.tar -C /tmp   # Extract to /tmp
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("ztar " ++ VERSION ++ " - High-performance tar utility\n");
}

fn looksLikeTarOptions(arg: []const u8) bool {
    // Check if the argument looks like old-style tar options (e.g., "cf", "xzf", "tvf")
    // Must contain at least one mode letter and be all valid option chars
    var has_mode = false;
    for (arg) |c| {
        switch (c) {
            'c', 'x', 't' => has_mode = true,
            'v', 'f', 'z', 'j', 'J', 'p', 'k', 'a', 'C' => {},
            else => return false,
        }
    }
    return has_mode;
}

fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var i: usize = 0;
    // Support old-style tar options: first arg without leading '-' (e.g., "cf", "xzf")
    var prepend_dash = false;
    if (args.len > 0 and args[0].len > 0 and args[0][0] != '-' and looksLikeTarOptions(args[0])) {
        prepend_dash = true;
    }

    while (i < args.len) : (i += 1) {
        var arg = args[i];
        // For old-style first arg, treat it as short options
        if (i == 0 and prepend_dash) {
            // Process as if it had a leading dash
            var j: usize = 0;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];
                switch (c) {
                    'c' => config.mode = .create,
                    'x' => config.mode = .extract,
                    't' => config.mode = .list,
                    'v' => config.verbose = true,
                    'f' => {
                        i += 1;
                        if (i >= args.len) {
                            writeStderr("ztar: option 'f' requires an argument\n");
                            return error.MissingArgument;
                        }
                        config.archive_file = args[i];
                    },
                    'C' => {
                        i += 1;
                        if (i >= args.len) {
                            writeStderr("ztar: option 'C' requires an argument\n");
                            return error.MissingArgument;
                        }
                        config.directory = args[i];
                    },
                    'z' => config.compression = .gzip,
                    'j' => config.compression = .bzip2,
                    'J' => config.compression = .xz,
                    'p' => config.preserve_permissions = true,
                    'k' => config.keep_old_files = true,
                    'a' => config.auto_compress = true,
                    else => {},
                }
            }
            continue;
        }

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Short options (possibly combined)
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];
                switch (c) {
                    'c' => config.mode = .create,
                    'x' => config.mode = .extract,
                    't' => config.mode = .list,
                    'v' => config.verbose = true,
                    'f' => {
                        // Next argument or rest of string is filename
                        if (j + 1 < arg.len) {
                            config.archive_file = arg[j + 1 ..];
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("ztar: option '-f' requires an argument\n");
                                return error.MissingArgument;
                            }
                            config.archive_file = args[i];
                        }
                        break;
                    },
                    'C' => {
                        i += 1;
                        if (i >= args.len) {
                            writeStderr("ztar: option '-C' requires an argument\n");
                            return error.MissingArgument;
                        }
                        config.directory = args[i];
                        break;
                    },
                    'z' => config.compression = .gzip,
                    'j' => config.compression = .bzip2,
                    'J' => config.compression = .xz,
                    'p' => config.preserve_permissions = true,
                    'k' => config.keep_old_files = true,
                    'a' => config.auto_compress = true,
                    else => {
                        var err_buf: [64]u8 = undefined;
                        const err_msg = std.fmt.bufPrint(&err_buf, "ztar: invalid option -- '{c}'\n", .{c}) catch "ztar: invalid option\n";
                        writeStderr(err_msg);
                        return error.InvalidOption;
                    },
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--create")) {
                config.mode = .create;
            } else if (std.mem.eql(u8, arg, "--extract")) {
                config.mode = .extract;
            } else if (std.mem.eql(u8, arg, "--list")) {
                config.mode = .list;
            } else if (std.mem.eql(u8, arg, "--verbose")) {
                config.verbose = true;
            } else if (std.mem.eql(u8, arg, "--gzip")) {
                config.compression = .gzip;
            } else if (std.mem.eql(u8, arg, "--bzip2")) {
                config.compression = .bzip2;
            } else if (std.mem.eql(u8, arg, "--xz")) {
                config.compression = .xz;
            } else if (std.mem.eql(u8, arg, "--zstd")) {
                config.compression = .zstd;
            } else if (std.mem.eql(u8, arg, "--preserve-permissions")) {
                config.preserve_permissions = true;
            } else if (std.mem.eql(u8, arg, "--keep-old-files")) {
                config.keep_old_files = true;
            } else if (std.mem.eql(u8, arg, "--auto-compress")) {
                config.auto_compress = true;
            } else if (std.mem.eql(u8, arg, "--file")) {
                i += 1;
                if (i >= args.len) {
                    writeStderr("ztar: option '--file' requires an argument\n");
                    return error.MissingArgument;
                }
                config.archive_file = args[i];
            } else if (std.mem.startsWith(u8, arg, "--file=")) {
                config.archive_file = arg[7..];
            } else if (std.mem.eql(u8, arg, "--directory")) {
                i += 1;
                if (i >= args.len) {
                    writeStderr("ztar: option '--directory' requires an argument\n");
                    return error.MissingArgument;
                }
                config.directory = args[i];
            } else if (std.mem.startsWith(u8, arg, "--directory=")) {
                config.directory = arg[12..];
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "ztar: unrecognized option '{s}'\n", .{arg}) catch "ztar: unrecognized option\n";
                writeStderr(err_msg);
                return error.InvalidOption;
            }
        } else {
            // File argument
            try config.files.append(allocator, arg);
        }
    }

    // Auto-detect compression from filename
    if (config.auto_compress and config.archive_file != null and config.compression == .none) {
        config.compression = Compression.detectFromFilename(config.archive_file.?);
    }

    return config;
}

fn createArchive(config: *const Config, allocator: std.mem.Allocator) !void {
    const archive_file = config.archive_file orelse {
        writeStderr("ztar: no archive file specified\n");
        return error.NoArchive;
    };

    if (rejectUnsupportedCompression(config.compression)) return error.UnsupportedCompression;

    // Change directory if specified
    if (config.directory) |dir| {
        var dir_buf: [4096]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir}) catch return error.PathTooLong;
        if (chdir(dir_z) != 0) {
            writeStderr("ztar: cannot change to directory\n");
            return error.ChdirFailed;
        }
    }

    // For gzip compression, we need to collect tar data in memory first
    if (config.compression == .gzip) {
        // Create tar archive in memory
        var tar_data: std.ArrayListUnmanaged(u8) = .empty;
        defer tar_data.deinit(allocator);

        // Add each file/directory to memory buffer
        for (config.files.items) |path| {
            addToArchiveMem(&tar_data, allocator, path, config);
        }

        // Write two zero blocks to end archive
        tar_data.appendSlice(allocator, &[_]u8{0} ** 1024) catch {
            writeStderr("ztar: memory allocation error\n");
            return error.OutOfMemory;
        };

        // Compress the tar data
        const compressed = compressGzip(allocator, tar_data.items) catch {
            writeStderr("ztar: compression failed\n");
            return error.CompressionFailed;
        };
        defer allocator.free(compressed);

        // Write compressed data to file
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{archive_file}) catch return error.PathTooLong;

        const fd = open(path_z.ptr, O_WRONLY_CREAT_TRUNC, @as(c_int, 0o644));
        if (fd < 0) {
            writeStderr("ztar: cannot create archive file\n");
            return error.CreateFailed;
        }
        defer _ = close(fd);

        _ = write(fd, compressed.ptr, compressed.len);

        if (config.verbose) {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "ztar: compressed {d} -> {d} bytes ({d:.1}%)\n", .{
                tar_data.items.len,
                compressed.len,
                if (tar_data.items.len > 0) 100.0 * @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(tar_data.items.len)) else 0.0,
            }) catch "ztar: compressed\n";
            writeStderr(msg);
        }
    } else {
        // No compression - write directly to file
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{archive_file}) catch return error.PathTooLong;

        const fd = open(path_z.ptr, O_WRONLY_CREAT_TRUNC, @as(c_int, 0o644));
        if (fd < 0) {
            writeStderr("ztar: cannot create archive file\n");
            return error.CreateFailed;
        }
        defer _ = close(fd);

        // Add each file/directory
        for (config.files.items) |path| {
            addToArchiveFd(fd, path, config, allocator);
        }

        // Write two zero blocks to end archive
        var zero_block: [512]u8 = undefined;
        @memset(&zero_block, 0);
        _ = write(fd, &zero_block, 512);
        _ = write(fd, &zero_block, 512);
    }
}

fn addToArchiveFd(fd: c_int, path: []const u8, config: *const Config, allocator: std.mem.Allocator) void {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;
    // allocator used in recursive call

    // Get file info using lstat
    var stat_buf: Stat = undefined;
    if (lstat(path_z.ptr, &stat_buf) != 0) {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "ztar: {s}: Cannot stat\n", .{path}) catch "ztar: Cannot stat file\n";
        writeStderr(err_msg);
        return;
    }

    // Create header
    var header = TarHeader.init();
    header.setName(path);
    header.setMode(stat_buf.mode & 0o7777);
    header.setUid(stat_buf.uid);
    header.setGid(stat_buf.gid);
    header.setMtime(stat_buf.mtime().sec);

    // Set user/group names
    if (getpwuid(stat_buf.uid)) |pw| {
        if (pw.pw_name) |name| {
            header.setUname(std.mem.span(name));
        }
    }
    if (getgrgid(stat_buf.gid)) |gr| {
        if (gr.gr_name) |name| {
            header.setGname(std.mem.span(name));
        }
    }

    // Determine type
    const is_dir = (stat_buf.mode & 0o170000) == 0o040000;
    const is_symlink = (stat_buf.mode & 0o170000) == 0o120000;

    if (is_dir) {
        header.typeflag = TarHeader.TYPE_DIRECTORY;
        header.setSize(0);
    } else if (is_symlink) {
        header.typeflag = TarHeader.TYPE_SYMLINK;
        header.setSize(0);
        // Read symlink target
        var link_buf: [100]u8 = undefined;
        const link_len = readlink(path_z.ptr, &link_buf, 100);
        if (link_len > 0) {
            @memcpy(header.linkname[0..@intCast(link_len)], link_buf[0..@intCast(link_len)]);
        }
    } else {
        header.typeflag = TarHeader.TYPE_REGULAR;
        header.setSize(@intCast(stat_buf.size));
    }

    header.computeChecksum();

    // Write header
    const header_bytes = @as([*]const u8, @ptrCast(&header))[0..512];
    _ = write(fd, header_bytes.ptr, 512);

    if (config.verbose) {
        writeStdout(path);
        writeStdout("\n");
    }

    // Write file contents (if regular file)
    if (!is_dir and !is_symlink and stat_buf.size > 0) {
        const src_fd = open(path_z.ptr, O_RDONLY);
        if (src_fd < 0) return;
        defer _ = close(src_fd);

        var buf: [8192]u8 = undefined;
        var remaining: u64 = @intCast(stat_buf.size);

        while (remaining > 0) {
            const to_read = @min(remaining, buf.len);
            const bytes_read = read(src_fd, &buf, to_read);
            if (bytes_read <= 0) break;
            _ = write(fd, &buf, @intCast(bytes_read));
            remaining -= @intCast(bytes_read);
        }

        // Pad to 512-byte boundary
        const file_size: u64 = @intCast(stat_buf.size);
        const padding = (512 - (file_size % 512)) % 512;
        if (padding > 0) {
            var pad_buf: [512]u8 = undefined;
            @memset(&pad_buf, 0);
            _ = write(fd, &pad_buf, padding);
        }
    }

    // Recurse into directories
    if (is_dir) {
        const dir = opendir(path_z.ptr);
        if (dir == null) return;
        defer _ = closedir(dir.?);

        while (readdir(dir.?)) |entry| {
            // Skip . and ..
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
            const name = std.mem.span(name_ptr);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            var full_path_buf: [4096]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ path, name }) catch continue;
            addToArchiveFd(fd, full_path, config, allocator);
        }
    }
}

/// Add file/directory to archive in memory (for compression)
fn addToArchiveMem(tar_data: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, path: []const u8, config: *const Config) void {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;

    // Get file info using lstat
    var stat_buf: Stat = undefined;
    if (lstat(path_z.ptr, &stat_buf) != 0) {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "ztar: {s}: Cannot stat\n", .{path}) catch "ztar: Cannot stat file\n";
        writeStderr(err_msg);
        return;
    }

    // Create header
    var header = TarHeader.init();
    header.setName(path);
    header.setMode(stat_buf.mode & 0o7777);
    header.setUid(stat_buf.uid);
    header.setGid(stat_buf.gid);
    header.setMtime(stat_buf.mtime().sec);

    // Set user/group names
    if (getpwuid(stat_buf.uid)) |pw| {
        if (pw.pw_name) |name| {
            header.setUname(std.mem.span(name));
        }
    }
    if (getgrgid(stat_buf.gid)) |gr| {
        if (gr.gr_name) |name| {
            header.setGname(std.mem.span(name));
        }
    }

    // Determine type
    const is_dir = (stat_buf.mode & 0o170000) == 0o040000;
    const is_symlink = (stat_buf.mode & 0o170000) == 0o120000;

    if (is_dir) {
        header.typeflag = TarHeader.TYPE_DIRECTORY;
        header.setSize(0);
    } else if (is_symlink) {
        header.typeflag = TarHeader.TYPE_SYMLINK;
        header.setSize(0);
        // Read symlink target
        var link_buf: [100]u8 = undefined;
        const link_len = readlink(path_z.ptr, &link_buf, 100);
        if (link_len > 0) {
            @memcpy(header.linkname[0..@intCast(link_len)], link_buf[0..@intCast(link_len)]);
        }
    } else {
        header.typeflag = TarHeader.TYPE_REGULAR;
        header.setSize(@intCast(stat_buf.size));
    }

    header.computeChecksum();

    // Write header to memory
    const header_bytes = @as([*]const u8, @ptrCast(&header))[0..512];
    tar_data.appendSlice(allocator, header_bytes) catch return;

    if (config.verbose) {
        writeStdout(path);
        writeStdout("\n");
    }

    // Write file contents (if regular file)
    if (!is_dir and !is_symlink and stat_buf.size > 0) {
        const src_fd = open(path_z.ptr, O_RDONLY);
        if (src_fd < 0) return;
        defer _ = close(src_fd);

        var buf: [8192]u8 = undefined;
        var remaining: u64 = @intCast(stat_buf.size);

        while (remaining > 0) {
            const to_read = @min(remaining, buf.len);
            const bytes_read = read(src_fd, &buf, to_read);
            if (bytes_read <= 0) break;
            tar_data.appendSlice(allocator, buf[0..@intCast(bytes_read)]) catch return;
            remaining -= @intCast(bytes_read);
        }

        // Pad to 512-byte boundary
        const file_size: u64 = @intCast(stat_buf.size);
        const padding = (512 - (file_size % 512)) % 512;
        if (padding > 0) {
            var pad_buf: [512]u8 = undefined;
            @memset(&pad_buf, 0);
            tar_data.appendSlice(allocator, pad_buf[0..padding]) catch return;
        }
    }

    // Recurse into directories
    if (is_dir) {
        const dir = opendir(path_z.ptr);
        if (dir == null) return;
        defer _ = closedir(dir.?);

        while (readdir(dir.?)) |entry| {
            // Skip . and ..
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
            const name = std.mem.span(name_ptr);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            var full_path_buf: [4096]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ path, name }) catch continue;
            addToArchiveMem(tar_data, allocator, full_path, config);
        }
    }
}

fn extractArchive(config: *const Config, allocator: std.mem.Allocator) !void {
    const archive_file = config.archive_file orelse {
        writeStderr("ztar: no archive file specified\n");
        return error.NoArchive;
    };

    if (rejectUnsupportedCompression(config.compression)) return error.UnsupportedCompression;

    // Change directory if specified
    if (config.directory) |dir| {
        var dir_buf: [4096]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir}) catch return error.PathTooLong;
        if (chdir(dir_z) != 0) {
            writeStderr("ztar: cannot change to directory\n");
            return error.ChdirFailed;
        }
    }

    // Read entire archive file into memory
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{archive_file}) catch return error.PathTooLong;

    const fd = open(path_z.ptr, O_RDONLY);
    if (fd < 0) {
        writeStderr("ztar: cannot open archive file\n");
        return error.OpenFailed;
    }

    var file_data: std.ArrayListUnmanaged(u8) = .empty;
    defer file_data.deinit(allocator);

    var buf: [65536]u8 = undefined;
    while (true) {
        const bytes_read = read(fd, &buf, buf.len);
        if (bytes_read <= 0) break;
        file_data.appendSlice(allocator, buf[0..@intCast(bytes_read)]) catch {
            _ = close(fd);
            writeStderr("ztar: memory allocation error\n");
            return error.OutOfMemory;
        };
    }
    _ = close(fd);

    // Check for gzip and decompress if needed
    var tar_data: []const u8 = file_data.items;
    var decompressed_data: ?[]u8 = null;
    defer if (decompressed_data) |d| allocator.free(d);

    if (isGzipData(file_data.items) or config.compression == .gzip) {
        decompressed_data = decompressGzip(allocator, file_data.items) catch {
            writeStderr("ztar: decompression failed\n");
            return error.DecompressionFailed;
        };
        tar_data = decompressed_data.?;

        if (config.verbose) {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "ztar: decompressed {d} -> {d} bytes\n", .{
                file_data.items.len,
                tar_data.len,
            }) catch "ztar: decompressed\n";
            writeStderr(msg);
        }
    }

    // Process tar data from memory
    var had_error = false;
    var pos: usize = 0;
    while (pos + 512 <= tar_data.len) {
        const header: *const TarHeader = @ptrCast(@alignCast(tar_data.ptr + pos));
        pos += 512;

        // Check for end of archive (two zero blocks)
        if (header.isZeroBlock()) break;

        // Verify checksum. A mismatch means the header is not a real tar
        // header; continuing (the old behavior) desynced the parser because
        // pos was never advanced past the body, so file data was reinterpreted
        // as headers. Treat it as fatal, like GNU tar on a corrupt archive.
        if (!header.verifyChecksum()) {
            writeStderr("ztar: This does not look like a tar archive\n");
            return error.BadChecksum;
        }

        var name_join_buf: [257]u8 = undefined;
        var name = header.getName(&name_join_buf);
        const size = header.getSize();
        const mode = header.getMode();

        // Strip leading slashes from paths (security + compatibility)
        while (name.len > 0 and name[0] == '/') {
            name = name[1..];
        }
        if (name.len == 0) {
            const blocks = (size + 511) / 512;
            pos += blocks * 512;
            continue;
        }

        // Refuse members that would escape the extraction directory via a
        // ".." component (path traversal). GNU tar / libarchive reject these
        // by default; the previous code only stripped a leading '/', so a
        // member named "../evil" was written to the PARENT directory.
        if (pathHasParentRef(name)) {
            var eb: [4300]u8 = undefined;
            const em = std.fmt.bufPrint(&eb, "ztar: {s}: Path contains '..', refusing to extract\n", .{name}) catch "ztar: Path contains '..', refusing to extract\n";
            writeStderr(em);
            had_error = true;
            const blocks = (size + 511) / 512;
            pos += blocks * 512;
            continue;
        }

        if (config.verbose) {
            writeStdout(name);
            writeStdout("\n");
        }

        // Create path
        var name_buf: [4096]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch {
            const blocks = (size + 511) / 512;
            pos += blocks * 512;
            continue;
        };

        switch (header.typeflag) {
            TarHeader.TYPE_DIRECTORY => {
                // Create directory
                _ = mkdir(name_z.ptr, 0o755);
                if (config.preserve_permissions) {
                    _ = chmod(name_z.ptr, mode);
                }
            },
            TarHeader.TYPE_REGULAR, TarHeader.TYPE_REGULAR_ALT => {
                // Create parent directories
                if (std.mem.lastIndexOf(u8, name, "/")) |idx| {
                    makeDirs(name[0..idx]);
                }

                // Check if file exists
                if (config.keep_old_files) {
                    var stat_buf: Stat = undefined;
                    if (lstat(name_z.ptr, &stat_buf) == 0) {
                        // Skip - file exists
                        const blocks = (size + 511) / 512;
                        pos += blocks * 512;
                        continue;
                    }
                }

                // Remove any pre-existing entry first (so we never write
                // THROUGH a symlink an earlier malicious member planted), then
                // create with O_NOFOLLOW so the final component is never
                // followed if it is a symlink.
                _ = unlink(name_z.ptr);
                const out_fd = open(name_z.ptr, O_WRONLY_CREAT_TRUNC_NOFOLLOW, @as(c_int, 0o644));
                if (out_fd < 0) {
                    had_error = true;
                    const blocks = (size + 511) / 512;
                    pos += blocks * 512;
                    continue;
                }
                defer _ = close(out_fd);

                // Copy contents from memory
                if (pos + size <= tar_data.len) {
                    _ = write(out_fd, tar_data.ptr + pos, size);
                }

                // Advance past content and padding
                const blocks = (size + 511) / 512;
                pos += blocks * 512;

                if (config.preserve_permissions) {
                    _ = chmod(name_z.ptr, mode);
                }
            },
            TarHeader.TYPE_SYMLINK => {
                // Create symlink
                var linkname_len: usize = 0;
                while (linkname_len < 100 and header.linkname[linkname_len] != 0) : (linkname_len += 1) {}

                var linkname_buf: [101]u8 = undefined;
                @memcpy(linkname_buf[0..linkname_len], header.linkname[0..linkname_len]);
                linkname_buf[linkname_len] = 0;

                // Refuse absolute or upward-traversing link targets: a link
                // like "x -> /etc" or "x -> ../.." would let a later member
                // "x/foo" be written outside the destination.
                if (linkTargetUnsafe(linkname_buf[0..linkname_len])) {
                    var eb: [256]u8 = undefined;
                    const em = std.fmt.bufPrint(&eb, "ztar: {s}: unsafe symlink target, refusing\n", .{name}) catch "ztar: unsafe symlink target, refusing\n";
                    writeStderr(em);
                    had_error = true;
                    continue;
                }

                // Remove any pre-existing entry so symlink() doesn't fail with
                // EEXIST on re-extract.
                _ = unlink(name_z.ptr);
                const linkname_z: [*:0]const u8 = @ptrCast(&linkname_buf);
                _ = symlink(linkname_z, name_z.ptr);
            },
            else => {
                // Skip unknown types
                const blocks = (size + 511) / 512;
                pos += blocks * 512;
            },
        }
    }

    if (had_error) return error.ExtractError;
}

fn makeDirs(path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (path) |c| {
        path_buf[pos] = c;
        pos += 1;
        if (c == '/') {
            path_buf[pos] = 0;
            const dir_z: [*:0]const u8 = @ptrCast(&path_buf);
            _ = mkdir(dir_z, 0o755);
        }
    }
    path_buf[pos] = 0;
    const dir_z: [*:0]const u8 = @ptrCast(&path_buf);
    _ = mkdir(dir_z, 0o755);
}

fn skipBytesFd(fd: c_int, count: u64) void {
    _ = lseek(fd, @intCast(count), SEEK_CUR);
}

fn listArchive(config: *const Config, allocator: std.mem.Allocator) !void {
    const archive_file = config.archive_file orelse {
        writeStderr("ztar: no archive file specified\n");
        return error.NoArchive;
    };

    if (rejectUnsupportedCompression(config.compression)) return error.UnsupportedCompression;

    // Read entire archive file into memory
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{archive_file}) catch return error.PathTooLong;

    const fd = open(path_z.ptr, O_RDONLY);
    if (fd < 0) {
        writeStderr("ztar: cannot open archive file\n");
        return error.OpenFailed;
    }

    var file_data: std.ArrayListUnmanaged(u8) = .empty;
    defer file_data.deinit(allocator);

    var buf: [65536]u8 = undefined;
    while (true) {
        const bytes_read = read(fd, &buf, buf.len);
        if (bytes_read <= 0) break;
        file_data.appendSlice(allocator, buf[0..@intCast(bytes_read)]) catch {
            _ = close(fd);
            writeStderr("ztar: memory allocation error\n");
            return error.OutOfMemory;
        };
    }
    _ = close(fd);

    // Check for gzip and decompress if needed
    var tar_data: []const u8 = file_data.items;
    var decompressed_data: ?[]u8 = null;
    defer if (decompressed_data) |d| allocator.free(d);

    if (isGzipData(file_data.items) or config.compression == .gzip) {
        decompressed_data = decompressGzip(allocator, file_data.items) catch {
            writeStderr("ztar: decompression failed\n");
            return error.DecompressionFailed;
        };
        tar_data = decompressed_data.?;
    }

    // Process tar data from memory
    var pos: usize = 0;
    while (pos + 512 <= tar_data.len) {
        const header: *const TarHeader = @ptrCast(@alignCast(tar_data.ptr + pos));
        pos += 512;

        if (header.isZeroBlock()) break;

        // Verify the header checksum so non-tar/garbage input errors out
        // instead of printing garbage member names.
        if (!header.verifyChecksum()) {
            writeStderr("ztar: This does not look like a tar archive\n");
            return error.BadChecksum;
        }

        var name_join_buf: [257]u8 = undefined;
        const name = header.getName(&name_join_buf);
        const size = header.getSize();

        if (config.verbose) {
            // Verbose listing with permissions, size, date
            var line_buf: [512]u8 = undefined;
            const mode = header.getMode();
            const mtime = header.getMtime();

            // Format mode string
            var mode_str: [10]u8 = undefined;
            formatMode(mode, header.typeflag, &mode_str);

            // Format size
            var size_str: [16]u8 = undefined;
            const size_len = std.fmt.bufPrint(&size_str, "{d:>8}", .{size}) catch "?";

            const line = std.fmt.bufPrint(&line_buf, "{s} {s} {d} {s}\n", .{
                mode_str[0..10],
                size_len,
                mtime,
                name,
            }) catch continue;
            writeStdout(line);
        } else {
            writeStdout(name);
            writeStdout("\n");
        }

        // Skip file content
        const blocks = (size + 511) / 512;
        pos += blocks * 512;
    }
}

fn formatMode(mode: u32, typeflag: u8, buf: *[10]u8) void {
    buf[0] = switch (typeflag) {
        TarHeader.TYPE_DIRECTORY => 'd',
        TarHeader.TYPE_SYMLINK => 'l',
        TarHeader.TYPE_CHARDEV => 'c',
        TarHeader.TYPE_BLOCKDEV => 'b',
        TarHeader.TYPE_FIFO => 'p',
        else => '-',
    };
    buf[1] = if (mode & 0o400 != 0) 'r' else '-';
    buf[2] = if (mode & 0o200 != 0) 'w' else '-';
    buf[3] = if (mode & 0o100 != 0) 'x' else '-';
    buf[4] = if (mode & 0o040 != 0) 'r' else '-';
    buf[5] = if (mode & 0o020 != 0) 'w' else '-';
    buf[6] = if (mode & 0o010 != 0) 'x' else '-';
    buf[7] = if (mode & 0o004 != 0) 'r' else '-';
    buf[8] = if (mode & 0o002 != 0) 'w' else '-';
    buf[9] = if (mode & 0o001 != 0) 'x' else '-';
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

    // GNU tar uses exit status 2 for fatal errors (1 is reserved for "some
    // files differ" in --compare, which ztar does not implement).
    var config = parseArgs(args[1..], allocator) catch {
        std.process.exit(2);
    };
    defer config.files.deinit(allocator);

    if (config.mode == .none) {
        writeStderr("ztar: You must specify one of -c, -t, -x\n");
        writeStderr("Try 'ztar --help' for more information.\n");
        std.process.exit(2);
    }

    switch (config.mode) {
        .create => createArchive(&config, allocator) catch {
            std.process.exit(2);
        },
        .extract => extractArchive(&config, allocator) catch {
            std.process.exit(2);
        },
        .list => listArchive(&config, allocator) catch {
            std.process.exit(2);
        },
        .none => unreachable,
    }
}

// ===========================================================================
// Unit tests — externally anchored to the POSIX.1-1988 "ustar" tar header
// definition (IEEE Std 1003.1, "pax" / "Extended tar Format") and to the
// documented GNU tar / libarchive path-traversal refusal behavior. Inputs and
// expected outputs are the spec's, not this program's — no roundtrip-only
// tests. The end-to-end cross-implementation anchor (create with ztar / read
// with the system bsdtar, and vice versa) lives in tests/parity_test.sh, run
// by the same `zig build test`.
// ===========================================================================

const testing = std.testing;

test "getOctal parses the octal ASCII header number fields (POSIX ustar)" {
    // POSIX: numeric fields are octal ASCII, terminated by NUL or space.
    // A file of 12 bytes has size field "000000000014\x00" (0o14 == 12).
    try testing.expectEqual(@as(u64, 12), TarHeader.getOctal("000000000014\x00"));
    // mode 0644 is stored as "0000644\x00".
    try testing.expectEqual(@as(u64, 0o644), TarHeader.getOctal("0000644\x00"));
    // Space terminator is equally valid per spec.
    try testing.expectEqual(@as(u64, 0o755), TarHeader.getOctal("0000755 "));
}

test "getName joins prefix + '/' + name for split paths (POSIX ustar)" {
    // POSIX ustar: when the prefix field is non-empty, the full pathname is
    // prefix, then a '/', then name.
    var h = TarHeader.init();
    @memcpy(h.prefix[0..9], "usr/local");
    @memcpy(h.name[0..8], "bin/ztar");
    var buf: [257]u8 = undefined;
    try testing.expectEqualStrings("usr/local/bin/ztar", h.getName(&buf));

    // Empty prefix => the name field alone is the pathname.
    var h2 = TarHeader.init();
    @memcpy(h2.name[0..5], "a.txt");
    try testing.expectEqualStrings("a.txt", h2.getName(&buf));
}

test "setName performs the POSIX name/prefix split for paths > 100 bytes" {
    // Path with a single '/' at index 120: the spec mandates the trailing
    // component (<=100) goes in `name` and the leading directory (<=155) in
    // `prefix`. leaf = "leaf.txt" (8 bytes), dir = 120 'p's.
    const dir = "p" ** 120;
    const path = dir ++ "/leaf.txt";
    try testing.expect(path.len > 100);
    var h = TarHeader.init();
    h.setName(path);
    // Exact field placement per the ustar split rule (not a roundtrip):
    try testing.expectEqualStrings(dir, h.prefix[0..120]);
    try testing.expectEqual(@as(u8, 0), h.prefix[120]);
    try testing.expectEqualStrings("leaf.txt", h.name[0..8]);
    try testing.expectEqual(@as(u8, 0), h.name[8]);
    // And the reconstructed pathname equals the original.
    var buf: [257]u8 = undefined;
    try testing.expectEqualStrings(path, h.getName(&buf));
}

test "setName keeps short paths verbatim in the name field, empty prefix" {
    var h = TarHeader.init();
    h.setName("dir/file.txt");
    try testing.expectEqualStrings("dir/file.txt", h.name[0..12]);
    try testing.expectEqual(@as(u8, 0), h.prefix[0]);
}

test "pathHasParentRef refuses traversal (GNU/libarchive default)" {
    // GNU tar / libarchive refuse members containing a ".." component or an
    // absolute path by default.
    try testing.expect(pathHasParentRef("../escaped.txt"));
    try testing.expect(pathHasParentRef("a/../../b"));
    try testing.expect(pathHasParentRef(".."));
    try testing.expect(pathHasParentRef("/abs/path"));
    try testing.expect(!pathHasParentRef("a/b/c.txt"));
    try testing.expect(!pathHasParentRef("a..b/c")); // ".." only as a full component
    try testing.expect(!pathHasParentRef("...")); // three dots is a normal name
}

test "linkTargetUnsafe refuses absolute and upward symlink targets" {
    try testing.expect(linkTargetUnsafe("/etc/passwd"));
    try testing.expect(linkTargetUnsafe("../../etc"));
    try testing.expect(linkTargetUnsafe("a/../../b"));
    try testing.expect(!linkTargetUnsafe("sibling.txt"));
    try testing.expect(!linkTargetUnsafe("sub/dir/file"));
    try testing.expect(!linkTargetUnsafe(""));
}

test "verifyChecksum accepts a well-formed header and rejects a corrupted one" {
    // The checksum is the unsigned sum of all 512 header bytes with the
    // checksum field taken as 8 spaces (POSIX ustar). A header we computed a
    // checksum for must verify; flipping any byte must fail.
    var h = TarHeader.init();
    h.setName("f");
    h.setMode(0o644);
    h.setSize(3);
    h.typeflag = TarHeader.TYPE_REGULAR;
    h.computeChecksum();
    try testing.expect(h.verifyChecksum());
    h.name[0] = 'g'; // tamper
    try testing.expect(!h.verifyChecksum());
}

test "compressGzip emits a real gzip stream (magic + trailer), decodable" {
    // gzip (RFC 1952): stream begins with 0x1f 0x8b. A finalized stream is
    // decodable back to the original; a stream missing the final block/footer
    // (the pre-fix bug) is not. We assert both the magic and decodability.
    const input = "the quick brown fox jumps over the lazy dog\n" ** 8;
    const gz = try compressGzip(testing.allocator, input);
    defer testing.allocator.free(gz);
    try testing.expect(gz.len >= 18);
    try testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try testing.expectEqual(@as(u8, 0x8b), gz[1]);
    const back = try decompressGzip(testing.allocator, gz);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(input, back);
}
