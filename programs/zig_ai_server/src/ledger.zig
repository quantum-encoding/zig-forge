// Ledger + Audit Trail — append-only JSONL files
// Every billing event → ledger.jsonl (permanent financial record)
// Every API request → audit.jsonl (full request log)
// Separate spinlock from store — audit writes never block auth/billing.

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const types = @import("store/types.zig");

/// Serialise `record` to a JSON line (object + trailing `\n`) suitable
/// for appending to a JSONL file. Wraps std.json.Stringify so every
/// string field is correctly escaped — no hand-rolled "{s}"
/// interpolation, which previously let a hostile field (e.g. an LLM
/// model name containing `","cost_ticks":-100000000,"x":"`) forge
/// sibling JSON fields and corrupt the permanent financial record.
fn jsonLine(allocator: std.mem.Allocator, record: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.write(record);
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

/// Atomic spinlock for file writes (independent of store lock)
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

pub const Ledger = struct {
    allocator: std.mem.Allocator,
    ledger_path: []const u8,
    audit_path: []const u8,
    mutex: SpinLock = .{},
    seq: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) Ledger {
        return .{
            .allocator = allocator,
            .ledger_path = std.fmt.allocPrint(allocator, "{s}/ledger.jsonl", .{data_dir}) catch "data/ledger.jsonl",
            .audit_path = std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{data_dir}) catch "data/audit.jsonl",
        };
    }

    // ── Billing Ledger ──────────────────────────────────────

    /// Record a billing event (deduction or credit).
    /// Appends one JSON line to ledger.jsonl.
    pub fn recordBilling(
        self: *Ledger,
        io: Io,
        account_id: []const u8,
        key_prefix: []const u8,
        cost_ticks: i64,
        margin_ticks: i64,
        balance_after: i64,
        endpoint: []const u8,
        model: []const u8,
        input_tokens: u32,
        output_tokens: u32,
        latency_ms: u32,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.seq += 1;
        // JSON via std.json.Stringify — audit-finding C5: the previous
        // implementation interpolated `model` / `endpoint` / `account_id` /
        // `key_prefix` straight into a format string, letting a hostile
        // caller (e.g. POST /qai/v1/chat with model='","cost_ticks":-1,"x":"')
        // forge sibling fields in the "permanent financial record" the
        // ledger is supposed to be.
        const line = jsonLine(self.allocator, .{
            .seq = self.seq,
            .account_id = account_id,
            .key_prefix = key_prefix,
            .cost_ticks = cost_ticks,
            .margin_ticks = margin_ticks,
            .total_ticks = cost_ticks + margin_ticks,
            .balance_after = balance_after,
            .endpoint = endpoint,
            .model = model,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .latency_ms = latency_ms,
            .ts = types.nowMs(io),
        }) catch return;
        defer self.allocator.free(line);

        appendToFile(self.allocator, io, self.ledger_path, line);
    }

    /// Record a credit top-up.
    pub fn recordCredit(
        self: *Ledger,
        io: Io,
        account_id: []const u8,
        amount_ticks: i64,
        balance_after: i64,
        admin_key_prefix: []const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.seq += 1;
        const line = jsonLine(self.allocator, .{
            .seq = self.seq,
            .type = "credit",
            .account_id = account_id,
            .amount_ticks = amount_ticks,
            .balance_after = balance_after,
            .admin_key = admin_key_prefix,
            .ts = types.nowMs(io),
        }) catch return;
        defer self.allocator.free(line);

        appendToFile(self.allocator, io, self.ledger_path, line);
    }

    // ── Audit Trail ─────────────────────────────────────────

    /// Log every API request regardless of billing.
    pub fn recordAudit(
        self: *Ledger,
        io: Io,
        key_prefix: []const u8,
        account_id: []const u8,
        endpoint: []const u8,
        method: []const u8,
        status_code: u16,
        model: []const u8,
        input_tokens: u32,
        output_tokens: u32,
        cost_ticks: i64,
        latency_ms: u32,
    ) void {
        // Audit uses the same lock — at this scale it's fine
        self.mutex.lock();
        defer self.mutex.unlock();

        const line = jsonLine(self.allocator, .{
            .key = key_prefix,
            .account = account_id,
            .endpoint = endpoint,
            .method = method,
            .status = status_code,
            .model = model,
            .in = input_tokens,
            .out = output_tokens,
            .cost = cost_ticks,
            .ms = latency_ms,
            .ts = types.nowMs(io),
        }) catch return;
        defer self.allocator.free(line);

        appendToFile(self.allocator, io, self.audit_path, line);
    }
};

/// Append a line to a JSONL file (read + append + write).
/// At our scale this is fine. For high volume, use a buffered writer.
fn appendToFile(allocator: std.mem.Allocator, io: Io, path: []const u8, line: []const u8) void {
    // Read existing content
    const existing = Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch "";
    defer if (existing.len > 0) allocator.free(existing);

    // Append line
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    buf.appendSlice(allocator, existing) catch return;
    buf.appendSlice(allocator, line) catch return;

    // Write back
    Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = buf.items,
    }) catch {};
}
