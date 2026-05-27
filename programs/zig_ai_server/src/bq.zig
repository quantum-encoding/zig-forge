// BigQuery Audit Logger — buffered insertAll with WaitGroup for graceful shutdown
// Every API request gets logged. Rows are batched and flushed every 5 seconds
// or when buffer hits 100 rows. SIGTERM handler waits for all pending writes.

const std = @import("std");
const gcp = @import("gcp.zig");
const types = @import("store/types.zig");

const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),
    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

pub const AuditRow = struct {
    request_id: []const u8,
    account_id: []const u8,
    key_prefix: []const u8,
    endpoint: []const u8,
    provider: []const u8, // "anthropic", "deepseek", "google", "xai", "openai"
    model: []const u8,
    input_tokens: u32,
    output_tokens: u32,
    cost_ticks: i64,
    margin_ticks: i64,
    latency_ms: u32,
    status_code: u16,
    tier: []const u8, // "free", "hobby", "pro", "enterprise"
};

pub const BqAudit = struct {
    allocator: std.mem.Allocator,
    ctx: ?*gcp.GcpContext,
    project_id: []const u8,
    dataset: []const u8,
    table: []const u8,

    // Buffer
    mutex: SpinLock = .{},
    buffer: std.ArrayListUnmanaged([]u8) = .empty, // JSON row strings
    seq: u64 = 0,

    // WaitGroup for graceful shutdown — tracks pending HTTP writes
    pending_writes: std.atomic.Value(u32) = .init(0),

    pub fn init(allocator: std.mem.Allocator, ctx: ?*gcp.GcpContext, project_id: []const u8) BqAudit {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .project_id = project_id,
            .dataset = "qai_analytics",
            .table = "zig_requests",
        };
    }

    /// Queue an audit row. Non-blocking. Flushes when buffer is full.
    pub fn log(self: *BqAudit, io: std.Io, row: AuditRow) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.seq += 1;
        // BigQuery insertAll row shape: {"json": {...field map...}}.
        // The previous implementation interpolated row.account_id /
        // row.key_prefix / row.endpoint / row.model / row.tier raw with
        // "{s}" (audit C5) — a per-request model or endpoint string
        // could forge sibling fields in the analytics audit trail
        // (M12 noted that BQ rejects silently, so the only check on
        // shape integrity was the JSON well-formedness — which the
        // injection broke). Now everything goes through
        // std.json.Stringify on a streaming writer.
        //
        // BigQuery's `created_at` column is TIMESTAMP and expects a
        // JSON STRING form ("YYYY-MM-DD HH:MM:SS.SSSSSS" or epoch ms
        // as a quoted number); we preserve the prior behaviour of
        // sending it as a quoted decimal int so the BQ schema is
        // unchanged.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        var req_id_buf: [32]u8 = undefined;
        const request_id = std.fmt.bufPrint(&req_id_buf, "req_{d}", .{self.seq}) catch return;

        var created_at_buf: [32]u8 = undefined;
        const created_at_str = std.fmt.bufPrint(&created_at_buf, "{d}", .{types.nowMs(io)}) catch return;

        jw.beginObject() catch return;
        jw.objectField("json") catch return;
        jw.beginObject() catch return;
        jw.objectField("request_id") catch return;
        jw.write(request_id) catch return;
        jw.objectField("account_id") catch return;
        jw.write(row.account_id) catch return;
        jw.objectField("key_prefix") catch return;
        jw.write(row.key_prefix) catch return;
        jw.objectField("endpoint") catch return;
        jw.write(row.endpoint) catch return;
        jw.objectField("provider") catch return;
        jw.write(row.provider) catch return;
        jw.objectField("model") catch return;
        jw.write(row.model) catch return;
        jw.objectField("input_tokens") catch return;
        jw.write(row.input_tokens) catch return;
        jw.objectField("output_tokens") catch return;
        jw.write(row.output_tokens) catch return;
        jw.objectField("cost_ticks") catch return;
        jw.write(row.cost_ticks) catch return;
        jw.objectField("margin_ticks") catch return;
        jw.write(row.margin_ticks) catch return;
        jw.objectField("latency_ms") catch return;
        jw.write(row.latency_ms) catch return;
        jw.objectField("status_code") catch return;
        jw.write(row.status_code) catch return;
        jw.objectField("tier") catch return;
        jw.write(row.tier) catch return;
        jw.objectField("created_at") catch return;
        jw.write(created_at_str) catch return;
        jw.endObject() catch return;
        jw.endObject() catch return;

        const json = aw.toOwnedSlice() catch return;

        self.buffer.append(self.allocator, json) catch {
            self.allocator.free(json);
            return;
        };

        // Auto-flush at 100 rows
        if (self.buffer.items.len >= 100) {
            self.flushLocked();
        }
    }

    /// Flush buffered rows to BigQuery. Call periodically (every 5s) and on shutdown.
    pub fn flush(self: *BqAudit) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushLocked();
    }

    fn flushLocked(self: *BqAudit) void {
        if (self.buffer.items.len == 0) return;
        if (self.ctx == null) return;

        // Take ownership of current buffer
        const rows = self.buffer.toOwnedSlice(self.allocator) catch return;
        self.buffer = .empty;

        // Track pending write
        _ = self.pending_writes.fetchAdd(1, .monotonic);

        // Build insertAll body
        const body = buildInsertBody(self.allocator, rows) orelse {
            freeRows(self.allocator, rows);
            _ = self.pending_writes.fetchSub(1, .monotonic);
            return;
        };

        // Fire-and-forget via thread (but tracked by pending_writes)
        const thread_ctx = self.allocator.create(FlushCtx) catch {
            self.allocator.free(body);
            freeRows(self.allocator, rows);
            _ = self.pending_writes.fetchSub(1, .monotonic);
            return;
        };
        thread_ctx.* = .{
            .audit = self,
            .body = body,
            .rows = rows,
        };

        const thread = std.Thread.spawn(.{}, flushThread, .{thread_ctx}) catch {
            self.allocator.free(body);
            freeRows(self.allocator, rows);
            self.allocator.destroy(thread_ctx);
            _ = self.pending_writes.fetchSub(1, .monotonic);
            return;
        };
        thread.detach();
    }

    const FlushCtx = struct {
        audit: *BqAudit,
        body: []u8,
        rows: [][]u8,
    };

    fn flushThread(ctx: *FlushCtx) void {
        defer {
            _ = ctx.audit.pending_writes.fetchSub(1, .monotonic);
            ctx.audit.allocator.free(ctx.body);
            freeRows(ctx.audit.allocator, ctx.rows);
            ctx.audit.allocator.destroy(ctx);
        }

        const gcp_ctx = ctx.audit.ctx orelse return;
        const url = std.fmt.allocPrint(ctx.audit.allocator,
            "https://bigquery.googleapis.com/bigquery/v2/projects/{s}/datasets/{s}/tables/{s}/insertAll",
            .{ ctx.audit.project_id, ctx.audit.dataset, ctx.audit.table },
        ) catch |err| {
            std.debug.print("  bq.flushThread: URL build failed ({s}); {d} audit rows dropped\n", .{ @errorName(err), ctx.rows.len });
            return;
        };
        defer ctx.audit.allocator.free(url);

        // Audit M12: previously every error here was swallowed —
        // network failures, 4xx (malformed row), 401 (token rotation),
        // 5xx (BigQuery outage) all returned silently and the rows
        // were dropped without trace. Combined with C5 (now fixed)
        // this meant the analytics audit trail could be erased by a
        // hostile payload with no operator-visible signal. We now
        // log the error class and the row count so the operator at
        // least sees that the audit pipeline lost data. We do not
        // retry: the buffered-flush model has no place to put a
        // retry queue, and reinjecting on a transient 5xx would
        // silently double-insert rows on success.
        var resp = gcp_ctx.post(url, ctx.body) catch |err| {
            std.debug.print(
                "  bq.flushThread: HTTP error {s}; {d} audit rows dropped\n",
                .{ @errorName(err), ctx.rows.len },
            );
            return;
        };
        defer resp.deinit();

        if (@intFromEnum(resp.status) >= 300) {
            // Truncate the response body in the log line so a malicious
            // upstream can't dump megabytes through std.debug.
            const body_preview = if (resp.body.len > 200) resp.body[0..200] else resp.body;
            std.debug.print(
                "  bq.flushThread: BigQuery rejected insertAll (status={d}); {d} rows dropped. body: {s}\n",
                .{ @intFromEnum(resp.status), ctx.rows.len, body_preview },
            );
        }
    }

    /// Wait for all pending BQ writes to complete. Call from SIGTERM handler.
    pub fn waitPending(self: *BqAudit) void {
        // First flush any remaining buffer
        self.flush();

        // Spin-wait for pending writes (with timeout)
        var attempts: u32 = 0;
        while (self.pending_writes.load(.acquire) > 0 and attempts < 200) : (attempts += 1) {
            // ~50ms per attempt × 200 = 10 second max wait
            std.atomic.spinLoopHint();
            var i: u32 = 0;
            while (i < 1_000_000) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn deinit(self: *BqAudit) void {
        // Free any remaining buffered rows
        for (self.buffer.items) |row| {
            self.allocator.free(row);
        }
        self.buffer.deinit(self.allocator);
    }
};

fn buildInsertBody(allocator: std.mem.Allocator, rows: [][]u8) ?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(allocator, "{\"rows\":[") catch return null;

    for (rows, 0..) |row, i| {
        if (i > 0) buf.append(allocator, ',') catch return null;
        buf.appendSlice(allocator, row) catch return null;
    }

    buf.appendSlice(allocator, "],\"skipInvalidRows\":true,\"ignoreUnknownValues\":true}") catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

fn freeRows(allocator: std.mem.Allocator, rows: [][]u8) void {
    for (rows) |row| allocator.free(row);
    allocator.free(rows);
}
