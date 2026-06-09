// Meshy 3D provider — async generation via the job worker.
//
// Meshy operations are long-running (submit returns a task id; poll until the
// task reaches a terminal status). They are dispatched as job types
// (3d/generate, 3d/remesh, 3d/retexture, 3d/rig, 3d/animate) by the cosmic-duck
// client through POST /qai/v1/jobs, so the cores here are invoked by the job
// worker (jobs.zig), which already runs on a background thread — blocking on
// the poll is fine there.
//
// Wire contract (from the quantum-sdk client the apps use):
//   submit:  POST  https://api.meshy.ai/openapi/<path>      → { "result": "<task_id>" }
//   poll:    GET   https://api.meshy.ai/openapi/<path>/<id>  → TaskResult
//   TaskResult: { id, status, progress, model_urls{glb,fbx,obj,usdz,stl,blend}, ... }
//   terminal status: "SUCCEEDED" | "FAILED"
// Auth: Authorization: Bearer MESHY_API_KEY.
//
// The job result returned to the client is the final TaskResult JSON with
// task_id + cost_ticks + balance_after merged in (cosmic-duck reads
// result.model_urls and a task id). Billed flat per generation from the
// registry's per_unit_ticks (meshy-6 $0.20, meshy-remesh $0.10, …).
//
// NOTE: a single background worker serializes jobs, so a slow Meshy poll
// (minutes) delays other queued jobs. Acceptable for now; documented in
// FEATURE_PARITY.md as a follow-up (multiple workers / non-blocking poll).

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const models_mod = @import("models.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const ledger_mod = @import("ledger.zig");
const router = @import("router.zig");
const Response = router.Response;

const BASE = "https://api.meshy.ai/openapi";
const POLL_INTERVAL_NS: u64 = 5 * std.time.ns_per_s;
const MAX_POLL_ATTEMPTS: u32 = 120; // ~10 min at 5s

// ── Request shapes (job params from the client) ──────────────────────

const GenerateParams = struct {
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    topology: ?[]const u8 = null,
    target_polycount: ?u32 = null,
    symmetry_mode: ?[]const u8 = null,
    pose_mode: ?[]const u8 = null,
    enable_pbr: ?bool = null,
};

const RemeshParams = struct {
    input_task_id: ?[]const u8 = null,
    model_url: ?[]const u8 = null,
    target_formats: ?[]const []const u8 = null,
    topology: ?[]const u8 = null,
    target_polycount: ?u32 = null,
    resize_height: ?f64 = null,
    origin_at: ?[]const u8 = null,
    convert_format_only: ?bool = null,
};

const RetextureParams = struct {
    input_task_id: ?[]const u8 = null,
    model_url: ?[]const u8 = null,
    prompt: []const u8 = "",
    enable_pbr: ?bool = null,
    ai_model: ?[]const u8 = null,
};

const RigParams = struct {
    input_task_id: ?[]const u8 = null,
    model_url: ?[]const u8 = null,
    height_meters: ?f64 = null,
};

const AnimateParams = struct {
    rig_task_id: []const u8 = "",
    action_id: i64 = 0,
};

// ── Job-worker entry points (one per 3d/* type) ──────────────────────

pub fn generateCore(a: std.mem.Allocator, env: *const std.process.Environ.Map, io: ?std.Io, st: ?*store_mod.Store, au: ?*const types.AuthContext, lg: ?*ledger_mod.Ledger, body: []const u8) Response {
    const p = parse(GenerateParams, a, body) orelse return err("invalid 3d/generate params");
    const model = p.model orelse "meshy-6";
    const topology = p.topology orelse "triangle";

    // Build submit body + choose the text-to-3d vs image-to-3d path.
    var submit_path: []const u8 = undefined;
    const submit_body = blk: {
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        jw.beginObject() catch return err("build");
        if (p.image_url) |img| {
            submit_path = "/v1/image-to-3d";
            field(&jw, "image_url", img);
            field(&jw, "ai_model", model);
            boolField(&jw, "should_texture", true);
            boolField(&jw, "enable_pbr", p.enable_pbr orelse false);
            field(&jw, "topology", topology);
        } else {
            const prompt = p.prompt orelse return err("prompt required for text-to-3D");
            submit_path = "/v2/text-to-3d";
            field(&jw, "mode", "preview");
            field(&jw, "prompt", prompt);
            field(&jw, "ai_model", model);
            field(&jw, "topology", topology);
        }
        if (p.target_polycount) |tp| intField(&jw, "target_polycount", tp);
        if (p.symmetry_mode) |s| field(&jw, "symmetry_mode", s);
        if (p.pose_mode) |s| field(&jw, "pose_mode", s);
        jw.endObject() catch return err("build");
        break :blk aw.toOwnedSlice() catch return err("build");
    };
    return run(a, env, io, st, au, lg, model, submit_path, submit_body, "3d/generate");
}

pub fn remeshCore(a: std.mem.Allocator, env: *const std.process.Environ.Map, io: ?std.Io, st: ?*store_mod.Store, au: ?*const types.AuthContext, lg: ?*ledger_mod.Ledger, body: []const u8) Response {
    const p = parse(RemeshParams, a, body) orelse return err("invalid 3d/remesh params");
    if (p.input_task_id == null and p.model_url == null) return err("input_task_id or model_url required");
    const submit_body = blk: {
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        jw.beginObject() catch return err("build");
        if (p.input_task_id) |v| field(&jw, "input_task_id", v);
        if (p.model_url) |v| field(&jw, "model_url", v);
        if (p.target_formats) |fmts| {
            jw.objectField("target_formats") catch {};
            jw.write(fmts) catch {};
        }
        if (p.topology) |v| field(&jw, "topology", v);
        if (p.target_polycount) |v| intField(&jw, "target_polycount", v);
        if (p.origin_at) |v| field(&jw, "origin_at", v);
        if (p.convert_format_only) |v| boolField(&jw, "convert_format_only", v);
        jw.endObject() catch return err("build");
        break :blk aw.toOwnedSlice() catch return err("build");
    };
    return run(a, env, io, st, au, lg, "meshy-remesh", "/v1/remesh", submit_body, "3d/remesh");
}

pub fn retextureCore(a: std.mem.Allocator, env: *const std.process.Environ.Map, io: ?std.Io, st: ?*store_mod.Store, au: ?*const types.AuthContext, lg: ?*ledger_mod.Ledger, body: []const u8) Response {
    const p = parse(RetextureParams, a, body) orelse return err("invalid 3d/retexture params");
    if (p.input_task_id == null and p.model_url == null) return err("input_task_id or model_url required");
    if (p.prompt.len == 0) return err("prompt required");
    const submit_body = blk: {
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        jw.beginObject() catch return err("build");
        if (p.input_task_id) |v| field(&jw, "input_task_id", v);
        if (p.model_url) |v| field(&jw, "model_url", v);
        field(&jw, "prompt", p.prompt);
        boolField(&jw, "enable_pbr", p.enable_pbr orelse false);
        field(&jw, "ai_model", p.ai_model orelse "meshy-6");
        jw.endObject() catch return err("build");
        break :blk aw.toOwnedSlice() catch return err("build");
    };
    return run(a, env, io, st, au, lg, "meshy-texture", "/v1/retexture", submit_body, "3d/retexture");
}

pub fn rigCore(a: std.mem.Allocator, env: *const std.process.Environ.Map, io: ?std.Io, st: ?*store_mod.Store, au: ?*const types.AuthContext, lg: ?*ledger_mod.Ledger, body: []const u8) Response {
    const p = parse(RigParams, a, body) orelse return err("invalid 3d/rig params");
    if (p.input_task_id == null and p.model_url == null) return err("input_task_id or model_url required");
    const submit_body = blk: {
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        jw.beginObject() catch return err("build");
        if (p.input_task_id) |v| field(&jw, "input_task_id", v);
        if (p.model_url) |v| field(&jw, "model_url", v);
        if (p.height_meters) |v| {
            jw.objectField("height_meters") catch {};
            jw.write(v) catch {};
        }
        jw.endObject() catch return err("build");
        break :blk aw.toOwnedSlice() catch return err("build");
    };
    return run(a, env, io, st, au, lg, "meshy-6", "/v1/rig", submit_body, "3d/rig");
}

pub fn animateCore(a: std.mem.Allocator, env: *const std.process.Environ.Map, io: ?std.Io, st: ?*store_mod.Store, au: ?*const types.AuthContext, lg: ?*ledger_mod.Ledger, body: []const u8) Response {
    const p = parse(AnimateParams, a, body) orelse return err("invalid 3d/animate params");
    if (p.rig_task_id.len == 0) return err("rig_task_id required");
    const submit_body = blk: {
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        jw.beginObject() catch return err("build");
        field(&jw, "rig_task_id", p.rig_task_id);
        intField(&jw, "action_id", @intCast(p.action_id));
        jw.endObject() catch return err("build");
        break :blk aw.toOwnedSlice() catch return err("build");
    };
    return run(a, env, io, st, au, lg, "meshy-6", "/v1/animate", submit_body, "3d/animate");
}

// ── Shared submit → poll → bill → respond ────────────────────────────

fn run(
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    io_opt: ?std.Io,
    st: ?*store_mod.Store,
    au: ?*const types.AuthContext,
    lg: ?*ledger_mod.Ledger,
    pricing_model: []const u8,
    submit_path: []const u8,
    submit_body: []const u8,
    endpoint: []const u8,
) Response {
    const io = io_opt orelse return err("io unavailable");
    const api_key = hs.ai.getApiKeyFromEnv(env, "MESHY_API_KEY") catch return errStatus(.service_unavailable, "Meshy not configured (MESHY_API_KEY unset)");

    // Flat per-generation cost.
    const model = models_mod.getModel(pricing_model);
    const cost: i64 = if (model) |m| m.per_unit_ticks else 2_000_000_000; // $0.20 default
    const margin_bps: i64 = if (model) |m| m.margin_bps else 2500;
    const margin = @divFloor(cost * margin_bps, 10000);

    var reservation_id: ?u64 = null;
    if (st) |s| if (au) |auth| {
        if (auth.account.role != .admin) {
            reservation_id = s.reserve(io, auth.account.id.slice(), auth.key_hash, @max(cost + margin, 1000), endpoint, pricing_model) catch |e| switch (e) {
                error.InsufficientBalance => return errStatus(.payment_required, "Account balance is too low for this 3D generation"),
                else => return err("reserve failed"),
            };
        }
    };

    var client = hs.HttpClient.init(a) catch return rollbackErr(st, io, reservation_id, "http init");
    defer client.deinit();

    const auth_header = std.fmt.allocPrint(a, "Bearer {s}", .{api_key}) catch return rollbackErr(st, io, reservation_id, "alloc");
    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
    };

    // Submit.
    const submit_url = std.fmt.allocPrint(a, "{s}{s}", .{ BASE, submit_path }) catch return rollbackErr(st, io, reservation_id, "alloc");
    var sresp = client.post(submit_url, &headers, submit_body) catch return rollbackErr(st, io, reservation_id, "Meshy submit failed");
    const task_id = blk: {
        defer sresp.deinit();
        if (@intFromEnum(sresp.status) >= 300) return rollbackErr(st, io, reservation_id, "Meshy rejected the submit");
        const Submit = struct { result: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Submit, a, sresp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return rollbackErr(st, io, reservation_id, "parse submit");
        defer parsed.deinit();
        if (parsed.value.result.len == 0) return rollbackErr(st, io, reservation_id, "no task id");
        break :blk a.dupe(u8, parsed.value.result) catch return rollbackErr(st, io, reservation_id, "alloc");
    };

    // Poll.
    const poll_url = std.fmt.allocPrint(a, "{s}{s}/{s}", .{ BASE, submit_path, task_id }) catch return rollbackErr(st, io, reservation_id, "alloc");
    var attempt: u32 = 0;
    while (attempt < MAX_POLL_ATTEMPTS) : (attempt += 1) {
        io.sleep(.{ .nanoseconds = POLL_INTERVAL_NS }, .real) catch {};
        var presp = client.get(poll_url, headers[0..2]) catch continue;
        // Inspect status; on terminal, build the response (presp owns the body).
        const Status = struct { status: []const u8 = "" };
        const sp = std.json.parseFromSlice(Status, a, presp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            presp.deinit();
            continue;
        };
        const status = sp.value.status;
        if (std.mem.eql(u8, status, "SUCCEEDED")) {
            const out = buildResult(a, presp.body, task_id, cost + margin, st, au, io, reservation_id, cost, margin, lg, endpoint, pricing_model);
            presp.deinit();
            return out;
        }
        if (std.mem.eql(u8, status, "FAILED") or std.mem.eql(u8, status, "CANCELED")) {
            presp.deinit();
            return rollbackErr(st, io, reservation_id, "Meshy task failed");
        }
        presp.deinit(); // still IN_PROGRESS / PENDING — keep polling
    }
    return rollbackErr(st, io, reservation_id, "Meshy task timed out");
}

/// Merge the final TaskResult with billing fields and commit the reservation.
fn buildResult(
    a: std.mem.Allocator,
    task_body: []const u8,
    task_id: []const u8,
    cost_total: i64,
    st: ?*store_mod.Store,
    au: ?*const types.AuthContext,
    io: std.Io,
    reservation_id: ?u64,
    cost: i64,
    margin: i64,
    lg: ?*ledger_mod.Ledger,
    endpoint: []const u8,
    pricing_model: []const u8,
) Response {
    var balance_after: i64 = 0;
    if (reservation_id) |rid| if (st) |s| s.commitReservation(io, rid, cost, margin) catch {};
    if (au) |auth| if (st) |s| {
        if (s.getAccount(auth.account.id.slice())) |acct| balance_after = acct.balance_ticks;
    };

    if (lg) |l| {
        const acct_id = if (au) |auth| auth.account.id.slice() else "anonymous";
        const key_pfx = if (au) |auth| auth.key.prefix.slice() else "none";
        l.recordBilling(io, acct_id, key_pfx, cost, margin, balance_after, endpoint, pricing_model, 0, 0, 0);
    }

    // Parse the TaskResult and re-emit with task_id + cost fields injected.
    const parsed = std.json.parseFromSlice(std.json.Value, a, task_body, .{}) catch
        return .{ .status = .ok, .body = a.dupe(u8, task_body) catch task_body };
    if (parsed.value != .object) return .{ .status = .ok, .body = a.dupe(u8, task_body) catch task_body };
    var obj = parsed.value.object;
    obj.put(a, "task_id", .{ .string = task_id }) catch {};
    obj.put(a, "cost_ticks", .{ .integer = cost_total }) catch {};
    obj.put(a, "balance_after", .{ .integer = balance_after }) catch {};
    const out = std.json.Stringify.valueAlloc(a, std.json.Value{ .object = obj }, .{}) catch
        return .{ .status = .ok, .body = a.dupe(u8, task_body) catch task_body };
    return .{ .status = .ok, .body = out };
}

// ── helpers ──────────────────────────────────────────────────────────

fn parse(comptime T: type, a: std.mem.Allocator, body: []const u8) ?T {
    const parsed = std.json.parseFromSlice(T, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return parsed.value; // arena-backed; valid for the job's lifetime
}

fn field(jw: *std.json.Stringify, name: []const u8, value: []const u8) void {
    jw.objectField(name) catch {};
    jw.write(value) catch {};
}
fn intField(jw: *std.json.Stringify, name: []const u8, value: u32) void {
    jw.objectField(name) catch {};
    jw.write(value) catch {};
}
fn boolField(jw: *std.json.Stringify, name: []const u8, value: bool) void {
    jw.objectField(name) catch {};
    jw.write(value) catch {};
}

fn rollbackErr(st: ?*store_mod.Store, io: std.Io, reservation_id: ?u64, msg: []const u8) Response {
    if (reservation_id) |rid| if (st) |s| s.rollbackReservation(io, rid);
    return err(msg);
}

fn err(message: []const u8) Response {
    _ = message;
    return .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Meshy 3D job failed\"}" };
}

fn errStatus(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"Meshy 3D is not configured on this server\"}" },
        .payment_required => .{ .status = .payment_required, .body = "{\"error\":\"insufficient_balance\",\"message\":\"Account balance is too low for this 3D generation\"}" },
        else => .{ .status = status, .body = "{\"error\":\"provider_error\",\"message\":\"Meshy 3D job failed\"}" },
    };
}
