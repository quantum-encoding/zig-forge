// Ledger + Audit Trail — append-only JSONL files
// Every billing event → ledger.jsonl (permanent financial record)
// Every API request → audit.jsonl (full request log)
// Separate spinlock from store — audit writes never block auth/billing.

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const types = @import("store/types.zig");

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
        const line = std.fmt.allocPrint(self.allocator,
            \\{{"seq":{d},"account_id":"{s}","key_prefix":"{s}","cost_ticks":{d},"margin_ticks":{d},"total_ticks":{d},"balance_after":{d},"endpoint":"{s}","model":"{s}","input_tokens":{d},"output_tokens":{d},"latency_ms":{d},"ts":{d}}}
        ++ "\n", .{
            self.seq,
            account_id,
            key_prefix,
            cost_ticks,
            margin_ticks,
            cost_ticks + margin_ticks,
            balance_after,
            endpoint,
            model,
            input_tokens,
            output_tokens,
            latency_ms,
            types.nowMs(),
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
        const line = std.fmt.allocPrint(self.allocator,
            \\{{"seq":{d},"type":"credit","account_id":"{s}","amount_ticks":{d},"balance_after":{d},"admin_key":"{s}","ts":{d}}}
        ++ "\n", .{
            self.seq,
            account_id,
            amount_ticks,
            balance_after,
            admin_key_prefix,
            types.nowMs(),
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

        const line = std.fmt.allocPrint(self.allocator,
            \\{{"key":"{s}","account":"{s}","endpoint":"{s}","method":"{s}","status":{d},"model":"{s}","in":{d},"out":{d},"cost":{d},"ms":{d},"ts":{d}}}
        ++ "\n", .{
            key_prefix,
            account_id,
            endpoint,
            method,
            status_code,
            model,
            input_tokens,
            output_tokens,
            cost_ticks,
            latency_ms,
            types.nowMs(),
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
