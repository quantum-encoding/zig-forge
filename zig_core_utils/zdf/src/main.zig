//! zdf - Report file system disk space usage
//!
//! High-performance df implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

// statvfs structure (Linux x86_64)
const Statvfs = extern struct {
    f_bsize: c_ulong,      // Filesystem block size
    f_frsize: c_ulong,     // Fragment size
    f_blocks: u64,         // Total blocks
    f_bfree: u64,          // Free blocks
    f_bavail: u64,         // Available blocks (non-root)
    f_files: u64,          // Total inodes
    f_ffree: u64,          // Free inodes
    f_favail: u64,         // Available inodes (non-root)
    f_fsid: c_ulong,       // Filesystem ID
    f_flag: c_ulong,       // Mount flags
    f_namemax: c_ulong,    // Max filename length
    __f_spare: [6]c_int,   // Padding
};

extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

const Config = struct {
    human_readable: bool = false,
    show_inodes: bool = false,
    show_type: bool = false,
    show_total: bool = false,
    block_size: usize = 1024, // Default 1K blocks
    paths: [64][]const u8 = undefined,
    path_count: usize = 0,
};

const Totals = struct {
    total_bytes: u64 = 0,
    used_bytes: u64 = 0,
    avail_bytes: u64 = 0,
    total_inodes: u64 = 0,
    used_inodes: u64 = 0,
    free_inodes: u64 = 0,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
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
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zdf " ++ VERSION ++ "\n");
}

fn formatSize(size: u64, human: bool, buf: []u8) []const u8 {
    if (!human) {
        return std.fmt.bufPrint(buf, "{d:>10}", .{size}) catch buf[0..0];
    }
    
    const units = [_][]const u8{ "B", "K", "M", "G", "T", "P" };
    var val: f64 = @floatFromInt(size);
    var unit_idx: usize = 0;
    
    while (val >= 1024 and unit_idx < units.len - 1) {
        val /= 1024;
        unit_idx += 1;
    }
    
    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d:>6}", .{size}) catch buf[0..0];
    } else if (val >= 100) {
        return std.fmt.bufPrint(buf, "{d:>5.0}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
    } else if (val >= 10) {
        return std.fmt.bufPrint(buf, "{d:>5.1}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
    } else {
        return std.fmt.bufPrint(buf, "{d:>5.2}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
    }
}

fn printHeader(cfg: *const Config) void {
    if (cfg.show_inodes) {
        writeStdout("Filesystem           Inodes    IUsed    IFree IUse% Mounted on\n");
    } else {
        if (cfg.show_type) {
            if (cfg.human_readable) {
                writeStdout("Filesystem     Type      Size   Used  Avail Use% Mounted on\n");
            } else {
                writeStdout("Filesystem     Type      1K-blocks      Used Available Use% Mounted on\n");
            }
        } else {
            if (cfg.human_readable) {
                writeStdout("Filesystem        Size   Used  Avail Use% Mounted on\n");
            } else {
                writeStdout("Filesystem       1K-blocks      Used Available Use% Mounted on\n");
            }
        }
    }
}

fn printFilesystem(device: []const u8, mount_point: []const u8, fstype: []const u8, cfg: *const Config, totals: *Totals) void {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{mount_point}) catch return;

    var stat: Statvfs = undefined;
    if (statvfs(path_z, &stat) != 0) return;

    // Skip pseudo filesystems with 0 blocks
    if (stat.f_blocks == 0) return;

    var line_buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Device name (left-aligned)
    if (cfg.show_type) {
        const dev_part = std.fmt.bufPrint(line_buf[pos..], "{s:<14} ", .{device}) catch return;
        pos += dev_part.len;
        const type_display = if (fstype.len > 8) fstype[0..8] else fstype;
        const type_part = std.fmt.bufPrint(line_buf[pos..], "{s:<8} ", .{type_display}) catch return;
        pos += type_part.len;
    } else {
        const dev_part = std.fmt.bufPrint(line_buf[pos..], "{s:<18} ", .{device}) catch return;
        pos += dev_part.len;
    }

    if (cfg.show_inodes) {
        // Inode mode
        const total_inodes = stat.f_files;
        const free_inodes = stat.f_ffree;
        const used_inodes = total_inodes - free_inodes;
        const use_pct: u64 = if (total_inodes > 0) (used_inodes * 100) / total_inodes else 0;

        // Accumulate totals
        totals.total_inodes += total_inodes;
        totals.used_inodes += used_inodes;
        totals.free_inodes += free_inodes;

        const inode_part = std.fmt.bufPrint(line_buf[pos..], "{d:>10} {d:>8} {d:>8} {d:>3}% {s}\n", .{
            total_inodes, used_inodes, free_inodes, use_pct, mount_point,
        }) catch return;
        pos += inode_part.len;
    } else {
        // Block mode
        const block_size = stat.f_frsize;
        const total_bytes = stat.f_blocks * block_size;
        const free_bytes = stat.f_bfree * block_size;
        const avail_bytes = stat.f_bavail * block_size;
        const used_bytes = total_bytes - free_bytes;

        // Accumulate totals
        totals.total_bytes += total_bytes;
        totals.used_bytes += used_bytes;
        totals.avail_bytes += avail_bytes;

        // Calculate percentage (avoid division by zero)
        const used_blocks = stat.f_blocks - stat.f_bfree;
        const total_usable = stat.f_blocks - stat.f_bfree + stat.f_bavail;
        const use_pct: u64 = if (total_usable > 0) (used_blocks * 100) / total_usable else 0;

        if (cfg.human_readable) {
            var size_buf: [16]u8 = undefined;
            var used_buf: [16]u8 = undefined;
            var avail_buf: [16]u8 = undefined;

            const size_str = formatSize(total_bytes, true, &size_buf);
            const used_str = formatSize(used_bytes, true, &used_buf);
            const avail_str = formatSize(avail_bytes, true, &avail_buf);

            const block_part = std.fmt.bufPrint(line_buf[pos..], "{s} {s} {s} {d:>3}% {s}\n", .{
                size_str, used_str, avail_str, use_pct, mount_point,
            }) catch return;
            pos += block_part.len;
        } else {
            // 1K blocks
            const total_1k = total_bytes / 1024;
            const used_1k = used_bytes / 1024;
            const avail_1k = avail_bytes / 1024;

            const block_part = std.fmt.bufPrint(line_buf[pos..], "{d:>12} {d:>9} {d:>9} {d:>3}% {s}\n", .{
                total_1k, used_1k, avail_1k, use_pct, mount_point,
            }) catch return;
            pos += block_part.len;
        }
    }

    writeStdout(line_buf[0..pos]);
}

fn printTotals(cfg: *const Config, totals: *const Totals) void {
    var line_buf: [512]u8 = undefined;
    var pos: usize = 0;

    const label_part = std.fmt.bufPrint(line_buf[pos..], "{s:<18} ", .{"total"}) catch return;
    pos += label_part.len;

    if (cfg.show_type) {
        const type_part = std.fmt.bufPrint(line_buf[pos..], "{s:<8} ", .{"-"}) catch return;
        pos += type_part.len;
    }

    if (cfg.show_inodes) {
        const use_pct: u64 = if (totals.total_inodes > 0) (totals.used_inodes * 100) / totals.total_inodes else 0;
        const inode_part = std.fmt.bufPrint(line_buf[pos..], "{d:>10} {d:>8} {d:>8} {d:>3}% -\n", .{
            totals.total_inodes, totals.used_inodes, totals.free_inodes, use_pct,
        }) catch return;
        pos += inode_part.len;
    } else {
        const total_usable = totals.used_bytes + totals.avail_bytes;
        const use_pct: u64 = if (total_usable > 0) (totals.used_bytes * 100) / total_usable else 0;

        if (cfg.human_readable) {
            var size_buf: [16]u8 = undefined;
            var used_buf: [16]u8 = undefined;
            var avail_buf: [16]u8 = undefined;

            const size_str = formatSize(totals.total_bytes, true, &size_buf);
            const used_str = formatSize(totals.used_bytes, true, &used_buf);
            const avail_str = formatSize(totals.avail_bytes, true, &avail_buf);

            const block_part = std.fmt.bufPrint(line_buf[pos..], "{s} {s} {s} {d:>3}% -\n", .{
                size_str, used_str, avail_str, use_pct,
            }) catch return;
            pos += block_part.len;
        } else {
            const total_1k = totals.total_bytes / 1024;
            const used_1k = totals.used_bytes / 1024;
            const avail_1k = totals.avail_bytes / 1024;

            const block_part = std.fmt.bufPrint(line_buf[pos..], "{d:>12} {d:>9} {d:>9} {d:>3}% -\n", .{
                total_1k, used_1k, avail_1k, use_pct,
            }) catch return;
            pos += block_part.len;
        }
    }

    writeStdout(line_buf[0..pos]);
}

fn parseMounts(cfg: *const Config, totals: *Totals) void {
    // Read /proc/mounts (Linux) or use getmntinfo (macOS)
    const fd = libc.open("/etc/mtab", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        // Try /proc/mounts on Linux
        const fd2 = libc.open("/proc/mounts", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd2 < 0) {
            writeStderr("zdf: cannot read mount information\n");
            return;
        }
        return parseMountsWithFd(fd2, cfg, totals);
    }
    return parseMountsWithFd(fd, cfg, totals);
}

fn parseMountsWithFd(fd: c_int, cfg: *const Config, totals: *Totals) void {
    defer _ = libc.close(fd);

    var buf: [32768]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buf.len) {
        const n = libc.read(fd, buf[total_read..].ptr, buf.len - total_read);
        if (n <= 0) break;
        total_read += @intCast(n);
    }

    const data = buf[0..total_read];

    // Parse each line
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Format: device mount_point fstype options dump pass
        var fields = std.mem.splitScalar(u8, line, ' ');
        const device = fields.next() orelse continue;
        const mount_point = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;

        // Skip certain pseudo filesystems
        if (std.mem.eql(u8, fstype, "proc")) continue;
        if (std.mem.eql(u8, fstype, "sysfs")) continue;
        if (std.mem.eql(u8, fstype, "devpts")) continue;
        if (std.mem.eql(u8, fstype, "securityfs")) continue;
        if (std.mem.eql(u8, fstype, "cgroup")) continue;
        if (std.mem.eql(u8, fstype, "cgroup2")) continue;
        if (std.mem.eql(u8, fstype, "pstore")) continue;
        if (std.mem.eql(u8, fstype, "bpf")) continue;
        if (std.mem.eql(u8, fstype, "tracefs")) continue;
        if (std.mem.eql(u8, fstype, "debugfs")) continue;
        if (std.mem.eql(u8, fstype, "hugetlbfs")) continue;
        if (std.mem.eql(u8, fstype, "mqueue")) continue;
        if (std.mem.eql(u8, fstype, "fusectl")) continue;
        if (std.mem.eql(u8, fstype, "configfs")) continue;
        if (std.mem.eql(u8, fstype, "efivarfs")) continue;
        if (std.mem.eql(u8, fstype, "autofs")) continue;

        printFilesystem(device, mount_point, fstype, cfg, totals);
    }
}

fn findMountInfo(path: []const u8, out_device: *[256]u8, out_mount: *[256]u8, out_fstype: *[64]u8) struct { device: []const u8, mount: []const u8, fstype: []const u8 } {
    // Read /proc/mounts to find the device and mount point for a path
    const fd = libc.open("/proc/mounts", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return .{ .device = path, .mount = path, .fstype = "-" };
    defer _ = libc.close(fd);

    var buf: [32768]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < buf.len) {
        const n = libc.read(fd, buf[total_read..].ptr, buf.len - total_read);
        if (n <= 0) break;
        total_read += @intCast(n);
    }

    var best_device: []const u8 = path;
    var best_mount: []const u8 = path;
    var best_fstype: []const u8 = "-";
    var best_mount_len: usize = 0;

    var lines = std.mem.splitScalar(u8, buf[0..total_read], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const device = fields.next() orelse continue;
        const mount_point = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;

        // Check if path starts with this mount point (longest match wins)
        if (std.mem.eql(u8, mount_point, "/") or
            (std.mem.startsWith(u8, path, mount_point) and
            (path.len == mount_point.len or path[mount_point.len] == '/')))
        {
            if (mount_point.len > best_mount_len) {
                best_mount_len = mount_point.len;
                // Copy to output buffers so they outlive this function's stack
                @memcpy(out_device[0..device.len], device);
                best_device = out_device[0..device.len];
                @memcpy(out_mount[0..mount_point.len], mount_point);
                best_mount = out_mount[0..mount_point.len];
                const ft_len = @min(fstype.len, out_fstype.len);
                @memcpy(out_fstype[0..ft_len], fstype[0..ft_len]);
                best_fstype = out_fstype[0..ft_len];
            }
        }
    }

    return .{ .device = best_device, .mount = best_mount, .fstype = best_fstype };
}

fn showPathInfo(path: []const u8, cfg: *const Config, totals: *Totals) void {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;

    var stat: Statvfs = undefined;
    if (statvfs(path_z, &stat) != 0) {
        writeStderr("zdf: cannot access '");
        writeStderr(path);
        writeStderr("'\n");
        return;
    }

    // Resolve actual device and mount point from /proc/mounts
    var dev_buf: [256]u8 = undefined;
    var mnt_buf: [256]u8 = undefined;
    var fst_buf: [64]u8 = undefined;
    const info = findMountInfo(path, &dev_buf, &mnt_buf, &fst_buf);
    printFilesystem(info.device, info.mount, info.fstype, cfg, totals);
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--human-readable")) {
            cfg.human_readable = true;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--si")) {
            cfg.human_readable = true; // Simplified: same as -h
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--inodes")) {
            cfg.show_inodes = true;
        } else if (std.mem.eql(u8, arg, "-T") or std.mem.eql(u8, arg, "--print-type")) {
            cfg.show_type = true;
        } else if (std.mem.eql(u8, arg, "--total")) {
            cfg.show_total = true;
        } else if (std.mem.eql(u8, arg, "-k")) {
            cfg.block_size = 1024;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (cfg.path_count < cfg.paths.len) {
                cfg.paths[cfg.path_count] = arg;
                cfg.path_count += 1;
            }
        }
    }

    printHeader(&cfg);

    var totals = Totals{};

    if (cfg.path_count > 0) {
        // Show specific paths
        for (cfg.paths[0..cfg.path_count]) |path| {
            showPathInfo(path, &cfg, &totals);
        }
    } else {
        // Show all mounted filesystems
        parseMounts(&cfg, &totals);
    }

    if (cfg.show_total) {
        printTotals(&cfg, &totals);
    }
}
