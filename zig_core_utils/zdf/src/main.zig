//! zdf - Report file system disk space usage
//!
//! A cross-platform `df` implementation in Zig (macOS + Linux).
//!
//! Portability note: the original implementation hardcoded the Linux x86_64
//! `statvfs` ABI and read `/proc/mounts`, so it produced garbage (and panicked
//! on integer overflow) on macOS. This version selects the native mount-table
//! and stat mechanism per target: `getmntinfo(3)` + `statfs(2)` on Darwin,
//! `/proc/mounts` + `statvfs(3)` on Linux. All kernel-supplied arithmetic is
//! saturating so a thin/over-provisioned filesystem can never underflow-panic.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const VERSION = "1.0.0";
const is_darwin = builtin.os.tag.isDarwin();

// ---------------------------------------------------------------------------
// Platform stat bindings
// ---------------------------------------------------------------------------

// macOS `struct statfs` (the __DARWIN_64_BIT_INO_T / __DARWIN_STRUCT_STATFS64
// layout, which is the only variant on arm64). MAXPATHLEN = 1024,
// MFSTYPENAMELEN = 16.
const DarwinStatfs = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};

const MNT_NOWAIT: c_int = 2;

// On arm64 macOS the plain symbols already resolve to the 64-bit-inode
// variants (__DARWIN_ONLY_64_BIT_INO_T == 1), so no "$INODE64" suffix is
// required.
extern "c" fn getmntinfo(mntbufp: *[*]DarwinStatfs, flags: c_int) c_int;
extern "c" fn statfs(path: [*:0]const u8, buf: *DarwinStatfs) c_int;

// Linux `struct statvfs` (glibc, 64-bit). Only referenced when compiling for
// Linux; kept as an extern struct so a non-Linux build never links it.
const LinuxStatvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    __f_spare: [6]c_int,
};
extern "c" fn statvfs(path: [*:0]const u8, buf: *LinuxStatvfs) c_int;

extern "c" fn strerror(errnum: c_int) [*:0]u8;

// ---------------------------------------------------------------------------
// Config / model
// ---------------------------------------------------------------------------

const Config = struct {
    human_readable: bool = false,
    human_base: u64 = 1024, // 1000 for --si / -H
    show_inodes: bool = false,
    show_type: bool = false,
    show_total: bool = false,
    block_size: u64 = 1024, // scale for non-human block mode
};

/// A single filesystem's stats, normalized across platforms. Strings are
/// owned (arena-allocated) so they outlive the transient kernel buffers.
const Row = struct {
    device: []const u8,
    mount: []const u8,
    fstype: []const u8,
    frag_size: u64, // bytes per block for size math
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
};

// ---------------------------------------------------------------------------
// Low-level IO (EINTR-safe, checks short writes)
// ---------------------------------------------------------------------------

fn writeFd(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return;
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeFd(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeFd(libc.STDERR_FILENO, data);
}

// ---------------------------------------------------------------------------
// Saturating arithmetic helpers
// ---------------------------------------------------------------------------

fn ceilDiv(num: u64, den: u64) u64 {
    if (den == 0) return 0;
    return (num +| (den - 1)) / den;
}

// ---------------------------------------------------------------------------
// Number / size formatting
// ---------------------------------------------------------------------------

fn fmtU64(a: std.mem.Allocator, v: u64) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{v}) catch "0";
}

/// GNU-style human-readable size: pick the largest unit whose value >= 1, then
/// round UP to 1 decimal place when < 10, else round up to a whole number.
/// `base` is 1024 for -h, 1000 for -H/--si.
fn fmtHuman(a: std.mem.Allocator, bytes: u64, base: u64) []const u8 {
    const units = "BKMGTPE";
    if (bytes == 0) return "0";

    var val: f64 = @floatFromInt(bytes);
    const b: f64 = @floatFromInt(base);
    var idx: usize = 0;
    while (val >= b and idx + 1 < units.len) {
        val /= b;
        idx += 1;
    }

    if (idx == 0) {
        // Sub-unit: whole bytes, no suffix (GNU shows the raw count here).
        return fmtU64(a, bytes);
    }

    const unit = units[idx];
    if (val < 10.0) {
        // ceil to one decimal
        const scaled = @ceil(val * 10.0) / 10.0;
        if (scaled >= 10.0) {
            return std.fmt.allocPrint(a, "{d:.0}{c}", .{ scaled, unit }) catch "0";
        }
        return std.fmt.allocPrint(a, "{d:.1}{c}", .{ scaled, unit }) catch "0";
    } else {
        const scaled = @ceil(val);
        return std.fmt.allocPrint(a, "{d:.0}{c}", .{ scaled, unit }) catch "0";
    }
}

/// "1K-blocks", "1M-blocks", "512B-blocks", ... matching GNU's header text.
fn blockHeader(a: std.mem.Allocator, bs: u64) []const u8 {
    const names = "KMGTPE";
    var v = bs;
    var k: usize = 0;
    while (v >= 1024 and v % 1024 == 0 and k < names.len) {
        v /= 1024;
        k += 1;
    }
    if (k > 0 and v == 1) {
        return std.fmt.allocPrint(a, "1{c}-blocks", .{names[k - 1]}) catch "1K-blocks";
    }
    return std.fmt.allocPrint(a, "{d}B-blocks", .{bs}) catch "1K-blocks";
}

// ---------------------------------------------------------------------------
// -B/--block-size SIZE parsing (returns bytes, or null on parse error)
// ---------------------------------------------------------------------------

fn unitExponent(c: u8) ?u32 {
    return switch (c) {
        'K', 'k' => 1,
        'M', 'm' => 2,
        'G', 'g' => 3,
        'T', 't' => 4,
        'P', 'p' => 5,
        'E', 'e' => 6,
        else => null,
    };
}

fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var num: u64 = 0;
    var have_digits = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        num = num *| 10 +| (s[i] - '0');
        have_digits = true;
    }
    if (!have_digits) num = 1;

    var mult: u64 = 1;
    const rest = s[i..];
    if (rest.len > 0) {
        const exp = unitExponent(rest[0]) orelse return null;
        // suffix forms: "K"/"KiB" => binary (1024), "KB" => decimal (1000)
        var base: u64 = 1024;
        if (rest.len == 2 and (rest[1] == 'B' or rest[1] == 'b')) {
            base = 1000;
        } else if (rest.len == 3 and (rest[1] == 'i' or rest[1] == 'I')) {
            base = 1024;
        } else if (rest.len != 1) {
            return null;
        }
        var e: u32 = 0;
        while (e < exp) : (e += 1) mult = mult *| base;
    }
    if (num == 0) return null;
    return num *| mult;
}

// ---------------------------------------------------------------------------
// Table rendering with GNU-compatible dynamic column widths
// ---------------------------------------------------------------------------

const MAX_COLS = 7;

// GNU df reserves a minimum width of 5 columns for the numeric size/count
// fields (Size/Used/Avail/<N>-blocks, Inodes/IUsed/IFree). The percent and
// text columns are not padded to this minimum.
const SIZE_COL_MIN: usize = 5;

const Table = struct {
    a: std.mem.Allocator,
    headers: [MAX_COLS][]const u8 = undefined,
    left: [MAX_COLS]bool = undefined,
    min_w: [MAX_COLS]usize = undefined,
    ncol: usize = 0,
    rows: std.ArrayList([MAX_COLS][]const u8) = .empty,

    fn addCol(self: *Table, header: []const u8, is_left: bool, min_width: usize) void {
        self.headers[self.ncol] = header;
        self.left[self.ncol] = is_left;
        self.min_w[self.ncol] = min_width;
        self.ncol += 1;
    }

    fn addRow(self: *Table, cells: [MAX_COLS][]const u8) void {
        self.rows.append(self.a, cells) catch {};
    }

    fn pad(a: std.mem.Allocator, s: []const u8, width: usize, is_left: bool) []const u8 {
        if (s.len >= width) return s;
        const buf = a.alloc(u8, width) catch return s;
        const gap = width - s.len;
        if (is_left) {
            @memcpy(buf[0..s.len], s);
            @memset(buf[s.len..], ' ');
        } else {
            @memset(buf[0..gap], ' ');
            @memcpy(buf[gap..], s);
        }
        return buf;
    }

    fn emit(self: *Table) void {
        var widths: [MAX_COLS]usize = undefined;
        for (0..self.ncol) |c| {
            widths[c] = @max(self.headers[c].len, self.min_w[c]);
            for (self.rows.items) |cells| {
                widths[c] = @max(widths[c], cells[c].len);
            }
        }

        var out: std.ArrayList(u8) = .empty;

        // header
        for (0..self.ncol) |c| {
            if (c > 0) out.append(self.a, ' ') catch {};
            if (c == self.ncol - 1) {
                out.appendSlice(self.a, self.headers[c]) catch {};
            } else {
                out.appendSlice(self.a, pad(self.a, self.headers[c], widths[c], self.left[c])) catch {};
            }
        }
        out.append(self.a, '\n') catch {};

        // data
        for (self.rows.items) |cells| {
            for (0..self.ncol) |c| {
                if (c > 0) out.append(self.a, ' ') catch {};
                if (c == self.ncol - 1) {
                    out.appendSlice(self.a, cells[c]) catch {};
                } else {
                    out.appendSlice(self.a, pad(self.a, cells[c], widths[c], self.left[c])) catch {};
                }
            }
            out.append(self.a, '\n') catch {};
        }

        writeStdout(out.items);
    }
};

fn usePercent(used: u64, avail: u64) u64 {
    const usable = used +| avail;
    if (usable == 0) return 0;
    return ceilDiv(used *| 100, usable);
}

fn buildTable(a: std.mem.Allocator, cfg: *const Config, rows: []const Row) Table {
    var t = Table{ .a = a };

    // columns
    t.addCol("Filesystem", true, 0);
    if (cfg.show_type) t.addCol("Type", true, 0);
    if (cfg.show_inodes) {
        t.addCol("Inodes", false, SIZE_COL_MIN);
        t.addCol("IUsed", false, SIZE_COL_MIN);
        t.addCol("IFree", false, SIZE_COL_MIN);
        t.addCol("IUse%", false, 0);
    } else if (cfg.human_readable) {
        t.addCol("Size", false, SIZE_COL_MIN);
        t.addCol("Used", false, SIZE_COL_MIN);
        t.addCol("Avail", false, SIZE_COL_MIN);
        t.addCol("Use%", false, 0);
    } else {
        t.addCol(blockHeader(a, cfg.block_size), false, SIZE_COL_MIN);
        t.addCol("Used", false, SIZE_COL_MIN);
        t.addCol("Available", false, SIZE_COL_MIN);
        t.addCol("Use%", false, 0);
    }
    t.addCol("Mounted on", true, 0);

    for (rows) |r| {
        var cells: [MAX_COLS][]const u8 = undefined;
        var c: usize = 0;
        cells[c] = r.device;
        c += 1;
        if (cfg.show_type) {
            cells[c] = r.fstype;
            c += 1;
        }
        if (cfg.show_inodes) {
            const used = r.files -| r.ffree;
            cells[c] = fmtU64(a, r.files);
            c += 1;
            cells[c] = fmtU64(a, used);
            c += 1;
            cells[c] = fmtU64(a, r.ffree);
            c += 1;
            cells[c] = std.fmt.allocPrint(a, "{d}%", .{usePercent(used, r.ffree)}) catch "0%";
            c += 1;
        } else {
            const total_bytes = r.blocks *| r.frag_size;
            const used_bytes = (r.blocks -| r.bfree) *| r.frag_size;
            const avail_bytes = r.bavail *| r.frag_size;
            const used_blocks = r.blocks -| r.bfree;
            if (cfg.human_readable) {
                cells[c] = fmtHuman(a, total_bytes, cfg.human_base);
                c += 1;
                cells[c] = fmtHuman(a, used_bytes, cfg.human_base);
                c += 1;
                cells[c] = fmtHuman(a, avail_bytes, cfg.human_base);
                c += 1;
            } else {
                cells[c] = fmtU64(a, ceilDiv(total_bytes, cfg.block_size));
                c += 1;
                cells[c] = fmtU64(a, ceilDiv(used_bytes, cfg.block_size));
                c += 1;
                cells[c] = fmtU64(a, ceilDiv(avail_bytes, cfg.block_size));
                c += 1;
            }
            cells[c] = std.fmt.allocPrint(a, "{d}%", .{usePercent(used_blocks, r.bavail)}) catch "0%";
            c += 1;
        }
        cells[c] = r.mount;
        t.addRow(cells);
    }

    return t;
}

fn appendTotalsRow(a: std.mem.Allocator, cfg: *const Config, rows: []const Row, out: *std.ArrayList(Row)) void {
    var total_bytes: u64 = 0;
    var used_bytes: u64 = 0;
    var avail_bytes: u64 = 0;
    var total_inodes: u64 = 0;
    var free_inodes: u64 = 0;
    for (rows) |r| {
        total_bytes +|= r.blocks *| r.frag_size;
        used_bytes +|= (r.blocks -| r.bfree) *| r.frag_size;
        avail_bytes +|= r.bavail *| r.frag_size;
        total_inodes +|= r.files;
        free_inodes +|= r.ffree;
    }
    _ = cfg;
    // Represent the aggregate with frag_size == 1 so downstream math is in bytes.
    out.append(a, .{
        .device = "total",
        .mount = "-",
        .fstype = "-",
        .frag_size = 1,
        .blocks = total_bytes,
        .bfree = total_bytes -| used_bytes,
        .bavail = avail_bytes,
        .files = total_inodes,
        .ffree = free_inodes,
    }) catch {};
}

// ---------------------------------------------------------------------------
// Platform mount enumeration / per-path stat
// ---------------------------------------------------------------------------

fn dupZ(a: std.mem.Allocator, s: []const u8) []const u8 {
    return a.dupe(u8, s) catch "";
}

fn appendDarwin(a: std.mem.Allocator, out: *std.ArrayList(Row), s: *const DarwinStatfs) void {
    out.append(a, .{
        .device = dupZ(a, std.mem.sliceTo(&s.f_mntfromname, 0)),
        .mount = dupZ(a, std.mem.sliceTo(&s.f_mntonname, 0)),
        .fstype = dupZ(a, std.mem.sliceTo(&s.f_fstypename, 0)),
        .frag_size = s.f_bsize,
        .blocks = s.f_blocks,
        .bfree = s.f_bfree,
        .bavail = s.f_bavail,
        .files = s.f_files,
        .ffree = s.f_ffree,
    }) catch {};
}

/// Enumerate every mounted filesystem. Returns false if the mount table could
/// not be read.
fn collectAll(a: std.mem.Allocator, out: *std.ArrayList(Row)) bool {
    if (is_darwin) {
        var mnt: [*]DarwinStatfs = undefined;
        const n = getmntinfo(&mnt, MNT_NOWAIT);
        if (n <= 0) return false;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            // Skip pseudo/empty filesystems (GNU hides these without -a).
            if (mnt[i].f_blocks == 0) continue;
            appendDarwin(a, out, &mnt[i]);
        }
        return true;
    } else {
        return collectAllLinux(a, out);
    }
}

/// Stat a single path; appends one Row. Returns false on failure (missing
/// path), in which case the caller emits an error and sets exit status 1.
fn collectPath(a: std.mem.Allocator, out: *std.ArrayList(Row), path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
    if (is_darwin) {
        var s: DarwinStatfs = undefined;
        if (statfs(path_z.ptr, &s) != 0) return false;
        appendDarwin(a, out, &s);
        return true;
    } else {
        return collectPathLinux(a, out, path, path_z);
    }
}

// --- Linux backend ---------------------------------------------------------

fn readAllFile(path: [*:0]const u8, buf: []u8) usize {
    const fd = libc.open(path, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return 0;
    defer _ = libc.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = libc.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

fn collectAllLinux(a: std.mem.Allocator, out: *std.ArrayList(Row)) bool {
    var buf: [65536]u8 = undefined;
    var n = readAllFile("/etc/mtab", &buf);
    if (n == 0) n = readAllFile("/proc/mounts", &buf);
    if (n == 0) return false;

    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const device = fields.next() orelse continue;
        const mount_point = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;
        if (isPseudoFs(fstype)) continue;
        statvfsAppend(a, out, device, mount_point, fstype);
    }
    return true;
}

fn statvfsAppend(a: std.mem.Allocator, out: *std.ArrayList(Row), device: []const u8, mount_point: []const u8, fstype: []const u8) void {
    var mbuf: [4096]u8 = undefined;
    const mz = std.fmt.bufPrintZ(&mbuf, "{s}", .{mount_point}) catch return;
    var st: LinuxStatvfs = undefined;
    if (statvfs(mz.ptr, &st) != 0) return;
    if (st.f_blocks == 0) return;
    out.append(a, .{
        .device = dupZ(a, device),
        .mount = dupZ(a, mount_point),
        .fstype = dupZ(a, fstype),
        .frag_size = st.f_frsize,
        .blocks = st.f_blocks,
        .bfree = st.f_bfree,
        .bavail = st.f_bavail,
        .files = st.f_files,
        .ffree = st.f_ffree,
    }) catch {};
}

fn collectPathLinux(a: std.mem.Allocator, out: *std.ArrayList(Row), path: []const u8, path_z: [:0]const u8) bool {
    var st: LinuxStatvfs = undefined;
    if (statvfs(path_z.ptr, &st) != 0) return false;

    // Resolve device/mount/fstype from /proc/mounts (longest-prefix match).
    var device: []const u8 = path;
    var mount: []const u8 = path;
    var fstype: []const u8 = "-";
    var best_len: usize = 0;

    var buf: [65536]u8 = undefined;
    const n = readAllFile("/proc/mounts", &buf);
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const dev = fields.next() orelse continue;
        const mp = fields.next() orelse continue;
        const ft = fields.next() orelse continue;
        const matches = std.mem.eql(u8, mp, "/") or
            (std.mem.startsWith(u8, path, mp) and
                (path.len == mp.len or path[mp.len] == '/'));
        if (matches and mp.len > best_len) {
            best_len = mp.len;
            device = dupZ(a, dev);
            mount = dupZ(a, mp);
            fstype = dupZ(a, ft);
        }
    }

    out.append(a, .{
        .device = device,
        .mount = mount,
        .fstype = fstype,
        .frag_size = st.f_frsize,
        .blocks = st.f_blocks,
        .bfree = st.f_bfree,
        .bavail = st.f_bavail,
        .files = st.f_files,
        .ffree = st.f_ffree,
    }) catch {};
    return true;
}

fn isPseudoFs(fstype: []const u8) bool {
    const skip = [_][]const u8{
        "proc",        "sysfs",  "devpts",  "securityfs", "cgroup",
        "cgroup2",     "pstore", "bpf",     "tracefs",    "debugfs",
        "hugetlbfs",   "mqueue", "fusectl", "configfs",   "efivarfs",
        "autofs",      "devtmpfs",
    };
    for (skip) |s| {
        if (std.mem.eql(u8, fstype, s)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

fn printHelp() void {
    const usage =
        \\Usage: zdf [OPTION]... [FILE]...
        \\Show information about the file system on which each FILE resides,
        \\or all file systems by default.
        \\
        \\Options:
        \\  -h, --human-readable  Print sizes in human readable format (e.g., 1K 234M 2G)
        \\  -H, --si              Like -h, but use powers of 1000 not 1024
        \\  -i, --inodes          List inode information instead of block usage
        \\  -T, --print-type      Print file system type
        \\  -B, --block-size=SIZE Scale sizes by SIZE before printing
        \\  -k                    Like --block-size=1K
        \\      --total           Print a grand total line
        \\      --help            Display this help and exit
        \\      --version         Output version information and exit
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zdf " ++ VERSION ++ "\n");
}

fn errInvalidShort(c: u8) noreturn {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zdf: invalid option -- '{c}'\n", .{c}) catch "zdf: invalid option\n";
    writeStderr(msg);
    writeStderr("Try 'zdf --help' for more information.\n");
    std.process.exit(1);
}

fn errInvalidLong(opt: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zdf: unrecognized option '{s}'\n", .{opt}) catch "zdf: unrecognized option\n";
    writeStderr(msg);
    writeStderr("Try 'zdf --help' for more information.\n");
    std.process.exit(1);
}

pub fn main(init: std.process.Init) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = Config{};
    var paths: std.ArrayList([]const u8) = .empty;
    var status: u8 = 0;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // program name
    var options_done = false;

    while (it.next()) |arg| {
        if (!options_done and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // long option
            if (std.mem.eql(u8, arg, "--")) {
                options_done = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--human-readable")) {
                cfg.human_readable = true;
                cfg.human_base = 1024;
            } else if (std.mem.eql(u8, arg, "--si")) {
                cfg.human_readable = true;
                cfg.human_base = 1000;
            } else if (std.mem.eql(u8, arg, "--inodes")) {
                cfg.show_inodes = true;
            } else if (std.mem.eql(u8, arg, "--print-type")) {
                cfg.show_type = true;
            } else if (std.mem.eql(u8, arg, "--total")) {
                cfg.show_total = true;
            } else if (std.mem.startsWith(u8, arg, "--block-size=")) {
                const val = arg["--block-size=".len..];
                cfg.block_size = parseSize(val) orelse {
                    writeStderr("zdf: invalid --block-size argument\n");
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, arg, "--block-size")) {
                const val = it.next() orelse {
                    writeStderr("zdf: option '--block-size' requires an argument\n");
                    std.process.exit(1);
                };
                cfg.block_size = parseSize(val) orelse {
                    writeStderr("zdf: invalid --block-size argument\n");
                    std.process.exit(1);
                };
            } else {
                errInvalidLong(arg);
            }
        } else if (!options_done and arg.len >= 2 and arg[0] == '-') {
            // short-option cluster
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'h' => {
                        cfg.human_readable = true;
                        cfg.human_base = 1024;
                    },
                    'H' => {
                        cfg.human_readable = true;
                        cfg.human_base = 1000;
                    },
                    'i' => cfg.show_inodes = true,
                    'T' => cfg.show_type = true,
                    'k' => cfg.block_size = 1024,
                    'B' => {
                        const rest = arg[j + 1 ..];
                        const val = if (rest.len > 0) rest else (it.next() orelse {
                            writeStderr("zdf: option requires an argument -- 'B'\n");
                            std.process.exit(1);
                        });
                        cfg.block_size = parseSize(val) orelse {
                            writeStderr("zdf: invalid -B argument\n");
                            std.process.exit(1);
                        };
                        break; // rest of cluster consumed as the value
                    },
                    else => errInvalidShort(arg[j]),
                }
            }
        } else {
            paths.append(a, arg) catch {};
        }
    }

    var rows: std.ArrayList(Row) = .empty;

    if (paths.items.len > 0) {
        for (paths.items) |path| {
            if (!collectPath(a, &rows, path)) {
                var buf: [4200]u8 = undefined;
                const errstr = std.mem.sliceTo(strerror(std.c._errno().*), 0);
                const msg = std.fmt.bufPrint(&buf, "zdf: {s}: {s}\n", .{ path, errstr }) catch "zdf: cannot access path\n";
                writeStderr(msg);
                status = 1;
            }
        }
        if (rows.items.len == 0) std.process.exit(status);
    } else {
        if (!collectAll(a, &rows)) {
            writeStderr("zdf: cannot read table of mounted file systems\n");
            std.process.exit(1);
        }
    }

    if (cfg.show_total) {
        appendTotalsRow(a, &cfg, rows.items, &rows);
    }

    var table = buildTable(a, &cfg, rows.items);
    table.emit();

    std.process.exit(status);
}
