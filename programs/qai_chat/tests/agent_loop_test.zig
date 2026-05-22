//! End-to-end test driving `agent.run` against a FakeProvider replay.
//! Proves the full turn-loop machinery — history append, usage accounting,
//! the streaming bridge from `streamEventCb` to `TurnState`, the user
//! prompt → assistant reply round-trip — works against a scripted event
//! sequence with no real HTTP in the picture. The substrate that the
//! emission-gate test from errors_and_observability_v1.md §5 will build on.
//!
//! Narrow bridge-level tests (FakeProvider in isolation) live in
//! `src/fake_provider.zig` as embedded test blocks — same code, different
//! granularity.

const std = @import("std");
const hs = @import("http-sentinel");
const agent = @import("agent");

test "agent.run with Provider.fake: drives one turn end-to-end" {
    const gpa = std.testing.allocator;

    var io_threaded = std.Io.Threaded.init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var out_alloc: std.Io.Writer.Allocating = .init(gpa);
    defer out_alloc.deinit();
    var err_alloc: std.Io.Writer.Allocating = .init(gpa);
    defer err_alloc.deinit();

    var history: std.ArrayList(hs.ai.common.AIMessage) = .empty;
    defer {
        for (history.items) |*m| m.deinit();
        history.deinit(gpa);
    }

    var approvals = agent.Approvals.init(gpa);
    defer approvals.deinit();

    var usage = agent.UsageStats.init(gpa);
    defer usage.deinit();

    // pricing cache populates lazily on the first lookup inside
    // printTurnUsage; release it explicitly so testing.allocator stays
    // clean. See docs/before_threads.md.
    defer agent.deinitPricingCache();

    var recorder = agent.FakeCallRecord.init(gpa);
    defer recorder.deinit();

    var fake_cfg = agent.FakeConfig{
        .fixture_path = "tests/fixtures/hello_world.jsonl",
        .recorder = &recorder,
    };

    try agent.run(.{
        .gpa = gpa,
        .io = io,
        .provider = .fake,
        .api_key = "",
        .base_url = "",
        .provider_name = "fake",
        .model = "fake-model",
        .max_tokens = 64,
        .temperature = 0.0,
        .system_prompt = null,
        .history = &history,
        .out = &out_alloc.writer,
        .err = &err_alloc.writer,
        .stdin = null,
        .auto_approve = true,
        .approvals = &approvals,
        .usage = &usage,
        .user_prompt = "test prompt",
        .fake = &fake_cfg,
    });

    // History should contain exactly two messages after one turn:
    // the user prompt, then the assistant's text reply. No tool_use in
    // the hello_world fixture, so the loop returns after the assistant
    // entry without a follow-up turn.
    try std.testing.expectEqual(@as(usize, 2), history.items.len);

    try std.testing.expectEqual(hs.ai.common.MessageRole.user, history.items[0].role);
    try std.testing.expectEqualStrings("test prompt", history.items[0].content);

    try std.testing.expectEqual(hs.ai.common.MessageRole.assistant, history.items[1].role);
    try std.testing.expectEqualStrings("Hello! How can I help?", history.items[1].content);
    try std.testing.expectEqual(@as(?[]hs.ai.common.ToolCall, null), history.items[1].tool_calls);

    // CallRecord should show the provider was invoked exactly once with
    // an empty history at call time (history is appended *after* the
    // streaming call returns, per agent.zig:514). This is the assertion
    // shape the emission-gate test will use: count + per-call history_len
    // proves retries (when they exist) re-invoke with reset state, not
    // accumulated state.
    try std.testing.expectEqual(@as(usize, 1), recorder.count());
    try std.testing.expectEqualStrings("test prompt", recorder.calls.items[0].prompt);
    try std.testing.expectEqual(@as(usize, 0), recorder.calls.items[0].history_len);

    // The user-facing live-stream emission still fires through args.out
    // (the bridge contract), now exercised through the full run() loop.
    try std.testing.expectEqualStrings("Hello! How can I help?\n", out_alloc.written());
}
