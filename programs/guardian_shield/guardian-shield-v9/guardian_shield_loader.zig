// guardian_shield_loader.zig
// Guardian Shield v9 userspace loader / policy manager.
//
// Responsibilities:
//   1. Verify kernel prerequisites (>=5.7, BPF in the active LSM stack, BTF).
//   2. Resolve and open the BPF object (relative to the executable, or --obj).
//   3. Load it, populate all policy maps, then flip the runtime `ready` flag so
//      no hook enforces against an empty policy.
//   4. Attach every program (LSM + tp_btf) and PIN each link under
//      /sys/fs/bpf/guardian_shield/ so enforcement PERSISTS if the loader dies
//      (LSM links otherwise detach on fd close -> fail-open). FAIL-CLOSED: if
//      any single hook fails to attach, all links are torn down and the loader
//      refuses to run with partial protection.
//   5. Consume the violation + exec ring buffers and append JSON-Lines events.
//   6. `--unpin` tears the whole thing down (removes pins -> links detach).
//
// Build: see build.zig (targets glibc 2.39, links -lbpf, _FORTIFY_SOURCE=0).

const std = @import("std");

const c = @cImport({
    @cInclude("bpf/libbpf.h");
    @cInclude("bpf/bpf.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("dirent.h");
    @cInclude("errno.h");
});

// ===================================================================
// Kernel-mirrored structures (must match guardian_shield.bpf.c byte-for-byte)
// ===================================================================

const MAX_PATH_LEN = 256;
const MAX_EXE_NAME = 64;
const MAX_EXE_PATH = 256;

const PathLpmKey = extern struct {
    prefixlen: u32, // in BITS
    data: [MAX_PATH_LEN]u8,
};

const PathRule = extern struct {
    prefix_len: u32, // in BYTES
    action: u8,
    _pad: [3]u8,
};

const GsConfig = extern struct {
    ready: u8,
    enforce_fs: u8,
    enforce_mem: u8,
    enforce_priv: u8,
    log_only: u8,
};

const ViolationEvent = extern struct {
    timestamp: u64,
    pid: u32,
    tid: u32,
    uid: u32,
    gid: u32,
    target_pid: u32,
    aux: u32,
    event_type: u8,
    tag: u8,
    enforced: u8,
    _pad: u8,
    comm: [16]u8,
    path: [MAX_PATH_LEN]u8,
    target_path: [MAX_PATH_LEN]u8,
};

const ExecEvent = extern struct {
    pid: u32,
    tag: u32,
    filename: [MAX_EXE_PATH]u8,
};

// ===================================================================
// Config
// ===================================================================

const RawConfig = struct {
    protected_paths: []const []const u8 = &.{},
    agent_exes: []const []const u8 = &.{},
    exempt_exes: []const []const u8 = &.{},
    enforce_fs: bool = true,
    enforce_mem: bool = true,
    enforce_priv: bool = false,
    log_only: bool = false,
    pin_dir: []const u8 = "/sys/fs/bpf/guardian_shield",
    log_file: []const u8 = "/var/log/guardian_shield.jsonl",
};

// ===================================================================
// Globals for the C-ABI ring buffer callbacks
// ===================================================================

var g_running: bool = true;
var g_log_fd: c_int = -1;
const g_alloc = std.heap.c_allocator;

const MAX_PATH_BYTES = 4096;

fn logWrite(bytes: []const u8) void {
    if (g_log_fd < 0) return;
    _ = c.write(g_log_fd, bytes.ptr, bytes.len);
}

fn onSignal(_: c_int) callconv(.c) void {
    g_running = false;
}

// ===================================================================
// main
// ===================================================================

const Args = struct {
    config_path: []const u8 = "config.json",
    obj_override: ?[]const u8 = null,
    unpin: bool = false,
    verbose: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var args = Args{};
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]
    var expect_obj = false;
    while (it.next()) |a| {
        if (expect_obj) {
            args.obj_override = try g_alloc.dupe(u8, a);
            expect_obj = false;
        } else if (std.mem.eql(u8, a, "--unpin")) {
            args.unpin = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            args.verbose = true;
        } else if (std.mem.eql(u8, a, "--obj")) {
            expect_obj = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return fail("unknown flag");
        } else {
            args.config_path = try g_alloc.dupe(u8, a);
        }
    }
    if (expect_obj) return fail("--obj requires a path argument");

    // Quiet libbpf's info/debug chatter unless --verbose (default keeps the
    // built-in warn/err handler which is useful for verifier diagnostics).
    if (!args.verbose)
        _ = c.libbpf_set_print(null);

    // Load config first (needed for pin_dir in both modes).
    const parsed = loadConfig(args.config_path) catch |e| {
        std.log.err("failed to load config '{s}': {t}", .{ args.config_path, e });
        return e;
    };
    defer parsed.deinit();
    const cfg = parsed.value;

    if (args.unpin) {
        try teardown(cfg.pin_dir);
        std.log.info("Guardian Shield v9: unpinned and detached.", .{});
        return;
    }

    try prereqChecks();

    const obj_path = try resolveObjPath(g_alloc, args.obj_override);
    defer g_alloc.free(obj_path);
    std.log.info("Guardian Shield v9 loader: object = {s}", .{obj_path});

    var loader = Loader.init(cfg);
    defer loader.deinit();

    try loader.open(obj_path);
    try loader.load();
    try loader.populateMaps();
    try loader.attachAndPin(); // fail-closed
    try loader.setReady(); // enforcement goes live here

    std.log.info("Guardian Shield v9 ACTIVE: {d} hooks pinned under {s} (enforce_fs={}, enforce_mem={}, enforce_priv={}, log_only={}).", .{
        loader.link_count, cfg.pin_dir, cfg.enforce_fs, cfg.enforce_mem, cfg.enforce_priv, cfg.log_only,
    });

    openLog(cfg.log_file);
    defer if (g_log_fd >= 0) {
        _ = c.close(g_log_fd);
    };

    installSignals();
    try loader.eventLoop();

    std.log.info("Guardian Shield v9 loader exiting. Enforcement REMAINS active via pinned links. Run with --unpin to remove.", .{});
}

fn fail(msg: []const u8) error{InvalidArgs} {
    std.log.err("{s}", .{msg});
    std.log.err("usage: guardian_shield_loader <config.json> [--obj <path>] [--verbose] [--unpin]", .{});
    return error.InvalidArgs;
}

// ===================================================================
// Prerequisites
// ===================================================================

fn prereqChecks() !void {
    // 1. Kernel >= 5.7
    var buf: [128]u8 = undefined;
    const rel = readSmall("/proc/sys/kernel/osrelease", &buf) catch {
        std.log.err("cannot read /proc/sys/kernel/osrelease", .{});
        return error.PrereqFailed;
    };
    const major, const minor = parseKernel(rel) orelse {
        std.log.err("cannot parse kernel version from '{s}'", .{rel});
        return error.PrereqFailed;
    };
    if (major < 5 or (major == 5 and minor < 7)) {
        std.log.err("kernel {d}.{d} < 5.7 - BPF-LSM unsupported. Upgrade the kernel.", .{ major, minor });
        return error.PrereqFailed;
    }

    // 2. bpf in the active LSM stack
    var lbuf: [512]u8 = undefined;
    const lsm = readSmall("/sys/kernel/security/lsm", &lbuf) catch {
        std.log.err("cannot read /sys/kernel/security/lsm (securityfs not mounted?)", .{});
        printLsmRemediation();
        return error.PrereqFailed;
    };
    if (!lsmHasBpf(lsm)) {
        std.log.err("'bpf' is NOT in the active LSM stack: {s}", .{lsm});
        printLsmRemediation();
        return error.PrereqFailed;
    }

    // 3. Kernel BTF present (CO-RE)
    if (c.access("/sys/kernel/btf/vmlinux", c.F_OK) != 0) {
        std.log.err("/sys/kernel/btf/vmlinux missing - kernel lacks CONFIG_DEBUG_INFO_BTF.", .{});
        return error.PrereqFailed;
    }

    std.log.info("prereqs OK: kernel {d}.{d}, bpf-LSM active, BTF present.", .{ major, minor });
}

fn printLsmRemediation() void {
    std.log.err("Remediation: add bpf to the LSM list on the kernel cmdline, e.g.", .{});
    std.log.err("  GRUB_CMDLINE_LINUX=\"... lsm=landlock,lockdown,yama,integrity,apparmor,bpf\"", .{});
    std.log.err("  then: sudo grub-mkconfig -o /boot/grub/grub.cfg  (or update-grub) && reboot", .{});
}

fn parseKernel(rel: []const u8) ?struct { u32, u32 } {
    var it = std.mem.splitScalar(u8, rel, '.');
    const maj_s = it.next() orelse return null;
    const min_s = it.next() orelse return null;
    const maj = std.fmt.parseInt(u32, std.mem.trim(u8, maj_s, " \n\r\t"), 10) catch return null;
    // minor may carry a suffix like "1-arch2"; take the leading digits.
    var end: usize = 0;
    while (end < min_s.len and std.ascii.isDigit(min_s[end])) : (end += 1) {}
    if (end == 0) return null;
    const min = std.fmt.parseInt(u32, min_s[0..end], 10) catch return null;
    return .{ maj, min };
}

fn lsmHasBpf(lsm: []const u8) bool {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, lsm, " \n\r\t"), ',');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "bpf")) return true;
    }
    return false;
}

// Read a whole small (proc/sys) file into `buf` via libc; return trimmed slice.
fn readSmall(path: []const u8, buf: []u8) ![]const u8 {
    var zbuf: [MAX_PATH_BYTES]u8 = undefined;
    const zpath = try std.fmt.bufPrintZ(&zbuf, "{s}", .{path});
    const fd = c.open(zpath.ptr, c.O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, buf.ptr + total, buf.len - total);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        total += @intCast(n);
    }
    return std.mem.trim(u8, buf[0..total], " \n\r\t");
}

// ===================================================================
// Object path resolution
// ===================================================================

fn resolveObjPath(alloc: std.mem.Allocator, override: ?[]const u8) ![]u8 {
    if (override) |o| return alloc.dupe(u8, o);

    // Resolve <exe_dir> via /proc/self/exe, then probe candidates next to it.
    var exe_buf: [MAX_PATH_BYTES]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    const dir = if (n > 0)
        (std.fs.path.dirname(exe_buf[0..@intCast(n)]) orelse ".")
    else
        ".";

    const candidates = [_][]const u8{
        "guardian_shield.bpf.o",
        "build/guardian_shield.bpf.o",
        "bpf/guardian_shield.bpf.o",
    };
    for (candidates) |cand| {
        const p = try std.fs.path.join(alloc, &.{ dir, cand });
        var zbuf: [MAX_PATH_BYTES]u8 = undefined;
        const zp = std.fmt.bufPrintZ(&zbuf, "{s}", .{p}) catch {
            alloc.free(p);
            continue;
        };
        if (c.access(zp.ptr, c.F_OK) == 0) return p;
        alloc.free(p);
    }
    return alloc.dupe(u8, "build/guardian_shield.bpf.o");
}

// ===================================================================
// Loader
// ===================================================================

const Loader = struct {
    cfg: RawConfig,
    obj: ?*c.bpf_object = null,
    links: std.ArrayListUnmanaged(*c.bpf_link) = .empty,
    v_rb: ?*c.ring_buffer = null,
    link_count: usize = 0,

    fn init(cfg: RawConfig) Loader {
        return .{ .cfg = cfg };
    }

    fn deinit(self: *Loader) void {
        if (self.v_rb) |rb| c.ring_buffer__free(rb);
        // Note: we intentionally do NOT destroy links on normal exit - they are
        // pinned and must persist. Links are only destroyed on the fail-closed
        // error path (see attachAndPin) before deinit runs.
        self.links.deinit(g_alloc);
        if (self.obj) |o| c.bpf_object__close(o);
    }

    fn open(self: *Loader, path: []const u8) !void {
        var pbuf: [MAX_PATH_BYTES]u8 = undefined;
        const z = try std.fmt.bufPrintZ(&pbuf, "{s}", .{path});
        const o = c.bpf_object__open_file(z.ptr, null);
        if (o == null) {
            std.log.err("bpf_object__open_file failed for {s}", .{path});
            return error.OpenFailed;
        }
        self.obj = o;
    }

    fn load(self: *Loader) !void {
        const o = self.obj orelse return error.NoObject;
        const rc = c.bpf_object__load(o);
        if (rc != 0) {
            std.log.err("bpf_object__load failed rc={d} (need root/CAP_BPF+CAP_SYS_ADMIN; check verifier log with --verbose)", .{rc});
            return error.LoadFailed;
        }
    }

    fn mapFd(self: *Loader, name: [:0]const u8) !c_int {
        const o = self.obj orelse return error.NoObject;
        const fd = c.bpf_object__find_map_fd_by_name(o, name.ptr);
        if (fd < 0) {
            std.log.err("map not found: {s}", .{name});
            return error.MapNotFound;
        }
        return fd;
    }

    fn populateMaps(self: *Loader) !void {
        // --- protected_paths (LPM trie) ---
        const pp_fd = try self.mapFd("protected_paths");
        var n_paths: usize = 0;
        for (self.cfg.protected_paths) |raw| {
            // Normalize: strip a single trailing '/' (except root). The kernel
            // boundary check requires prefixes stored WITHOUT trailing slash.
            var p = raw;
            if (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
            if (p.len == 0 or p.len >= MAX_PATH_LEN) {
                std.log.warn("skipping invalid protected_path '{s}'", .{raw});
                continue;
            }
            var key = std.mem.zeroes(PathLpmKey);
            key.prefixlen = @intCast(p.len * 8);
            @memcpy(key.data[0..p.len], p);
            var val = PathRule{ .prefix_len = @intCast(p.len), .action = 1, ._pad = .{ 0, 0, 0 } };
            const rc = c.bpf_map_update_elem(pp_fd, &key, &val, c.BPF_ANY);
            if (rc != 0) {
                std.log.err("failed to insert protected_path '{s}' rc={d}", .{ p, rc });
                return error.MapUpdateFailed;
            }
            n_paths += 1;
        }

        // --- agent_exe_names (basename -> 1) ---
        const ae_fd = try self.mapFd("agent_exe_names");
        for (self.cfg.agent_exes) |name| {
            if (name.len >= MAX_EXE_NAME) {
                std.log.warn("agent_exe '{s}' too long, skipping", .{name});
                continue;
            }
            var key = std.mem.zeroes([MAX_EXE_NAME]u8);
            @memcpy(key[0..name.len], name);
            var one: u8 = 1;
            _ = c.bpf_map_update_elem(ae_fd, &key, &one, c.BPF_ANY);
        }

        // --- exempt_exes (full path -> 1) ---
        const ex_fd = try self.mapFd("exempt_exes");
        for (self.cfg.exempt_exes) |name| {
            if (name.len >= MAX_EXE_PATH) {
                std.log.warn("exempt_exe '{s}' too long, skipping", .{name});
                continue;
            }
            var key = std.mem.zeroes([MAX_EXE_PATH]u8);
            @memcpy(key[0..name.len], name);
            var one: u8 = 1;
            _ = c.bpf_map_update_elem(ex_fd, &key, &one, c.BPF_ANY);
        }

        // --- runtime_cfg (flags set, ready=0 until attach completes) ---
        const cfg_fd = try self.mapFd("runtime_cfg");
        var k0: u32 = 0;
        var gc = GsConfig{
            .ready = 0,
            .enforce_fs = @intFromBool(self.cfg.enforce_fs),
            .enforce_mem = @intFromBool(self.cfg.enforce_mem),
            .enforce_priv = @intFromBool(self.cfg.enforce_priv),
            .log_only = @intFromBool(self.cfg.log_only),
        };
        if (c.bpf_map_update_elem(cfg_fd, &k0, &gc, c.BPF_ANY) != 0)
            return error.MapUpdateFailed;

        std.log.info("policy loaded: {d} protected paths, {d} agent exes, {d} exempt exes.", .{
            n_paths, self.cfg.agent_exes.len, self.cfg.exempt_exes.len,
        });
    }

    fn attachAndPin(self: *Loader) !void {
        const o = self.obj orelse return error.NoObject;

        // Ensure the pin directory exists on bpffs.
        makePinDir(self.cfg.pin_dir) catch |e| {
            std.log.err("cannot create pin dir '{s}': {t} (is /sys/fs/bpf a bpffs mount?)", .{ self.cfg.pin_dir, e });
            return error.PinDirFailed;
        };

        var prog: ?*c.bpf_program = c.bpf_object__next_program(o, null);
        while (prog) |p| : (prog = c.bpf_object__next_program(o, p)) {
            const name = c.bpf_program__name(p);
            const link = c.bpf_program__attach(p);
            if (link == null) {
                std.log.err("ATTACH FAILED for program '{s}' - tearing down (fail-closed).", .{name});
                self.teardownLinks();
                return error.AttachFailed;
            }
            self.links.append(g_alloc, link.?) catch {
                _ = c.bpf_link__destroy(link.?);
                self.teardownLinks();
                return error.OutOfMemory;
            };

            // Pin the link so it survives loader exit.
            var pbuf: [MAX_PATH_BYTES]u8 = undefined;
            const pin_path = std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ self.cfg.pin_dir, std.mem.span(name) }) catch {
                self.teardownLinks();
                return error.PinPathTooLong;
            };
            // Remove a stale pin from a previous run, then pin fresh.
            std.posix.unlink(pin_path) catch {};
            const prc = c.bpf_link__pin(link.?, pin_path.ptr);
            if (prc != 0) {
                std.log.err("bpf_link__pin failed for '{s}' rc={d} - tearing down.", .{ name, prc });
                self.teardownLinks();
                return error.PinFailed;
            }
            self.link_count += 1;
        }

        if (self.link_count == 0) {
            std.log.err("no programs attached - refusing to run.", .{});
            return error.NoPrograms;
        }
    }

    // Destroy + unpin all links (fail-closed path only).
    fn teardownLinks(self: *Loader) void {
        for (self.links.items) |l| {
            _ = c.bpf_link__unpin(l); // no-op if not pinned
            _ = c.bpf_link__destroy(l);
        }
        self.links.clearRetainingCapacity();
        self.link_count = 0;
    }

    fn setReady(self: *Loader) !void {
        const cfg_fd = try self.mapFd("runtime_cfg");
        var k0: u32 = 0;
        var gc = GsConfig{
            .ready = 1,
            .enforce_fs = @intFromBool(self.cfg.enforce_fs),
            .enforce_mem = @intFromBool(self.cfg.enforce_mem),
            .enforce_priv = @intFromBool(self.cfg.enforce_priv),
            .log_only = @intFromBool(self.cfg.log_only),
        };
        if (c.bpf_map_update_elem(cfg_fd, &k0, &gc, c.BPF_ANY) != 0)
            return error.MapUpdateFailed;
    }

    fn eventLoop(self: *Loader) !void {
        const v_fd = try self.mapFd("violation_events");
        const rb = c.ring_buffer__new(v_fd, handleViolation, null, null);
        if (rb == null) return error.RingBufferInit;
        self.v_rb = rb;

        const e_fd = try self.mapFd("exec_events");
        _ = c.ring_buffer__add(rb, e_fd, handleExec, null);

        while (g_running) {
            const rc = c.ring_buffer__poll(rb, 250);
            if (rc < 0 and rc != -4) { // -EINTR is fine
                std.log.err("ring_buffer__poll error rc={d}", .{rc});
                return error.PollFailed;
            }
        }
    }
};

// ===================================================================
// Pin helpers / teardown
// ===================================================================

fn makePinDir(dir: []const u8) !void {
    std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

fn teardown(pin_dir: []const u8) !void {
    var dir = std.fs.openDirAbsolute(pin_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.info("pin dir '{s}' does not exist; nothing to unpin.", .{pin_dir});
            return;
        },
        else => return e,
    };
    defer dir.close();

    var it = dir.iterate();
    var removed: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .file) {
            dir.deleteFile(entry.name) catch |e| {
                std.log.warn("could not remove pin '{s}': {t}", .{ entry.name, e });
                continue;
            };
            removed += 1;
        }
    }
    std.log.info("removed {d} pinned links from {s}.", .{ removed, pin_dir });
    std.fs.deleteDirAbsolute(pin_dir) catch {};
}

// ===================================================================
// Ring buffer callbacks (C ABI)
// ===================================================================

fn eventName(t: u8) []const u8 {
    return switch (t) {
        1 => "unlink",
        2 => "rename",
        3 => "chmod",
        4 => "truncate",
        5 => "link",
        6 => "symlink",
        7 => "mkdir",
        8 => "rmdir",
        9 => "open_write",
        20 => "ptrace",
        21 => "dev_mem",
        22 => "module_load",
        23 => "capability",
        24 => "mount",
        else => "unknown",
    };
}

fn cstr(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

fn handleViolation(_: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
    if (data == null or size < @sizeOf(ViolationEvent)) return 0;
    const ev: *const ViolationEvent = @ptrCast(@alignCast(data.?));

    // Emit JSON via std.json.Stringify (never format-string interpolation).
    const record = .{
        .ts_ns = ev.timestamp,
        .event = eventName(ev.event_type),
        .enforced = ev.enforced != 0,
        .pid = ev.pid,
        .tid = ev.tid,
        .uid = ev.uid,
        .gid = ev.gid,
        .tag = ev.tag,
        .comm = cstr(&ev.comm),
        .path = cstr(&ev.path),
        .target_path = cstr(&ev.target_path),
        .target_pid = ev.target_pid,
        .aux = ev.aux,
    };
    const json = std.json.Stringify.valueAlloc(g_alloc, record, .{}) catch return 0;
    defer g_alloc.free(json);

    if (g_log_file) |f| {
        f.writeAll(json) catch {};
        f.writeAll("\n") catch {};
    }
    std.debug.print("[guardian] {s} {s} pid={d} tag={d} path={s}\n", .{
        if (ev.enforced != 0) "BLOCKED" else "AUDIT",
        eventName(ev.event_type),
        ev.pid,
        ev.tag,
        cstr(&ev.path),
    });
    return 0;
}

fn handleExec(_: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
    if (data == null or size < @sizeOf(ExecEvent)) return 0;
    const ev: *const ExecEvent = @ptrCast(@alignCast(data.?));

    const record = .{
        .event = "agent_tagged",
        .pid = ev.pid,
        .tag = ev.tag,
        .exe = cstr(&ev.filename),
    };
    const json = std.json.Stringify.valueAlloc(g_alloc, record, .{}) catch return 0;
    defer g_alloc.free(json);
    if (g_log_file) |f| {
        f.writeAll(json) catch {};
        f.writeAll("\n") catch {};
    }
    return 0;
}

// ===================================================================
// Misc
// ===================================================================

fn openLog(path: []const u8) !void {
    const f = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch |e| {
        std.log.warn("cannot open log '{s}': {t} (continuing without file log)", .{ path, e });
        return;
    };
    f.seekFromEnd(0) catch {};
    g_log_file = f;
}

fn installSignals() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

fn loadConfig(path: []const u8) !std.json.Parsed(RawConfig) {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const content = try f.readToEndAlloc(g_alloc, 1 << 20);
    defer g_alloc.free(content);
    return std.json.parseFromSlice(RawConfig, g_alloc, content, .{ .ignore_unknown_fields = true });
}
