// SSE writer primitive.
//
// The AI server's stream.zig is heavily AI-domain — it pipes
// token-by-token chunks from provider APIs through a sendMessageStreaming
// callback. jesternet's SSE need is different: emit events read from
// the WAL-backed events log (per the durable-replay canary's contract
// property), with keep-alives between sends.
//
// So this file is NOT a literal lift; it's the same general shape
// (writer + flush per event, drop-conn on error) but with jesternet's
// event format and the WAL replay primitive as input source.
//
// Wire format per CONTRACT §6.1 and CONFORMANCE's SSE canary:
//
//   id: <durable-event-seq>\n
//   event: <kind>\n
//   data: <json-payload>\n
//   \n
//
// Plus keepalive comments:
//
//   :keepalive\n\n
//
// The id field MUST be the durable event sequence number from the WAL,
// not an in-memory id. That's what the durable-replay canary's
// `Last-Event-ID` reconnect path reads from, and it's what makes
// "every event between E1 and the current tip replays after a
// reconnect" structurally true rather than buffer-dependent.

const std = @import("std");
const http = std.http;
const Io = std.Io;

/// One SSE event ready to emit.
pub const Event = struct {
    /// Durable WAL sequence number. Becomes the SSE `id:` field; the
    /// reconnect client sends it back as Last-Event-ID and the server's
    /// `events.replayFrom(id, ...)` resumes from this position.
    id: u64,
    /// Event kind. Becomes the SSE `event:` field. Mirrors
    /// CONTRACT §5's EventKind union.
    kind: []const u8,
    /// JSON-encoded payload. Becomes the SSE `data:` field.
    data: []const u8,
};

/// Write one event to the SSE stream. Flushes after the trailing
/// blank line so the client sees the event immediately rather than
/// waiting for the next write.
pub fn writeEvent(writer: *Io.Writer, event: Event) !void {
    try writer.print("id: {d}\n", .{event.id});
    try writer.print("event: {s}\n", .{event.kind});
    try writer.print("data: {s}\n\n", .{event.data});
    try writer.flush();
}

/// Write a keep-alive comment. SSE comments start with `:` and are
/// ignored by clients but keep intermediaries from closing the
/// connection on idle.
pub fn writeKeepalive(writer: *Io.Writer) !void {
    try writer.writeAll(":keepalive\n\n");
    try writer.flush();
}

/// Write the SSE retry hint. Tells the EventSource client how long
/// to wait before reconnecting on error. The default browser retry
/// (3s) is fine for most cases; this overrides when the server wants
/// faster recovery during planned shutdowns.
pub fn writeRetry(writer: *Io.Writer, millis: u64) !void {
    try writer.print("retry: {d}\n\n", .{millis});
    try writer.flush();
}

// ── Tests ──

test "writeEvent produces a well-formed SSE record" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try writeEvent(&aw.writer, .{
        .id = 42,
        .kind = "commit.pushed",
        .data = "{\"repo\":\"jak/foo\",\"sha\":\"abc\"}",
    });

    const expected =
        "id: 42\n" ++
        "event: commit.pushed\n" ++
        "data: {\"repo\":\"jak/foo\",\"sha\":\"abc\"}\n" ++
        "\n";

    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "writeKeepalive emits a comment line" {
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try writeKeepalive(&aw.writer);
    try std.testing.expectEqualStrings(":keepalive\n\n", aw.writer.buffered());
}
