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
    @cInclude("sys/sysmacros.h");
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("arpa/inet.h");
});

// ===================================================================
// Kernel-mirrored structures (must match guardian_shield.bpf.c byte-for-byte)
// ===================================================================

// Must match guardian_shield.bpf.c. MAX_PATH_LEN was reduced to 128 so recon_ctx
// fits the BPF stack (bpf_loop requires a stack context).
const MAX_PATH_LEN = 128;
const MAX_EXE_NAME = 64;
const MAX_EXE_PATH = 256;

const PathLpmKey = extern struct {
    prefixlen: u32, // in BITS
    data: [MAX_PATH_LEN]u8,
};

const PathRule = extern struct {
    prefix_len: u32, // in BYTES
    action: u8,
    _pad: u8,
    // Bitmask of guarded operations, bit (EV_x - 1). Occupies the old padding,
    // so the map value layout and size are unchanged.
    ops: u16,
};

// Operation bits, mirroring enum event_type in the BPF object (bit = EV - 1).
const OP_UNLINK: u16 = 1 << 0;
const OP_RENAME: u16 = 1 << 1;
const OP_CHMOD: u16 = 1 << 2;
const OP_TRUNCATE: u16 = 1 << 3;
const OP_LINK: u16 = 1 << 4;
const OP_SYMLINK: u16 = 1 << 5;
const OP_MKDIR: u16 = 1 << 6;
const OP_RMDIR: u16 = 1 << 7;
const OP_OPEN_WRITE: u16 = 1 << 8;
const OP_CREATE: u16 = 1 << 9;
const OPS_ALL: u16 = 0xFFFF;
// The set that stops a runaway `rm -rf` while leaving a working tree writable.
const OPS_DESTROY: u16 = OP_UNLINK | OP_RMDIR | OP_RENAME | OP_TRUNCATE;

fn opFromName(name: []const u8) ?u16 {
    const eq = std.mem.eql;
    if (eq(u8, name, "*") or eq(u8, name, "all")) return OPS_ALL;
    if (eq(u8, name, "destroy")) return OPS_DESTROY;
    if (eq(u8, name, "unlink") or eq(u8, name, "delete")) return OP_UNLINK;
    if (eq(u8, name, "rename") or eq(u8, name, "move")) return OP_RENAME;
    if (eq(u8, name, "chmod")) return OP_CHMOD;
    if (eq(u8, name, "truncate")) return OP_TRUNCATE;
    if (eq(u8, name, "link")) return OP_LINK;
    if (eq(u8, name, "symlink")) return OP_SYMLINK;
    if (eq(u8, name, "mkdir")) return OP_MKDIR;
    if (eq(u8, name, "rmdir")) return OP_RMDIR;
    if (eq(u8, name, "open_write") or eq(u8, name, "write")) return OP_OPEN_WRITE;
    if (eq(u8, name, "create")) return OP_CREATE;
    return null;
}

/// Plain string list -> all-ops specs (critical_paths, credential_paths).
fn specsFromStrings(list: []const []const u8) ![]const PathSpec {
    const out = try g_alloc.alloc(PathSpec, list.len);
    for (list, 0..) |p, i| out[i] = .{ .path = p, .ops = OPS_ALL };
    return out;
}

/// protected_paths entries: a bare string guards everything (back-compatible
/// with every config written before op masks existed); an object selects ops.
/// An unknown op name is a hard error - silently guarding less than the operator
/// asked for is the one failure mode this must never have.
fn specsFromValues(list: []const std.json.Value) ![]const PathSpec {
    const out = try g_alloc.alloc(PathSpec, list.len);
    for (list, 0..) |v, i| {
        switch (v) {
            .string => |s| out[i] = .{ .path = s, .ops = OPS_ALL },
            .object => |obj| {
                const pv = obj.get("path") orelse {
                    std.log.err("protected_paths[{d}]: object entry has no \"path\"", .{i});
                    return error.InvalidConfig;
                };
                const p = switch (pv) {
                    .string => |s| s,
                    else => {
                        std.log.err("protected_paths[{d}]: \"path\" must be a string", .{i});
                        return error.InvalidConfig;
                    },
                };
                var mask: u16 = OPS_ALL;
                if (obj.get("block")) |bv| {
                    switch (bv) {
                        .array => |arr| {
                            mask = 0; // empty list => FREE hole, intentionally
                            for (arr.items) |ov| {
                                const name = switch (ov) {
                                    .string => |s| s,
                                    else => {
                                        std.log.err("protected_paths[{d}]: \"block\" entries must be strings", .{i});
                                        return error.InvalidConfig;
                                    },
                                };
                                mask |= opFromName(name) orelse {
                                    std.log.err("protected_paths[{d}]: unknown operation '{s}'", .{ i, name });
                                    return error.InvalidConfig;
                                };
                            }
                        },
                        else => {
                            std.log.err("protected_paths[{d}]: \"block\" must be an array", .{i});
                            return error.InvalidConfig;
                        },
                    }
                }
                out[i] = .{ .path = p, .ops = mask };
            },
            else => {
                std.log.err("protected_paths[{d}]: must be a string or an object", .{i});
                return error.InvalidConfig;
            },
        }
    }
    return out;
}

/// One protected-path entry after normalisation. JSON accepts either form:
///   "/some/path"                                -> guards ALL operations
///   {"path": "/p", "block": ["unlink","rmdir"]} -> guards only those
/// An EMPTY block list is meaningful rather than a no-op: because the trie is
/// longest-prefix, it punches a FREE hole under a broader guarded prefix.
const PathSpec = struct {
    path: []const u8,
    ops: u16,
};

const GsConfig = extern struct {
    ready: u8,
    enforce_fs: u8,
    enforce_mem: u8,
    enforce_priv: u8,
    log_only: u8,
    hardening_mode: u8,
    enforce_cred_read: u8,
    enforce_egress: u8,
};

// Mirrors struct egress_lpm_key (egress_allow trie key). addr in network order.
const EgressKey = extern struct {
    prefixlen: u32, // bits
    addr: [4]u8,
};

// Mirrors struct proc_tag in guardian_shield.bpf.c (agent_pids value).
const ProcTag = extern struct {
    tag: u8,
    root_tgid: u32,
    since_ns: u64,
};

// Mirrors struct exe_id (trusted_inodes key). Kernel s_dev is MKDEV(maj,min) =
// (maj << 20) | min (MINORBITS=20).
const ExeId = extern struct {
    ino: u64,
    dev: u32,
    _pad: u32 = 0,
};

const TAG_TRUSTED: u8 = 3;
const MINORBITS: u5 = 20;

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
    // Elements are either a JSON string (guard all ops) or an object
    // {"path": ..., "block": [...]}. Kept as Value so both forms parse; see
    // specsFromValues().
    protected_paths: []const std.json.Value = &.{},
    critical_paths: []const []const u8 = &.{},
    credential_paths: []const []const u8 = &.{},
    agent_exes: []const []const u8 = &.{},
    exempt_exes: []const []const u8 = &.{},
    trusted_exes: []const []const u8 = &.{},
    build_exes: []const []const u8 = &.{},
    egress_allow: []const []const u8 = &.{},
    enforce_fs: bool = true,
    enforce_mem: bool = true,
    enforce_priv: bool = false,
    log_only: bool = false,
    hardening_mode: bool = false,
    enforce_cred_read: bool = true,
    enforce_egress: bool = true,
    pin_dir: []const u8 = "/sys/fs/bpf/guardian_shield",
    log_file: []const u8 = "/var/log/guardian_shield.jsonl",
};

// ===================================================================
// Globals for the C-ABI ring buffer callbacks
// ===================================================================

var g_log_fd: c_int = -1;
const g_alloc = std.heap.c_allocator;

const MAX_PATH_BYTES = 4096;

fn logWrite(bytes: []const u8) void {
    if (g_log_fd < 0) return;
    _ = c.write(g_log_fd, bytes.ptr, bytes.len);
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
    try loader.tagSelfTrusted(); // loader tree = TAG_TRUSTED before enforcement
    try loader.attachAndPin(); // fail-closed
    try loader.setReady(); // enforcement goes live here

    std.log.info("Guardian Shield v9 ACTIVE: {d} hooks pinned under {s} (mode={s}, enforce_fs={}, enforce_mem={}, enforce_priv={}, log_only={}).", .{
        loader.link_count, cfg.pin_dir,
        if (cfg.hardening_mode) "HARDENING (default-deny, self-protecting)" else "agent-containment",
        cfg.enforce_fs, cfg.enforce_mem, cfg.enforce_priv, cfg.log_only,
    });

    openLog(cfg.log_file);
    defer if (g_log_fd >= 0) {
        _ = c.close(g_log_fd);
    };

    // Note: no SIGINT handler is installed. On termination the pinned LSM links
    // PERSIST (that is the whole point); use `--unpin` to remove enforcement.
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
        // --- protected_paths (LPM trie). In hardening mode the trie protects
        // the CRITICAL set against everyone-but-trusted; otherwise the agent-mode
        // protected_paths against agents. ---
        // critical_paths is a plain string list (hardening is deliberately
        // all-or-nothing); protected_paths carries per-entry operation masks.
        const path_src: []const PathSpec = if (self.cfg.hardening_mode)
            try specsFromStrings(self.cfg.critical_paths)
        else
            try specsFromValues(self.cfg.protected_paths);
        const n_paths = try self.populateLpm("protected_paths", path_src);

        // --- credential_paths (LPM trie). The crown-jewel AssetMap; read-denied
        // for TAINTED/AGENT subtrees regardless of posture. Read-gating is not an
        // op in the mask, so these are always all-ops. ---
        const n_creds = try self.populateLpm("credential_paths", try specsFromStrings(self.cfg.credential_paths));

        // --- basename classifiers ---
        try self.populateBasenameMap("agent_exe_names", self.cfg.agent_exes);
        try self.populateBasenameMap("build_exe_names", self.cfg.build_exes);

        // --- full-path allowlists ---
        try self.populateExeMap("exempt_exes", self.cfg.exempt_exes);
        try self.populateExeMap("trusted_exes", self.cfg.trusted_exes); // MUST include the loader
        // --- trusted_inodes ({ino,dev}). Trust the loader by exe identity so a
        // relative-path --unpin still matches (path-string match would fail). ---
        try self.populateTrustedInodes();

        // --- egress_allow (IPv4 CIDR trie): built-in private ranges + operator ---
        const n_egress = try self.populateEgress();

        // --- runtime_cfg (flags set, ready=0 until attach completes) ---
        const cfg_fd = try self.mapFd("runtime_cfg");
        var k0: u32 = 0;
        var gc = self.buildConfig(0);
        if (c.bpf_map_update_elem(cfg_fd, &k0, &gc, c.BPF_ANY) != 0)
            return error.MapUpdateFailed;

        std.log.info("policy loaded: {d} {s} paths, {d} credential paths, {d} agent exes, {d} build exes, {d} trusted, {d} egress CIDRs (hardening={}, cred_read={}, egress={}).", .{
            n_paths,
            if (self.cfg.hardening_mode) "critical" else "protected",
            n_creds,
            self.cfg.agent_exes.len,
            self.cfg.build_exes.len,
            self.cfg.trusted_exes.len,
            n_egress,
            self.cfg.hardening_mode,
            self.cfg.enforce_cred_read,
            self.cfg.enforce_egress,
        });
    }

    // Built-in egress allowlist: loopback, RFC1918 private, link-local, CGNAT.
    // Always inserted so LAN/localhost/registry-mirror-on-LAN work even if the
    // operator's egress_allow omits them; operator CIDRs are added on top.
    const EGRESS_DEFAULTS = [_][]const u8{
        "127.0.0.0/8",   "10.0.0.0/8",     "172.16.0.0/12",
        "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10",
    };

    fn populateEgress(self: *Loader) !usize {
        const fd = try self.mapFd("egress_allow");
        var n: usize = 0;
        for (EGRESS_DEFAULTS) |cidr| {
            if (insertCidr(fd, cidr)) n += 1;
        }
        for (self.cfg.egress_allow) |cidr| {
            if (insertCidr(fd, cidr)) n += 1;
        }
        return n;
    }

    // Insert a list of path prefixes into an LPM trie map (trailing '/' stripped;
    // stored WITHOUT it, as the kernel boundary check requires). Returns count.
    fn populateLpm(self: *Loader, map_name: [:0]const u8, list: []const PathSpec) !usize {
        const fd = try self.mapFd(map_name);
        var n: usize = 0;
        for (list) |spec| {
            var p = spec.path;
            if (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
            if (p.len == 0 or p.len >= MAX_PATH_LEN) {
                std.log.warn("skipping invalid {s} entry '{s}'", .{ map_name, spec.path });
                continue;
            }
            var key = std.mem.zeroes(PathLpmKey);
            key.prefixlen = @intCast(p.len * 8);
            @memcpy(key.data[0..p.len], p);
            var val = PathRule{ .prefix_len = @intCast(p.len), .action = 1, ._pad = 0, .ops = spec.ops };
            if (c.bpf_map_update_elem(fd, &key, &val, c.BPF_ANY) != 0) {
                std.log.err("failed to insert {s} '{s}'", .{ map_name, p });
                return error.MapUpdateFailed;
            }
            n += 1;
        }
        return n;
    }

    fn populateBasenameMap(self: *Loader, map_name: [:0]const u8, list: []const []const u8) !void {
        const fd = try self.mapFd(map_name);
        for (list) |name| {
            if (name.len >= MAX_EXE_NAME) {
                std.log.warn("{s} entry '{s}' too long, skipping", .{ map_name, name });
                continue;
            }
            var key = std.mem.zeroes([MAX_EXE_NAME]u8);
            @memcpy(key[0..name.len], name);
            var one: u8 = 1;
            _ = c.bpf_map_update_elem(fd, &key, &one, c.BPF_ANY);
        }
    }

    fn populateExeMap(self: *Loader, map_name: [:0]const u8, list: []const []const u8) !void {
        const fd = try self.mapFd(map_name);
        for (list) |name| {
            if (name.len >= MAX_EXE_PATH) {
                std.log.warn("{s} entry '{s}' too long, skipping", .{ map_name, name });
                continue;
            }
            var key = std.mem.zeroes([MAX_EXE_PATH]u8);
            @memcpy(key[0..name.len], name);
            var one: u8 = 1;
            _ = c.bpf_map_update_elem(fd, &key, &one, c.BPF_ANY);
        }
    }

    fn populateTrustedInodes(self: *Loader) !void {
        const fd = try self.mapFd("trusted_inodes");
        // Every configured trusted exe...
        var buf: [MAX_PATH_BYTES]u8 = undefined;
        for (self.cfg.trusted_exes) |p| {
            const zp = std.fmt.bufPrintZ(&buf, "{s}", .{p}) catch continue;
            insertInode(fd, zp);
        }
        // ...AND the loader's own binary (canonical), so it trusts itself no
        // matter what the config says or how it was invoked.
        insertInode(fd, "/proc/self/exe");
    }

    fn buildConfig(self: *Loader, ready: u8) GsConfig {
        return GsConfig{
            .ready = ready,
            .enforce_fs = @intFromBool(self.cfg.enforce_fs),
            .enforce_mem = @intFromBool(self.cfg.enforce_mem),
            .enforce_priv = @intFromBool(self.cfg.enforce_priv),
            .log_only = @intFromBool(self.cfg.log_only),
            .hardening_mode = @intFromBool(self.cfg.hardening_mode),
            .enforce_cred_read = @intFromBool(self.cfg.enforce_cred_read),
            .enforce_egress = @intFromBool(self.cfg.enforce_egress),
        };
    }

    // Tag the loader's OWN process tree TAG_TRUSTED directly, so the running
    // loader can call bpf() (and touch critical paths like the pin dir) even in
    // hardening mode. The loader exec'd before gs_exec was attached, so it is
    // not otherwise in agent_pids. Belt-and-suspenders with trusted_exes.
    fn tagSelfTrusted(self: *Loader) !void {
        const fd = try self.mapFd("agent_pids");
        var tgid: u32 = @intCast(c.getpid());
        var t = ProcTag{ .tag = TAG_TRUSTED, .root_tgid = tgid, .since_ns = 0 };
        if (c.bpf_map_update_elem(fd, &tgid, &t, c.BPF_ANY) != 0)
            std.log.warn("could not self-tag loader tgid {d} as trusted", .{tgid});
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
            _ = c.unlink(pin_path.ptr);
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

        // All links pinned. Drop the loader's own link fds so the PINS are the
        // sole owners. LSM links cannot be force-detached (no LINK_DETACH), so
        // the only way to remove one is to release every reference; making the
        // pins the sole reference means `--unpin` (which removes the pins) fully
        // detaches all hooks even while a logger instance is still running.
        // The bpf_object stays open (its maps back the ring buffers).
        const dropped = self.links.items.len;
        for (self.links.items) |l| _ = c.bpf_link__destroy(l);
        self.links.clearRetainingCapacity();
        std.log.info("released {d} loader-held link fds; pins are the sole owners (--unpin fully detaches).", .{dropped});
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
        var gc = self.buildConfig(1);
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

        while (true) {
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

// Stat `path` and insert its {ino, dev} identity into the trusted_inodes map
// (dev re-encoded to the kernel's MKDEV form so it matches inode->i_sb->s_dev).
fn insertInode(fd: c_int, path: [:0]const u8) void {
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) {
        std.log.warn("cannot stat trusted exe '{s}' for inode-trust", .{path});
        return;
    }
    const maj: u32 = @intCast(c.gnu_dev_major(st.st_dev));
    const min: u32 = @intCast(c.gnu_dev_minor(st.st_dev));
    var id = ExeId{
        .ino = @intCast(st.st_ino),
        .dev = (maj << MINORBITS) | (min & ((@as(u32, 1) << MINORBITS) - 1)),
    };
    var one: u8 = 1;
    _ = c.bpf_map_update_elem(fd, &id, &one, c.BPF_ANY);
}

// Parse "a.b.c.d/prefix" and insert into the egress_allow LPM trie. addr bytes
// are network order (inet_pton output = MSB first), matching the BPF key + the
// dest's sin_addr.s_addr. Returns true on success.
fn insertCidr(fd: c_int, cidr: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse {
        std.log.warn("egress_allow '{s}' missing /prefix, skipping", .{cidr});
        return false;
    };
    const ip_str = cidr[0..slash];
    const prefix = std.fmt.parseInt(u32, cidr[slash + 1 ..], 10) catch {
        std.log.warn("egress_allow '{s}' bad prefix, skipping", .{cidr});
        return false;
    };
    if (prefix > 32) {
        std.log.warn("egress_allow '{s}' prefix > 32 (IPv6 not supported in the trie), skipping", .{cidr});
        return false;
    }
    var zip: [64]u8 = undefined;
    const zip_s = std.fmt.bufPrintZ(&zip, "{s}", .{ip_str}) catch return false;
    var key = std.mem.zeroes(EgressKey);
    key.prefixlen = prefix;
    if (c.inet_pton(c.AF_INET, zip_s.ptr, &key.addr) != 1) {
        std.log.warn("egress_allow '{s}' not a valid IPv4, skipping", .{cidr});
        return false;
    }
    return c.bpf_map_update_elem(fd, &key, &@as(u8, 1), c.BPF_ANY) == 0;
}

fn makePinDir(dir: []const u8) !void {
    var zbuf: [MAX_PATH_BYTES]u8 = undefined;
    const zdir = try std.fmt.bufPrintZ(&zbuf, "{s}", .{dir});
    if (c.mkdir(zdir.ptr, 0o755) != 0) {
        const e = std.c._errno().*;
        if (e != c.EEXIST) return error.MkdirFailed;
    }
}

fn teardown(pin_dir: []const u8) !void {
    var zbuf: [MAX_PATH_BYTES]u8 = undefined;
    const zdir = try std.fmt.bufPrintZ(&zbuf, "{s}", .{pin_dir});

    // Collect pin names first (do not mutate the dir mid-iteration).
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| g_alloc.free(n);
        names.deinit(g_alloc);
    }
    const dp = c.opendir(zdir.ptr);
    if (dp == null) {
        std.log.info("pin dir '{s}' not present; nothing to unpin.", .{pin_dir});
        return;
    }
    while (true) {
        const ent = c.readdir(dp);
        if (ent == null) break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const dup = g_alloc.dupe(u8, name) catch continue;
        names.append(g_alloc, dup) catch {
            g_alloc.free(dup);
        };
    }
    _ = c.closedir(dp);

    // LSM/tracing links have NO LINK_DETACH op (kernel: bpf_tracing_link has
    // _release/_dealloc but no _detach), so the ONLY way to detach is to drive
    // the link refcount to 0. Re-open each pinned link (fresh fd we control,
    // ref++), then unpin (drop the bpffs pin ref) and destroy our fd LAST -
    // this forces the final deref through a reference we own rather than relying
    // on bpffs inode-eviction timing after a bare unlink(). Requires this
    // process to be TAG_TRUSTED (bpf_link__open is a bpf() call) - it is, via
    // trusted_inodes inode-trust, regardless of relative/absolute invocation.
    var detached: usize = 0;
    for (names.items) |name| {
        var fbuf: [MAX_PATH_BYTES]u8 = undefined;
        const fp = std.fmt.bufPrintZ(&fbuf, "{s}/{s}", .{ pin_dir, name }) catch continue;
        const link = c.bpf_link__open(fp.ptr);
        if (link != null and c.libbpf_get_error(link) == 0) {
            _ = c.bpf_link__detach(link); // no-op (-EOPNOTSUPP) for LSM; harmless
            _ = c.bpf_link__unpin(link); // unlink the bpffs pin
            _ = c.bpf_link__destroy(link); // close our fd -> last ref -> release
            detached += 1;
        } else {
            if (c.unlink(fp.ptr) == 0) detached += 1; // fallback
        }
    }
    std.log.info("detached {d} pinned links from {s} (refcount-to-zero teardown).", .{ detached, pin_dir });
    _ = c.rmdir(zdir.ptr);
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
        10 => "create",
        11 => "cred_read",
        12 => "tainted_connect",
        20 => "ptrace",
        21 => "dev_mem",
        22 => "module_load",
        23 => "capability",
        24 => "mount",
        25 => "bpf",
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

    logWrite(json);
    logWrite("\n");
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
    logWrite(json);
    logWrite("\n");
    return 0;
}

// ===================================================================
// Misc
// ===================================================================

fn openLog(path: []const u8) void {
    var zbuf: [MAX_PATH_BYTES]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return;
    const fd = c.open(zpath.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o644));
    if (fd < 0) {
        std.log.warn("cannot open log '{s}' (continuing without file log)", .{path});
        return;
    }
    g_log_fd = fd;
}

fn loadConfig(path: []const u8) !std.json.Parsed(RawConfig) {
    var zbuf: [MAX_PATH_BYTES]u8 = undefined;
    const zpath = try std.fmt.bufPrintZ(&zbuf, "{s}", .{path});
    const fd = c.open(zpath.ptr, c.O_RDONLY);
    if (fd < 0) return error.ConfigOpenFailed;
    defer _ = c.close(fd);

    const size = c.lseek(fd, 0, c.SEEK_END);
    if (size < 0 or size > (1 << 20)) return error.ConfigTooLarge;
    _ = c.lseek(fd, 0, c.SEEK_SET);

    const content = try g_alloc.alloc(u8, @intCast(size));
    defer g_alloc.free(content);
    var total: usize = 0;
    while (total < content.len) {
        const n = c.read(fd, content.ptr + total, content.len - total);
        if (n < 0) return error.ConfigReadFailed;
        if (n == 0) break;
        total += @intCast(n);
    }
    // alloc_always: copy every string into the Parsed arena so it stays valid
    // after `content` is freed (default alloc_if_needed references the input).
    return std.json.parseFromSlice(RawConfig, g_alloc, content[0..total], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
