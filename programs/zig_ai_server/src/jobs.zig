// Async job subsystem — in-process queue + background worker.
//
//   POST /qai/v1/jobs        enqueue { type, params } → { job_id, status }
//   GET  /qai/v1/jobs        list this account's jobs
//   GET  /qai/v1/jobs/{id}   job status + result
//
// Wire-compatible with the Go gateway's job endpoints. A job's `type` is the
// endpoint path it defers (e.g. "audio/tts", "images/generate") and its
// `params` is exactly that endpoint's request body — so a job is the async
// form of the matching synchronous call. A single background worker pulls
// queued jobs FIFO and dispatches each to the same body-core handler the
// sync route uses, so **billing happens once, at processing time, against the
// live balance** (reserve/commit inside the core). No double-billing, no
// separate async billing path.
//
// Supported types today: images/generate, images/edit, embeddings, audio/tts,
// audio/stt, audio/music, audio/sound-effects. Other Go job types
// (video/generate, 3d/*, chat) need provider-side long-running-operation
// polling and remain unsupported (the job fails fast with a clear message).
//
// Memory: each job is heap-allocated and never moved, so the worker can hold
// a stable pointer while processing without the store lock. Per-job work runs
// in an arena freed after the result is copied into the store allocator.
// Concurrency: a spinlock guards the map + FIFO queue; the worker releases it
// for the (slow) provider call and re-acquires only to publish the result.

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const store_mod = @import("store/store.zig");
const ledger_mod = @import("ledger.zig");
const types = @import("store/types.zig");
const Response = router.Response;

const images = @import("images.zig");
const embeddings = @import("embeddings.zig");
const audio = @import("audio.zig");
const meshy = @import("meshy.zig");
const video = @import("video.zig");
const heygen = @import("heygen.zig");

const MAX_PARAMS: usize = 40 * 1024 * 1024; // base64 image/audio params run large
const MAX_JOBS: usize = 10_000; // bound the in-memory store

const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),
    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

const Status = enum { queued, processing, completed, failed };

fn statusStr(s: Status) []const u8 {
    return switch (s) {
        .queued => "queued",
        .processing => "processing",
        .completed => "completed",
        .failed => "failed",
    };
}

const Job = struct {
    id: u64,
    account_id: [64]u8 = undefined, // owned copy (FixedStr64-sized)
    account_id_len: usize = 0,
    jtype: []const u8, // owned
    params: []const u8, // owned (the deferred endpoint's request body)
    auth: types.AuthContext, // value snapshot for billing at processing time
    status: Status = .queued,
    result: []const u8 = "", // owned when set
    err: []const u8 = "", // owned when set
    created_at: i64 = 0,
    started_at: i64 = 0,
    completed_at: i64 = 0,

    fn accountId(self: *const Job) []const u8 {
        return self.account_id[0..self.account_id_len];
    }
};

pub const JobStore = struct {
    allocator: std.mem.Allocator,
    mutex: SpinLock = .{},
    map: std.AutoHashMapUnmanaged(u64, *Job) = .empty,
    queue: std.ArrayListUnmanaged(u64) = .empty,
    next_id: u64 = 1,

    // Worker dependencies (process-lifetime; set at init).
    io: std.Io,
    billing_store: *store_mod.Store,
    ledger: *ledger_mod.Ledger,
    environ_map: *const std.process.Environ.Map,
    shutdown: *std.atomic.Value(u32),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        billing_store: *store_mod.Store,
        ledger: *ledger_mod.Ledger,
        environ_map: *const std.process.Environ.Map,
        shutdown: *std.atomic.Value(u32),
    ) JobStore {
        return .{
            .allocator = allocator,
            .io = io,
            .billing_store = billing_store,
            .ledger = ledger,
            .environ_map = environ_map,
            .shutdown = shutdown,
        };
    }
};

// ── HTTP handlers ────────────────────────────────────────────────────

const CreateRequest = struct {
    type: []const u8 = "",
    params: std.json.Value = .null,
};

/// POST /qai/v1/jobs
pub fn handleCreate(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    js: *JobStore,
    auth: *const types.AuthContext,
) Response {
    const json_util = @import("json.zig");
    const body = json_util.readBody(request, allocator, MAX_PARAMS) catch {
        return err(.bad_request, "Failed to read request body");
    };
    defer allocator.free(body);
    if (body.len == 0) return err(.bad_request, "Empty request body");

    const parsed = std.json.parseFromSlice(CreateRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return err(.bad_request, "invalid JSON body");
    };
    defer parsed.deinit();

    if (parsed.value.type.len == 0) return err(.bad_request, "type is required");
    if (!isSupported(parsed.value.type)) return err(.bad_request, "unsupported job type");

    // Re-serialize params to bytes (the deferred endpoint's body), then enqueue.
    const params_bytes = std.json.Stringify.valueAlloc(allocator, parsed.value.params, .{}) catch {
        return err(.internal_server_error, "could not capture params");
    };
    defer allocator.free(params_bytes);

    const job_id = enqueueJob(js, parsed.value.type, params_bytes, auth) orelse
        return err(.service_unavailable, "could not enqueue job");

    const out = std.json.Stringify.valueAlloc(allocator, .{
        .job_id = job_id,
        .status = "queued",
        .type = parsed.value.type,
    }, .{}) catch return err(.internal_server_error, "serialize failed");
    return .{ .body = out };
}

/// Create + enqueue a job. Dups `jtype` and `params` into the store allocator
/// (so callers may pass borrowed slices). Returns the new job id, or null if
/// the queue is full / allocation failed. Used by handleCreate and by the
/// sync routes that defer a long-running op (e.g. video/translate).
pub fn enqueueJob(js: *JobStore, jtype: []const u8, params: []const u8, auth: *const types.AuthContext) ?u64 {
    const params_bytes = js.allocator.dupe(u8, params) catch return null;
    const jt = js.allocator.dupe(u8, jtype) catch {
        js.allocator.free(params_bytes);
        return null;
    };
    const job = js.allocator.create(Job) catch {
        js.allocator.free(params_bytes);
        js.allocator.free(jt);
        return null;
    };
    job.* = .{
        .id = 0,
        .jtype = jt,
        .params = params_bytes,
        .auth = auth.*,
        .created_at = types.nowMs(js.io),
    };
    const aid = auth.account.id.slice();
    const aid_len = @min(aid.len, job.account_id.len);
    @memcpy(job.account_id[0..aid_len], aid[0..aid_len]);
    job.account_id_len = aid_len;

    js.mutex.lock();
    if (js.map.count() >= MAX_JOBS) {
        js.mutex.unlock();
        js.allocator.free(params_bytes);
        js.allocator.free(jt);
        js.allocator.destroy(job);
        return null;
    }
    job.id = js.next_id;
    js.next_id += 1;
    const put_ok = blk: {
        js.map.put(js.allocator, job.id, job) catch break :blk false;
        js.queue.append(js.allocator, job.id) catch break :blk false;
        break :blk true;
    };
    js.mutex.unlock();
    if (!put_ok) {
        js.allocator.free(params_bytes);
        js.allocator.free(jt);
        js.allocator.destroy(job);
        return null;
    }
    return job.id;
}

/// POST /qai/v1/batch — fan out N requests as queued jobs.
/// Body: { requests: [ { type, params }, ... ] } → { jobs: [ { job_id, type } ] }.
pub fn handleBatch(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    js: *JobStore,
    auth: *const types.AuthContext,
) Response {
    const json_util = @import("json.zig");
    const body = json_util.readBody(request, allocator, MAX_PARAMS) catch return err(.bad_request, "read body");
    defer allocator.free(body);

    const Batch = struct {
        requests: []const struct {
            type: []const u8 = "",
            params: std.json.Value = .null,
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Batch, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return err(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    if (parsed.value.requests.len == 0) return err(.bad_request, "requests is required");
    if (parsed.value.requests.len > 1000) return err(.bad_request, "batch too large (max 1000)");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    jw.beginObject() catch return err(.internal_server_error, "serialize");
    jw.objectField("jobs") catch {};
    jw.beginArray() catch {};
    for (parsed.value.requests) |r| {
        if (r.type.len == 0 or !isSupported(r.type)) continue;
        const params_bytes = std.json.Stringify.valueAlloc(allocator, r.params, .{}) catch continue;
        defer allocator.free(params_bytes);
        const jid = enqueueJob(js, r.type, params_bytes, auth) orelse continue;
        jw.beginObject() catch {};
        jw.objectField("job_id") catch {};
        jw.write(jid) catch {};
        jw.objectField("type") catch {};
        jw.write(r.type) catch {};
        jw.endObject() catch {};
    }
    jw.endArray() catch {};
    jw.objectField("status") catch {};
    jw.write("queued") catch {};
    jw.endObject() catch return err(.internal_server_error, "serialize");
    const out = aw.toOwnedSlice() catch return err(.internal_server_error, "serialize");
    return .{ .body = out };
}

/// GET /qai/v1/jobs/{id}
pub fn handleStatus(
    allocator: std.mem.Allocator,
    js: *JobStore,
    auth: *const types.AuthContext,
    id_str: []const u8,
) Response {
    const id = std.fmt.parseInt(u64, id_str, 10) catch return err(.bad_request, "invalid job id");

    js.mutex.lock();
    const maybe = js.map.get(id);
    // Snapshot the fields we need under lock (the worker may mutate concurrently).
    var snap_status: Status = .queued;
    var snap_type: []const u8 = "";
    var snap_result: []const u8 = "";
    var snap_err: []const u8 = "";
    var snap_created: i64 = 0;
    var snap_started: i64 = 0;
    var snap_completed: i64 = 0;
    var owns = false;
    if (maybe) |job| {
        // Account scoping: only the owner (or admin) can read a job.
        if (auth.account.role == .admin or std.mem.eql(u8, job.accountId(), auth.account.id.slice())) {
            owns = true;
            snap_status = job.status;
            snap_type = job.jtype;
            snap_result = job.result;
            snap_err = job.err;
            snap_created = job.created_at;
            snap_started = job.started_at;
            snap_completed = job.completed_at;
        }
    }
    js.mutex.unlock();

    if (maybe == null or !owns) return err(.not_found, "job not found");

    // Build response. `result` is embedded as raw JSON when present.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    jw.beginObject() catch return err(.internal_server_error, "serialize failed");
    jw.objectField("job_id") catch {};
    jw.write(id) catch {};
    jw.objectField("type") catch {};
    jw.write(snap_type) catch {};
    jw.objectField("status") catch {};
    jw.write(statusStr(snap_status)) catch {};
    if (snap_result.len > 0) {
        jw.objectField("result") catch {};
        // result is already-valid JSON from the core handler — emit verbatim.
        jw.print("{s}", .{snap_result}) catch {};
    }
    if (snap_err.len > 0) {
        jw.objectField("error") catch {};
        jw.write(snap_err) catch {};
    }
    jw.objectField("created_at") catch {};
    jw.write(snap_created) catch {};
    if (snap_started > 0) {
        jw.objectField("started_at") catch {};
        jw.write(snap_started) catch {};
    }
    if (snap_completed > 0) {
        jw.objectField("completed_at") catch {};
        jw.write(snap_completed) catch {};
    }
    jw.endObject() catch return err(.internal_server_error, "serialize failed");
    const out = aw.toOwnedSlice() catch return err(.internal_server_error, "serialize failed");
    return .{ .body = out };
}

/// GET /qai/v1/jobs
pub fn handleList(
    allocator: std.mem.Allocator,
    js: *JobStore,
    auth: *const types.AuthContext,
) Response {
    const Brief = struct {
        job_id: u64,
        type: []const u8,
        status: []const u8,
        created_at: i64,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayListUnmanaged(Brief) = .empty;

    const is_admin = auth.account.role == .admin;
    const my_id = auth.account.id.slice();

    js.mutex.lock();
    var it = js.map.valueIterator();
    while (it.next()) |jp| {
        const job = jp.*;
        if (!is_admin and !std.mem.eql(u8, job.accountId(), my_id)) continue;
        list.append(a, .{
            .job_id = job.id,
            .type = a.dupe(u8, job.jtype) catch continue,
            .status = statusStr(job.status),
            .created_at = job.created_at,
        }) catch break;
    }
    js.mutex.unlock();

    std.mem.sort(Brief, list.items, {}, struct {
        fn f(_: void, l: Brief, r: Brief) bool {
            return l.job_id > r.job_id;
        }
    }.f);

    const out = std.json.Stringify.valueAlloc(allocator, .{ .jobs = list.items }, .{}) catch
        return err(.internal_server_error, "serialize failed");
    return .{ .body = out };
}

/// GET /qai/v1/jobs/{id}/stream — SSE progress stream. Writes directly to the
/// connection (the caller marks the response handled). Polls the job store
/// once a second, emitting `progress` events, then a terminal `complete` /
/// `error` event with the result. Caller-supplied id; ownership enforced.
pub fn handleStream(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    js: *JobStore,
    auth: *const types.AuthContext,
    id_str: []const u8,
) void {
    const id = std.fmt.parseInt(u64, id_str, 10) catch return;

    var stream_buf: [4096]u8 = undefined;
    var hdrs = [_]http.Header{
        .{ .name = "content-type", .value = "text/event-stream" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    var bw = request.respondStreaming(&stream_buf, .{
        .respond_options = .{ .status = .ok, .extra_headers = &hdrs, .keep_alive = false },
    }) catch return;

    var attempt: u32 = 0;
    while (attempt < 600) : (attempt += 1) { // ~10 min cap at 1s
        // Snapshot the job under lock.
        js.mutex.lock();
        const maybe = js.map.get(id);
        var owned = false;
        var status: Status = .queued;
        var result_ptr: []const u8 = "";
        var err_ptr: []const u8 = "";
        if (maybe) |job| {
            if (auth.account.role == .admin or std.mem.eql(u8, job.accountId(), auth.account.id.slice())) {
                owned = true;
                status = job.status;
                result_ptr = job.result;
                err_ptr = job.err;
            }
        }
        js.mutex.unlock();

        if (maybe == null or !owned) {
            bw.writer.writeAll("data: {\"type\":\"error\",\"error\":\"job not found\"}\n\n") catch {};
            break;
        }
        if (status == .completed) {
            emitComplete(allocator, &bw, result_ptr);
            break;
        }
        if (status == .failed) {
            bw.writer.writeAll("data: {\"type\":\"error\",\"status\":\"failed\"}\n\n") catch {};
            bw.writer.flush() catch {};
            break;
        }
        // queued / processing → progress tick.
        bw.writer.writeAll("data: {\"type\":\"progress\",\"status\":\"processing\"}\n\n") catch break;
        bw.writer.flush() catch break;
        io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .real) catch break;
    }

    bw.writer.writeAll("data: {\"type\":\"done\"}\n\n") catch {};
    bw.end() catch {};
}

/// Emit the terminal `complete` SSE event, embedding the job's result JSON.
fn emitComplete(allocator: std.mem.Allocator, bw: anytype, result_json: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Parse the result so it embeds as structured JSON (not a quoted string).
    const rv: std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, a, result_json, .{}) catch
        .{ .string = result_json };
    const frame = std.json.Stringify.valueAlloc(a, .{
        .type = "complete",
        .status = "completed",
        .result = rv,
    }, .{}) catch {
        bw.writer.writeAll("data: {\"type\":\"complete\",\"status\":\"completed\"}\n\n") catch {};
        return;
    };
    bw.writer.writeAll("data: ") catch return;
    bw.writer.writeAll(frame) catch return;
    bw.writer.writeAll("\n\n") catch return;
    bw.writer.flush() catch {};
}

// ── Background worker ────────────────────────────────────────────────

/// Worker thread entry. Pulls queued jobs FIFO and processes them until the
/// shutdown flag is set. Spawned once from main.zig.
pub fn workerLoop(js: *JobStore) void {
    while (js.shutdown.load(.acquire) == 0) {
        const job = nextQueued(js) orelse {
            js.io.sleep(.{ .nanoseconds = 200 * std.time.ns_per_ms }, .real) catch return;
            continue;
        };
        processJob(js, job);
    }
}

fn nextQueued(js: *JobStore) ?*Job {
    js.mutex.lock();
    defer js.mutex.unlock();
    if (js.queue.items.len == 0) return null;
    const id = js.queue.orderedRemove(0);
    const job = js.map.get(id) orelse return null;
    job.status = .processing;
    job.started_at = types.nowMs(js.io);
    return job;
}

fn processJob(js: *JobStore, job: *Job) void {
    // Per-job arena: the core handler allocates its working set and response
    // here; we copy the final body into the store allocator, then free it all.
    var arena = std.heap.ArenaAllocator.init(js.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resp = dispatch(js, a, job);

    const body_copy: []const u8 = js.allocator.dupe(u8, resp.body) catch "";

    js.mutex.lock();
    if (resp.status == .ok) {
        job.result = body_copy;
        job.status = .completed;
    } else {
        // On failure the body is the error JSON; surface it under `error`.
        job.err = body_copy;
        job.status = .failed;
    }
    job.completed_at = types.nowMs(js.io);
    js.mutex.unlock();
}

/// Dispatch a job to the body-core of the endpoint its `type` names. Billing
/// (reserve/commit) happens inside each core against the live store, using the
/// job's captured auth snapshot.
fn dispatch(js: *JobStore, a: std.mem.Allocator, job: *Job) Response {
    const t = job.jtype;
    const env = js.environ_map;
    const io = js.io;
    const st = js.billing_store;
    const au = &job.auth;
    const lg = js.ledger;
    const p = job.params;

    if (std.mem.eql(u8, t, "images/generate")) return images.handleCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "images/edit")) return images.editCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "embeddings")) return embeddings.handleCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "audio/tts")) return audio.ttsCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "audio/stt")) return audio.sttCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "audio/music")) return audio.musicCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "audio/sound-effects")) return audio.soundEffectsCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "3d/generate")) return meshy.generateCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "3d/remesh")) return meshy.remeshCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "3d/retexture")) return meshy.retextureCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "3d/rig")) return meshy.rigCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "3d/animate")) return meshy.animateCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "video/generate")) return video.generateCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "audio/dub")) return audio.dubCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "video/translate")) return heygen.translateCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "video/studio")) return heygen.studioCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "video/digital-twin")) return heygen.digitalTwinCore(a, env, io, st, au, lg, p);
    if (std.mem.eql(u8, t, "video/photo-avatar")) return heygen.photoAvatarCore(a, env, io, st, au, lg, p);
    return err(.bad_request, "unsupported job type");
}

fn isSupported(t: []const u8) bool {
    const supported = [_][]const u8{
        "images/generate", "images/edit",  "embeddings",
        "audio/tts",       "audio/stt",    "audio/music",
        "audio/sound-effects",
        "3d/generate",     "3d/remesh",    "3d/retexture",
        "3d/rig",          "3d/animate",   "video/generate",
        "audio/dub",       "video/translate", "video/studio",
        "video/digital-twin", "video/photo-avatar",
    };
    for (supported) |s| if (std.mem.eql(u8, t, s)) return true;
    return false;
}

fn err(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"Job request rejected\"}" },
        .not_found => .{ .status = .not_found, .body = "{\"error\":\"not_found\",\"message\":\"Job not found\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"Job queue is full\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"Job request failed\"}" },
    };
}
