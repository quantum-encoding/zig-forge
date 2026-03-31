// zsys - System Information Tool
// A pure Zig implementation for querying system state
// Equivalent functionality to: free, uptime, nproc, uname

const std = @import("std");

const MemoryInfo = struct {
    total: u64,
    free: u64,
    available: u64,
    buffers: u64,
    cached: u64,
    swap_total: u64,
    swap_free: u64,
    shared: u64,
};

const CpuInfo = struct {
    model_name: [128]u8,
    model_name_len: usize,
    vendor_id: [64]u8,
    vendor_id_len: usize,
    cpu_mhz: f64,
    cache_size: u64,
    physical_cores: u32,
    logical_cores: u32,

    pub fn getModelName(self: *const CpuInfo) []const u8 {
        return self.model_name[0..self.model_name_len];
    }
    pub fn getVendorId(self: *const CpuInfo) []const u8 {
        return self.vendor_id[0..self.vendor_id_len];
    }
};

const LoadAvg = struct {
    one_min: f64,
    five_min: f64,
    fifteen_min: f64,
    running_procs: u32,
    total_procs: u32,
};

const UptimeInfo = struct {
    uptime_secs: f64,
    idle_secs: f64,
};

const SystemInfo = struct {
    sysname: [65]u8,
    sysname_len: usize,
    nodename: [65]u8,
    nodename_len: usize,
    release: [65]u8,
    release_len: usize,
    version: [65]u8,
    version_len: usize,
    machine: [65]u8,
    machine_len: usize,

    pub fn getSysname(self: *const SystemInfo) []const u8 {
        return self.sysname[0..self.sysname_len];
    }
    pub fn getNodename(self: *const SystemInfo) []const u8 {
        return self.nodename[0..self.nodename_len];
    }
    pub fn getRelease(self: *const SystemInfo) []const u8 {
        return self.release[0..self.release_len];
    }
    pub fn getVersion(self: *const SystemInfo) []const u8 {
        return self.version[0..self.version_len];
    }
    pub fn getMachine(self: *const SystemInfo) []const u8 {
        return self.machine[0..self.machine_len];
    }
};

// Read a file from /proc filesystem using Zig 0.16 I/O API
fn readProcFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        return err;
    };
    defer file.close(io);

    // /proc files often report size 0, so we read in chunks
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = file.readStreaming(io, &.{&read_buf}) catch |err| {
            return err;
        };
        if (bytes_read == 0) break;
        try buffer.appendSlice(allocator, read_buf[0..bytes_read]);
    }

    return buffer.toOwnedSlice(allocator);
}

// Parse /proc/meminfo
fn parseMemoryInfo(allocator: std.mem.Allocator) !MemoryInfo {
    const contents = try readProcFile(allocator, "/proc/meminfo");
    defer allocator.free(contents);

    var info = MemoryInfo{
        .total = 0,
        .free = 0,
        .available = 0,
        .buffers = 0,
        .cached = 0,
        .swap_total = 0,
        .swap_free = 0,
        .shared = 0,
    };

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse "Key: Value kB" format
        var parts = std.mem.splitScalar(u8, line, ':');
        const key = parts.next() orelse continue;
        const rest = parts.next() orelse continue;

        // Extract numeric value
        const trimmed = std.mem.trim(u8, rest, " \t");
        var value_parts = std.mem.splitScalar(u8, trimmed, ' ');
        const value_str = value_parts.next() orelse continue;
        const value = std.fmt.parseInt(u64, value_str, 10) catch continue;

        // Values are in kB, convert to bytes
        const value_bytes = value * 1024;

        if (std.mem.eql(u8, key, "MemTotal")) {
            info.total = value_bytes;
        } else if (std.mem.eql(u8, key, "MemFree")) {
            info.free = value_bytes;
        } else if (std.mem.eql(u8, key, "MemAvailable")) {
            info.available = value_bytes;
        } else if (std.mem.eql(u8, key, "Buffers")) {
            info.buffers = value_bytes;
        } else if (std.mem.eql(u8, key, "Cached")) {
            info.cached = value_bytes;
        } else if (std.mem.eql(u8, key, "SwapTotal")) {
            info.swap_total = value_bytes;
        } else if (std.mem.eql(u8, key, "SwapFree")) {
            info.swap_free = value_bytes;
        } else if (std.mem.eql(u8, key, "Shmem")) {
            info.shared = value_bytes;
        }
    }

    return info;
}

// Parse /proc/cpuinfo
fn parseCpuInfo(allocator: std.mem.Allocator) !CpuInfo {
    const contents = try readProcFile(allocator, "/proc/cpuinfo");
    defer allocator.free(contents);

    var info: CpuInfo = undefined;
    @memset(&info.model_name, 0);
    @memset(&info.vendor_id, 0);
    info.model_name_len = 0;
    info.vendor_id_len = 0;
    info.cpu_mhz = 0;
    info.cache_size = 0;
    info.physical_cores = 0;
    info.logical_cores = 0;

    var seen_physical_ids = std.AutoHashMap(u32, void).init(allocator);
    defer seen_physical_ids.deinit();

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var parts = std.mem.splitSequence(u8, line, ": ");
        const key_part = parts.next() orelse continue;
        const value = parts.next() orelse continue;
        const key = std.mem.trim(u8, key_part, " \t");

        if (std.mem.eql(u8, key, "model name")) {
            // Store first model name found
            if (info.model_name_len == 0) {
                const copy_len = @min(value.len, info.model_name.len);
                @memcpy(info.model_name[0..copy_len], value[0..copy_len]);
                info.model_name_len = copy_len;
            }
        } else if (std.mem.eql(u8, key, "vendor_id")) {
            if (info.vendor_id_len == 0) {
                const copy_len = @min(value.len, info.vendor_id.len);
                @memcpy(info.vendor_id[0..copy_len], value[0..copy_len]);
                info.vendor_id_len = copy_len;
            }
        } else if (std.mem.eql(u8, key, "cpu MHz")) {
            if (info.cpu_mhz == 0) {
                info.cpu_mhz = std.fmt.parseFloat(f64, value) catch 0;
            }
        } else if (std.mem.eql(u8, key, "cache size")) {
            if (info.cache_size == 0) {
                // Parse "XXXX KB" format
                var cache_parts = std.mem.splitScalar(u8, value, ' ');
                const cache_str = cache_parts.next() orelse continue;
                info.cache_size = std.fmt.parseInt(u64, cache_str, 10) catch 0;
            }
        } else if (std.mem.eql(u8, key, "physical id")) {
            const phys_id = std.fmt.parseInt(u32, value, 10) catch continue;
            try seen_physical_ids.put(phys_id, {});
        } else if (std.mem.eql(u8, key, "processor")) {
            info.logical_cores += 1;
        }
    }

    info.physical_cores = @intCast(seen_physical_ids.count());
    if (info.physical_cores == 0) {
        info.physical_cores = 1; // At least 1 physical CPU
    }

    // Default values if not found
    if (info.model_name_len == 0) {
        const unknown = "Unknown";
        @memcpy(info.model_name[0..unknown.len], unknown);
        info.model_name_len = unknown.len;
    }
    if (info.vendor_id_len == 0) {
        const unknown = "Unknown";
        @memcpy(info.vendor_id[0..unknown.len], unknown);
        info.vendor_id_len = unknown.len;
    }

    return info;
}

// Parse /proc/loadavg
fn parseLoadAvg(allocator: std.mem.Allocator) !LoadAvg {
    const contents = try readProcFile(allocator, "/proc/loadavg");
    defer allocator.free(contents);

    var info = LoadAvg{
        .one_min = 0,
        .five_min = 0,
        .fifteen_min = 0,
        .running_procs = 0,
        .total_procs = 0,
    };

    // Format: "1.23 4.56 7.89 1/234 56789"
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, contents, " \n"), ' ');

    if (parts.next()) |one| {
        info.one_min = std.fmt.parseFloat(f64, one) catch 0;
    }
    if (parts.next()) |five| {
        info.five_min = std.fmt.parseFloat(f64, five) catch 0;
    }
    if (parts.next()) |fifteen| {
        info.fifteen_min = std.fmt.parseFloat(f64, fifteen) catch 0;
    }
    if (parts.next()) |procs| {
        // Format: "running/total"
        var proc_parts = std.mem.splitScalar(u8, procs, '/');
        if (proc_parts.next()) |running| {
            info.running_procs = std.fmt.parseInt(u32, running, 10) catch 0;
        }
        if (proc_parts.next()) |total| {
            info.total_procs = std.fmt.parseInt(u32, total, 10) catch 0;
        }
    }

    return info;
}

// Parse /proc/uptime
fn parseUptime(allocator: std.mem.Allocator) !UptimeInfo {
    const contents = try readProcFile(allocator, "/proc/uptime");
    defer allocator.free(contents);

    var info = UptimeInfo{
        .uptime_secs = 0,
        .idle_secs = 0,
    };

    // Format: "uptime_secs idle_secs"
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, contents, " \n"), ' ');

    if (parts.next()) |uptime| {
        info.uptime_secs = std.fmt.parseFloat(f64, uptime) catch 0;
    }
    if (parts.next()) |idle| {
        info.idle_secs = std.fmt.parseFloat(f64, idle) catch 0;
    }

    return info;
}

extern "c" fn uname(buf: *std.c.utsname) c_int;

// Get system info via uname
fn getSystemInfo() SystemInfo {
    var sys: SystemInfo = undefined;
    @memset(&sys.sysname, 0);
    @memset(&sys.nodename, 0);
    @memset(&sys.release, 0);
    @memset(&sys.version, 0);
    @memset(&sys.machine, 0);

    var uts: std.c.utsname = undefined;
    const result = uname(&uts);
    if (result != 0) {
        const unknown = "Unknown";
        @memcpy(sys.sysname[0..unknown.len], unknown);
        sys.sysname_len = unknown.len;
        @memcpy(sys.nodename[0..unknown.len], unknown);
        sys.nodename_len = unknown.len;
        @memcpy(sys.release[0..unknown.len], unknown);
        sys.release_len = unknown.len;
        @memcpy(sys.version[0..unknown.len], unknown);
        sys.version_len = unknown.len;
        @memcpy(sys.machine[0..unknown.len], unknown);
        sys.machine_len = unknown.len;
        return sys;
    }

    // Copy with length tracking
    const sysname_slice = std.mem.sliceTo(&uts.sysname, 0);
    @memcpy(sys.sysname[0..sysname_slice.len], sysname_slice);
    sys.sysname_len = sysname_slice.len;

    const nodename_slice = std.mem.sliceTo(&uts.nodename, 0);
    @memcpy(sys.nodename[0..nodename_slice.len], nodename_slice);
    sys.nodename_len = nodename_slice.len;

    const release_slice = std.mem.sliceTo(&uts.release, 0);
    @memcpy(sys.release[0..release_slice.len], release_slice);
    sys.release_len = release_slice.len;

    const version_slice = std.mem.sliceTo(&uts.version, 0);
    @memcpy(sys.version[0..version_slice.len], version_slice);
    sys.version_len = version_slice.len;

    const machine_slice = std.mem.sliceTo(&uts.machine, 0);
    @memcpy(sys.machine[0..machine_slice.len], machine_slice);
    sys.machine_len = machine_slice.len;

    return sys;
}

// Format bytes as human-readable string
fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "Ki", "Mi", "Gi", "Ti" };
    var value: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (value >= 1024 and unit_idx < units.len - 1) {
        value /= 1024;
        unit_idx += 1;
    }

    const written = std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit_idx] }) catch return "???";
    return written;
}

// Format uptime as human-readable string
fn formatUptime(secs: f64, buf: []u8) []const u8 {
    const total_secs: u64 = @intFromFloat(secs);
    const days = total_secs / 86400;
    const hours = (total_secs % 86400) / 3600;
    const mins = (total_secs % 3600) / 60;

    if (days > 0) {
        const written = std.fmt.bufPrint(buf, "{d} days, {d}:{d:0>2}", .{ days, hours, mins }) catch return "???";
        return written;
    } else {
        const written = std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ hours, mins }) catch return "???";
        return written;
    }
}

const Command = enum {
    all,
    memory,
    cpu,
    uptime,
    load,
    uname,
    help,
};

// Writer wrapper for Zig 0.16 I/O API
const Writer = struct {
    io: std.Io,
    buffer: *[8192]u8,
    file: std.Io.File,

    pub fn init() Writer {
        const io = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io,
            .buffer = &static.buffer,
            .file = std.Io.File.stdout(),
        };
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }

    pub fn write(self: *Writer, data: []const u8) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.writeAll(data) catch {};
        writer.interface.flush() catch {};
    }
};

fn printHelp(w: *Writer) void {
    w.write(
        \\zsys - System Information Tool
        \\
        \\USAGE:
        \\    zsys [COMMAND]
        \\
        \\COMMANDS:
        \\    all      Show all system information (default)
        \\    memory   Show memory usage (like 'free')
        \\    cpu      Show CPU information (like 'lscpu')
        \\    uptime   Show system uptime (like 'uptime')
        \\    load     Show load averages
        \\    uname    Show system identification (like 'uname -a')
        \\    help     Show this help message
        \\
        \\EXAMPLES:
        \\    zsys             # Show all info
        \\    zsys memory      # Show memory only
        \\    zsys cpu         # Show CPU only
        \\
    );
}

fn printMemory(allocator: std.mem.Allocator, w: *Writer) !void {
    const mem = try parseMemoryInfo(allocator);

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var buf3: [32]u8 = undefined;
    var buf4: [32]u8 = undefined;
    var buf5: [32]u8 = undefined;
    var buf6: [32]u8 = undefined;

    w.write("=== Memory Information ===\n");
    w.write("               total        used        free      shared  buff/cache   available\n");
    w.print("Mem:    {s:>11} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11}\n", .{
        formatBytes(mem.total, &buf1),
        formatBytes(mem.total - mem.free - mem.buffers - mem.cached, &buf2),
        formatBytes(mem.free, &buf3),
        formatBytes(mem.shared, &buf4),
        formatBytes(mem.buffers + mem.cached, &buf5),
        formatBytes(mem.available, &buf6),
    });

    if (mem.swap_total > 0) {
        w.print("Swap:   {s:>11} {s:>11} {s:>11}\n", .{
            formatBytes(mem.swap_total, &buf1),
            formatBytes(mem.swap_total - mem.swap_free, &buf2),
            formatBytes(mem.swap_free, &buf3),
        });
    }
    w.write("\n");
}

fn printCpu(allocator: std.mem.Allocator, w: *Writer) !void {
    const cpu = try parseCpuInfo(allocator);

    w.write("=== CPU Information ===\n");
    w.print("Model:           {s}\n", .{cpu.getModelName()});
    w.print("Vendor:          {s}\n", .{cpu.getVendorId()});
    w.print("Frequency:       {d:.0} MHz\n", .{cpu.cpu_mhz});
    w.print("Cache:           {d} KB\n", .{cpu.cache_size});
    w.print("Physical CPUs:   {d}\n", .{cpu.physical_cores});
    w.print("Logical CPUs:    {d}\n", .{cpu.logical_cores});
    w.write("\n");
}

fn printUptime(allocator: std.mem.Allocator, w: *Writer) !void {
    const up = try parseUptime(allocator);
    const load = try parseLoadAvg(allocator);

    var buf: [64]u8 = undefined;
    const uptime_str = formatUptime(up.uptime_secs, &buf);

    w.write("=== System Uptime ===\n");
    w.print("Uptime:          {s}\n", .{uptime_str});
    w.print("Load average:    {d:.2}, {d:.2}, {d:.2}\n", .{
        load.one_min,
        load.five_min,
        load.fifteen_min,
    });
    w.print("Processes:       {d} running, {d} total\n", .{
        load.running_procs,
        load.total_procs,
    });
    w.write("\n");
}

fn printLoad(allocator: std.mem.Allocator, w: *Writer) !void {
    const load = try parseLoadAvg(allocator);

    w.write("=== Load Averages ===\n");
    w.print("1 min:           {d:.2}\n", .{load.one_min});
    w.print("5 min:           {d:.2}\n", .{load.five_min});
    w.print("15 min:          {d:.2}\n", .{load.fifteen_min});
    w.print("Running:         {d}\n", .{load.running_procs});
    w.print("Total:           {d}\n", .{load.total_procs});
    w.write("\n");
}

fn printUname(w: *Writer) void {
    const sys = getSystemInfo();

    w.write("=== System Identification ===\n");
    w.print("Kernel:          {s}\n", .{sys.getSysname()});
    w.print("Hostname:        {s}\n", .{sys.getNodename()});
    w.print("Release:         {s}\n", .{sys.getRelease()});
    w.print("Version:         {s}\n", .{sys.getVersion()});
    w.print("Architecture:    {s}\n", .{sys.getMachine()});
    w.write("\n");
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            std.debug.print("zsys: failed to allocate args\n", .{});
            std.process.exit(1);
        };
    }
    const args = args_list.items;

    var w = Writer.init();

    // Parse command
    var cmd = Command.all;
    if (args.len > 1) {
        const arg = args[1];
        if (std.mem.eql(u8, arg, "all")) {
            cmd = .all;
        } else if (std.mem.eql(u8, arg, "memory") or std.mem.eql(u8, arg, "mem") or std.mem.eql(u8, arg, "free")) {
            cmd = .memory;
        } else if (std.mem.eql(u8, arg, "cpu") or std.mem.eql(u8, arg, "lscpu")) {
            cmd = .cpu;
        } else if (std.mem.eql(u8, arg, "uptime") or std.mem.eql(u8, arg, "up")) {
            cmd = .uptime;
        } else if (std.mem.eql(u8, arg, "load") or std.mem.eql(u8, arg, "loadavg")) {
            cmd = .load;
        } else if (std.mem.eql(u8, arg, "uname") or std.mem.eql(u8, arg, "sys")) {
            cmd = .uname;
        } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cmd = .help;
        } else {
            w.print("Unknown command: {s}\n\n", .{arg});
            printHelp(&w);
            std.process.exit(1);
        }
    }

    switch (cmd) {
        .all => {
            printUname(&w);
            printCpu(allocator, &w) catch |err| {
                w.print("Error reading CPU info: {}\n", .{err});
            };
            printMemory(allocator, &w) catch |err| {
                w.print("Error reading memory info: {}\n", .{err});
            };
            printUptime(allocator, &w) catch |err| {
                w.print("Error reading uptime: {}\n", .{err});
            };
        },
        .memory => printMemory(allocator, &w) catch |err| {
            w.print("Error: {}\n", .{err});
            std.process.exit(1);
        },
        .cpu => printCpu(allocator, &w) catch |err| {
            w.print("Error: {}\n", .{err});
            std.process.exit(1);
        },
        .uptime => printUptime(allocator, &w) catch |err| {
            w.print("Error: {}\n", .{err});
            std.process.exit(1);
        },
        .load => printLoad(allocator, &w) catch |err| {
            w.print("Error: {}\n", .{err});
            std.process.exit(1);
        },
        .uname => printUname(&w),
        .help => printHelp(&w),
    }
}

test "parse memory info" {
    const allocator = std.testing.allocator;
    const mem = parseMemoryInfo(allocator) catch return;
    try std.testing.expect(mem.total > 0);
}

test "parse cpu info" {
    const allocator = std.testing.allocator;
    const cpu = parseCpuInfo(allocator) catch return;
    try std.testing.expect(cpu.logical_cores > 0);
}

test "parse load avg" {
    const allocator = std.testing.allocator;
    const load = parseLoadAvg(allocator) catch return;
    try std.testing.expect(load.total_procs > 0);
}

test "format bytes" {
    var buf: [32]u8 = undefined;

    const result1 = formatBytes(1024, &buf);
    try std.testing.expectEqualStrings("1.0 Ki", result1);

    const result2 = formatBytes(1048576, &buf);
    try std.testing.expectEqualStrings("1.0 Mi", result2);

    const result3 = formatBytes(1073741824, &buf);
    try std.testing.expectEqualStrings("1.0 Gi", result3);
}
