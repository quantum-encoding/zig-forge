// System information collector — reads from /proc on Linux.
// Abstracted for future Zigix kernel integration via the same /proc interface.

const std = @import("std");

pub const MAX_CORES: u8 = 16;
pub const MAX_NET_IFACES: u8 = 8;

pub const NetInterface = struct {
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: usize = 0,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rx_packets: u64 = 0,
    tx_packets: u64 = 0,
    rx_errors: u64 = 0,
    tx_errors: u64 = 0,
    rx_dropped: u64 = 0,
    tx_dropped: u64 = 0,
};

pub const SystemSnapshot = struct {
    // CPU
    cpu_count: u8 = 0,
    cpu_usage: [MAX_CORES]f32 = [_]f32{0} ** MAX_CORES,
    cpu_total: f32 = 0,

    // Memory (kilobytes)
    mem_total_kb: u64 = 0,
    mem_available_kb: u64 = 0,
    mem_used_kb: u64 = 0,
    mem_buffers_kb: u64 = 0,
    mem_cached_kb: u64 = 0,
    swap_total_kb: u64 = 0,
    swap_free_kb: u64 = 0,

    // Load averages
    load_1: f32 = 0,
    load_5: f32 = 0,
    load_15: f32 = 0,

    // Uptime
    uptime_secs: u64 = 0,

    // System identity
    hostname: [64]u8 = [_]u8{0} ** 64,
    hostname_len: usize = 0,
    kernel_version: [64]u8 = [_]u8{0} ** 64,
    kernel_version_len: usize = 0,
    machine: [16]u8 = [_]u8{0} ** 16,
    machine_len: usize = 0,

    // Disk (root filesystem)
    disk_total_kb: u64 = 0,
    disk_used_kb: u64 = 0,

    // Network
    net_ifaces: [MAX_NET_IFACES]NetInterface = [_]NetInterface{.{}} ** MAX_NET_IFACES,
    net_iface_count: u8 = 0,

    // Timestamp
    timestamp_secs: i64 = 0,
};

const CpuTimes = struct {
    user: u64 = 0,
    nice: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    irq: u64 = 0,
    softirq: u64 = 0,
    steal: u64 = 0,

    fn total(self: CpuTimes) u64 {
        return self.user + self.nice + self.system + self.idle +
            self.iowait + self.irq + self.softirq + self.steal;
    }

    fn busy(self: CpuTimes) u64 {
        return self.total() - self.idle - self.iowait;
    }
};

// 0 = aggregate total, 1..MAX_CORES = per-core
const CpuTimesArray = [MAX_CORES + 1]CpuTimes;

pub const SysInfoCollector = struct {
    prev_cpu: CpuTimesArray = [_]CpuTimes{.{}} ** (MAX_CORES + 1),
    has_prev: bool = false,
    identity_loaded: bool = false,
    // Cached identity (only read once)
    cached_hostname: [64]u8 = [_]u8{0} ** 64,
    cached_hostname_len: usize = 0,
    cached_kernel: [64]u8 = [_]u8{0} ** 64,
    cached_kernel_len: usize = 0,
    cached_machine: [16]u8 = [_]u8{0} ** 16,
    cached_machine_len: usize = 0,

    pub fn collect(self: *SysInfoCollector) SystemSnapshot {
        var snap = SystemSnapshot{};

        // System identity (once)
        if (!self.identity_loaded) {
            self.loadIdentity();
        }
        @memcpy(snap.hostname[0..self.cached_hostname_len], self.cached_hostname[0..self.cached_hostname_len]);
        snap.hostname_len = self.cached_hostname_len;
        @memcpy(snap.kernel_version[0..self.cached_kernel_len], self.cached_kernel[0..self.cached_kernel_len]);
        snap.kernel_version_len = self.cached_kernel_len;
        @memcpy(snap.machine[0..self.cached_machine_len], self.cached_machine[0..self.cached_machine_len]);
        snap.machine_len = self.cached_machine_len;

        // Parse /proc files
        self.parseCpuStat(&snap);
        parseMeminfo(&snap);
        parseUptime(&snap);
        parseLoadAvg(&snap);
        parseNetDev(&snap);
        getDiskUsage(&snap);

        // Timestamp via clock_gettime
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        snap.timestamp_secs = ts.sec;

        return snap;
    }

    fn loadIdentity(self: *SysInfoCollector) void {
        // Use uname(2) — returns struct directly in Zig 0.16
        const uts = std.posix.uname();

        // Hostname
        const nodename = std.mem.sliceTo(&uts.nodename, 0);
        const hn_len = @min(nodename.len, self.cached_hostname.len);
        @memcpy(self.cached_hostname[0..hn_len], nodename[0..hn_len]);
        self.cached_hostname_len = hn_len;

        // Kernel version: "sysname release"
        const sysname = std.mem.sliceTo(&uts.sysname, 0);
        const release = std.mem.sliceTo(&uts.release, 0);
        const kv = std.fmt.bufPrint(&self.cached_kernel, "{s} {s}", .{ sysname, release }) catch "?";
        self.cached_kernel_len = kv.len;

        // Machine arch
        const machine = std.mem.sliceTo(&uts.machine, 0);
        const m_len = @min(machine.len, self.cached_machine.len);
        @memcpy(self.cached_machine[0..m_len], machine[0..m_len]);
        self.cached_machine_len = m_len;

        self.identity_loaded = true;
    }

    fn parseCpuStat(self: *SysInfoCollector, snap: *SystemSnapshot) void {
        var buf: [4096]u8 = undefined;
        const data = readProcFile("/proc/stat", &buf) orelse return;

        var current: CpuTimesArray = [_]CpuTimes{.{}} ** (MAX_CORES + 1);
        var core_idx: u8 = 0;

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len < 3) continue;

            // "cpu " (aggregate) or "cpu0 ", "cpu1 ", etc.
            const is_total = std.mem.startsWith(u8, line, "cpu ");
            const is_core = std.mem.startsWith(u8, line, "cpu") and line.len > 3 and line[3] >= '0' and line[3] <= '9';

            if (!is_total and !is_core) continue;

            // Skip the "cpuN " prefix
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            _ = it.next(); // skip "cpu" or "cpuN"

            var times = CpuTimes{};
            if (it.next()) |v| times.user = std.fmt.parseInt(u64, v, 10) catch 0;
            if (it.next()) |v| times.nice = std.fmt.parseInt(u64, v, 10) catch 0;
            if (it.next()) |v| times.system = std.fmt.parseInt(u64, v, 10) catch 0;
            if (it.next()) |v| times.idle = std.fmt.parseInt(u64, v, 10) catch 0;
            if (it.next()) |v| times.iowait = std.fmt.parseInt(u64, v, 10) catch 0;
            if (it.next()) |v| times.irq = std.fmt.parseInt(u64, v, 10) catch 0;
            if (it.next()) |v| times.softirq = std.fmt.parseInt(u64, v, 10) catch 0;
            if (it.next()) |v| times.steal = std.fmt.parseInt(u64, v, 10) catch 0;

            if (is_total) {
                current[0] = times;
            } else if (core_idx < MAX_CORES) {
                current[core_idx + 1] = times;
                core_idx += 1;
            }
        }

        snap.cpu_count = core_idx;

        // Compute usage from delta if we have a previous sample
        if (self.has_prev) {
            // Total CPU
            const dt = current[0].total() -| self.prev_cpu[0].total();
            const db = current[0].busy() -| self.prev_cpu[0].busy();
            snap.cpu_total = if (dt > 0) @as(f32, @floatFromInt(db)) / @as(f32, @floatFromInt(dt)) * 100.0 else 0;

            // Per-core
            var i: u8 = 0;
            while (i < core_idx) : (i += 1) {
                const idx = @as(usize, i) + 1;
                const cdt = current[idx].total() -| self.prev_cpu[idx].total();
                const cdb = current[idx].busy() -| self.prev_cpu[idx].busy();
                snap.cpu_usage[i] = if (cdt > 0) @as(f32, @floatFromInt(cdb)) / @as(f32, @floatFromInt(cdt)) * 100.0 else 0;
            }
        }

        self.prev_cpu = current;
        self.has_prev = true;
    }
};

fn parseMeminfo(snap: *SystemSnapshot) void {
    var buf: [4096]u8 = undefined;
    const data = readProcFile("/proc/meminfo", &buf) orelse return;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const val = extractKbValue(line);

        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            snap.mem_total_kb = val;
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            snap.mem_available_kb = val;
        } else if (std.mem.startsWith(u8, line, "Buffers:")) {
            snap.mem_buffers_kb = val;
        } else if (std.mem.startsWith(u8, line, "Cached:")) {
            snap.mem_cached_kb = val;
        } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            snap.swap_total_kb = val;
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            snap.swap_free_kb = val;
        }
    }

    snap.mem_used_kb = snap.mem_total_kb -| snap.mem_available_kb;
}

fn parseUptime(snap: *SystemSnapshot) void {
    var buf: [128]u8 = undefined;
    const data = readProcFile("/proc/uptime", &buf) orelse return;

    // Format: "12345.67 98765.43"
    var it = std.mem.tokenizeScalar(u8, data, ' ');
    if (it.next()) |val| {
        // Parse integer part before the decimal
        if (std.mem.indexOfScalar(u8, val, '.')) |dot| {
            snap.uptime_secs = std.fmt.parseInt(u64, val[0..dot], 10) catch 0;
        } else {
            snap.uptime_secs = std.fmt.parseInt(u64, val, 10) catch 0;
        }
    }
}

fn parseLoadAvg(snap: *SystemSnapshot) void {
    var buf: [128]u8 = undefined;
    const data = readProcFile("/proc/loadavg", &buf) orelse return;

    var it = std.mem.tokenizeScalar(u8, data, ' ');
    if (it.next()) |v| snap.load_1 = std.fmt.parseFloat(f32, v) catch 0;
    if (it.next()) |v| snap.load_5 = std.fmt.parseFloat(f32, v) catch 0;
    if (it.next()) |v| snap.load_15 = std.fmt.parseFloat(f32, v) catch 0;
}

fn parseNetDev(snap: *SystemSnapshot) void {
    var buf: [4096]u8 = undefined;
    const data = readProcFile("/proc/net/dev", &buf) orelse return;

    var iface_idx: u8 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    // Skip first two header lines
    _ = lines.next();
    _ = lines.next();

    while (lines.next()) |line| {
        if (iface_idx >= MAX_NET_IFACES) break;
        if (line.len < 5) continue;

        // Format: "  iface: rx_bytes rx_packets rx_errs rx_drop ... tx_bytes tx_packets tx_errs tx_drop ..."
        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name_raw = std.mem.trim(u8, line[0..colon_pos], " ");
        if (name_raw.len == 0) continue;

        var iface = &snap.net_ifaces[iface_idx];
        const n_len = @min(name_raw.len, iface.name.len);
        @memcpy(iface.name[0..n_len], name_raw[0..n_len]);
        iface.name_len = n_len;

        // Parse the numeric fields after the colon
        var it = std.mem.tokenizeScalar(u8, line[colon_pos + 1 ..], ' ');
        // rx: bytes packets errs drop fifo frame compressed multicast
        if (it.next()) |v| iface.rx_bytes = std.fmt.parseInt(u64, v, 10) catch 0;
        if (it.next()) |v| iface.rx_packets = std.fmt.parseInt(u64, v, 10) catch 0;
        if (it.next()) |v| iface.rx_errors = std.fmt.parseInt(u64, v, 10) catch 0;
        if (it.next()) |v| iface.rx_dropped = std.fmt.parseInt(u64, v, 10) catch 0;
        // Skip fifo, frame, compressed, multicast
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        // tx: bytes packets errs drop ...
        if (it.next()) |v| iface.tx_bytes = std.fmt.parseInt(u64, v, 10) catch 0;
        if (it.next()) |v| iface.tx_packets = std.fmt.parseInt(u64, v, 10) catch 0;
        if (it.next()) |v| iface.tx_errors = std.fmt.parseInt(u64, v, 10) catch 0;
        if (it.next()) |v| iface.tx_dropped = std.fmt.parseInt(u64, v, 10) catch 0;

        iface_idx += 1;
    }

    snap.net_iface_count = iface_idx;
}

fn getDiskUsage(snap: *SystemSnapshot) void {
    // Use statvfs via libc
    const c = @cImport({
        @cInclude("sys/statvfs.h");
    });
    var stat: c.struct_statvfs = undefined;
    if (c.statvfs("/", &stat) == 0) {
        const block_size: u64 = stat.f_frsize;
        snap.disk_total_kb = (stat.f_blocks * block_size) / 1024;
        snap.disk_used_kb = ((stat.f_blocks - stat.f_bfree) * block_size) / 1024;
    }
}

// Utility: read an entire /proc pseudo-file into a buffer
fn readProcFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const c = @cImport({
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
    });
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);

    const n = c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

// Utility: extract the numeric kB value from a /proc/meminfo-style line
// "MemTotal:       16384000 kB" -> 16384000
fn extractKbValue(line: []const u8) u64 {
    // Find the first digit after the colon
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    const after_colon = std.mem.trimStart(u8, line[colon + 1 ..], " ");
    // Take digits until space or end
    var end: usize = 0;
    while (end < after_colon.len and after_colon[end] >= '0' and after_colon[end] <= '9') : (end += 1) {}
    if (end == 0) return 0;
    return std.fmt.parseInt(u64, after_colon[0..end], 10) catch 0;
}

// Utility: format kilobytes into human-readable string
pub fn formatKb(kb: u64, buf: []u8) []const u8 {
    if (kb >= 1048576) {
        // GB
        const gb_x10 = kb * 10 / 1048576;
        return std.fmt.bufPrint(buf, "{d}.{d} GB", .{ gb_x10 / 10, gb_x10 % 10 }) catch "?";
    } else if (kb >= 1024) {
        // MB
        const mb_x10 = kb * 10 / 1024;
        return std.fmt.bufPrint(buf, "{d}.{d} MB", .{ mb_x10 / 10, mb_x10 % 10 }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d} KB", .{kb}) catch "?";
    }
}

// Utility: format uptime seconds to "Xd Xh Xm Xs"
pub fn formatUptime(secs: u64, buf: []u8) []const u8 {
    const d = secs / 86400;
    const h = (secs % 86400) / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;

    if (d > 0) {
        return std.fmt.bufPrint(buf, "{d}d {d}h {d}m {d}s", .{ d, h, m, s }) catch "?";
    } else if (h > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ h, m, s }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, s }) catch "?";
    }
}

// Utility: format bytes to human-readable rate
pub fn formatRate(bytes_per_sec: u64, buf: []u8) []const u8 {
    if (bytes_per_sec >= 1073741824) {
        const v = bytes_per_sec * 10 / 1073741824;
        return std.fmt.bufPrint(buf, "{d}.{d} GB/s", .{ v / 10, v % 10 }) catch "?";
    } else if (bytes_per_sec >= 1048576) {
        const v = bytes_per_sec * 10 / 1048576;
        return std.fmt.bufPrint(buf, "{d}.{d} MB/s", .{ v / 10, v % 10 }) catch "?";
    } else if (bytes_per_sec >= 1024) {
        const v = bytes_per_sec * 10 / 1024;
        return std.fmt.bufPrint(buf, "{d}.{d} KB/s", .{ v / 10, v % 10 }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d} B/s", .{bytes_per_sec}) catch "?";
    }
}
