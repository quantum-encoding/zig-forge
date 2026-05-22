//! FakeProvider — scripted StreamEvent dispatch from a JSONL fixture.
//!
//! Mirrors the `sendMessageStreamingWithEvents(prompt, context, config,
//! callback, cb_context)` surface that the real AI clients in
//! http_sentinel expose, so the agent-loop bridge (`streamEventCb` in
//! agent.zig) can be exercised without real HTTP. Used by the test
//! harness to validate that scripted event sequences drive the loop
//! and produce what the design docs (messagelog v1, fanout v1,
//! errors v1) claim.
//!
//! Fixture format: one JSON object per line, `kind` discriminator,
//! remaining fields populate the matching `StreamEvent` variant. See
//! `tests/fixtures/README.md`.
//!
//! Lifetime: each fixture line is parsed, dispatched, and freed in
//! sequence. The slices inside the dispatched `StreamEvent` are
//! valid only for the duration of the callback call — same contract
//! as the real providers (common.zig:780). Callbacks that want to
//! keep data must dupe it. The existing `streamEventCb` already does.

const std = @import("std");
const hs = @import("http-sentinel");

const log = std.log.scoped(.fake_provider);

/// Captures one row per `sendMessageStreamingWithEvents` invocation. The
/// upcoming emission-gate test (errors_and_observability_v1.md §5) asserts
/// on call count and per-call state, not just final outcome — a retry must
/// observe that the provider was re-invoked with cleared TurnState, not
/// just that the final history looks right.
pub const CallRecord = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList(Call) = .empty,

    pub const Call = struct {
        /// Duped at record time; owned by this CallRecord.
        prompt: []const u8,
        /// Length of the history slice the provider saw on this call.
        /// Cheap proxy for "did the agent loop reset state correctly
        /// between attempts" — a duplicate history entry is detectable
        /// here without snapshotting the full slice.
        history_len: usize,
        max_tokens: u32,
    };

    pub fn init(gpa: std.mem.Allocator) CallRecord {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *CallRecord) void {
        for (self.calls.items) |c| self.gpa.free(c.prompt);
        self.calls.deinit(self.gpa);
    }

    pub fn count(self: *const CallRecord) usize {
        return self.calls.items.len;
    }
};

/// All the test-only configuration the agent loop needs to drive
/// FakeProvider end-to-end. Carried on RunArgs as an optional pointer
/// (`fake: ?*FakeConfig = null`), populated by the test, ignored by
/// production code paths.
pub const FakeConfig = struct {
    /// Path to a JSONL fixture, relative to cwd or absolute.
    fixture_path: []const u8,
    /// Optional — set to observe call count and per-call state. The
    /// test owns the lifetime; pass null when the bridge-level
    /// behavior is enough (most cases other than retry tests).
    recorder: ?*CallRecord = null,
};

pub const FakeProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fixture_path: []const u8,
    recorder: ?*CallRecord,

    pub const Config = struct {
        io: std.Io,
        /// Path to a JSONL fixture, relative to cwd or absolute.
        fixture_path: []const u8,
        /// Optional — see CallRecord.
        recorder: ?*CallRecord = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) FakeProvider {
        return .{
            .allocator = allocator,
            .io = config.io,
            .fixture_path = config.fixture_path,
            .recorder = config.recorder,
        };
    }

    pub fn deinit(self: *FakeProvider) void {
        _ = self; // nothing owned beyond fixture_path + recorder pointer (caller's lifetime)
    }

    /// Replay the fixture's events through `callback`, in order.
    /// Returns early without error if the callback returns `false`
    /// (matches the real providers' cancel semantics).
    ///
    /// `prompt`, `context`, and `config` are ignored — the fixture is
    /// the script. A future variant could record/validate them, but
    /// v1 substrate just dispatches the scripted events.
    pub fn sendMessageStreamingWithEvents(
        self: *FakeProvider,
        prompt: []const u8,
        context: []const hs.ai.common.AIMessage,
        config: hs.ai.common.RequestConfig,
        callback: hs.ai.common.StreamEventCallback,
        cb_context: ?*anyopaque,
    ) !void {
        if (self.recorder) |rec| {
            try rec.calls.append(rec.gpa, .{
                .prompt = try rec.gpa.dupe(u8, prompt),
                .history_len = context.len,
                .max_tokens = config.max_tokens,
            });
        }

        const data = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.fixture_path,
            self.allocator,
            .limited(1 * 1024 * 1024),
        );
        defer self.allocator.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            const parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                line,
                .{},
            ) catch |e| {
                log.err("line {d}: JSON parse failed: {s}", .{ line_no, @errorName(e) });
                return error.MalformedFixtureLine;
            };
            defer parsed.deinit();

            const ev = try parseStreamEvent(parsed.value, line_no);
            const keep_going = callback(ev, cb_context);
            if (!keep_going) return;
        }
    }
};

fn parseStreamEvent(v: std.json.Value, line_no: usize) !hs.ai.common.StreamEvent {
    if (v != .object) {
        log.err("line {d}: top-level must be a JSON object", .{line_no});
        return error.MalformedFixtureLine;
    }
    const kind = (try jsonString(v, "kind", line_no)) orelse {
        log.err("line {d}: missing required field 'kind'", .{line_no});
        return error.MalformedFixtureLine;
    };

    if (std.mem.eql(u8, kind, "text_delta")) {
        return .{ .text_delta = .{
            .index = (try jsonU32(v, "index", line_no)) orelse 0,
            .text = (try jsonString(v, "text", line_no)) orelse "",
        } };
    } else if (std.mem.eql(u8, kind, "tool_use_start")) {
        return .{ .tool_use_start = .{
            .index = (try jsonU32(v, "index", line_no)) orelse 0,
            .id = (try jsonString(v, "id", line_no)) orelse "",
            .name = (try jsonString(v, "name", line_no)) orelse "",
        } };
    } else if (std.mem.eql(u8, kind, "tool_input_delta")) {
        return .{ .tool_input_delta = .{
            .index = (try jsonU32(v, "index", line_no)) orelse 0,
            .partial_json = (try jsonString(v, "partial_json", line_no)) orelse "",
        } };
    } else if (std.mem.eql(u8, kind, "block_stop")) {
        return .{ .block_stop = .{
            .index = (try jsonU32(v, "index", line_no)) orelse 0,
        } };
    } else if (std.mem.eql(u8, kind, "message_stop")) {
        return .{ .message_stop = .{
            .stop_reason = try jsonString(v, "stop_reason", line_no),
            .input_tokens = (try jsonU32(v, "input_tokens", line_no)) orelse 0,
            .output_tokens = (try jsonU32(v, "output_tokens", line_no)) orelse 0,
        } };
    }
    log.err("line {d}: unknown event kind '{s}'", .{ line_no, kind });
    return error.MalformedFixtureLine;
}

/// Returns null when the key is absent or explicitly JSON null (so callers
/// can `orelse` a default). Hard-errors when the key is present but has
/// the wrong type — silent type coercion is the bug class this guards.
fn jsonString(v: std.json.Value, key: []const u8, line_no: usize) !?[]const u8 {
    if (v != .object) return error.MalformedFixtureLine;
    const child = v.object.get(key) orelse return null;
    return switch (child) {
        .string => |s| s,
        .null => null,
        else => {
            log.err(
                "line {d}: field '{s}' must be a string, got {s}",
                .{ line_no, key, @tagName(child) },
            );
            return error.MalformedFixtureLine;
        },
    };
}

/// Same semantics as jsonString — null on missing/JSON-null, hard-error on
/// wrong type. Also hard-errors on out-of-u32-range integers, including
/// negatives, rather than silently clamping or wrapping.
fn jsonU32(v: std.json.Value, key: []const u8, line_no: usize) !?u32 {
    if (v != .object) return error.MalformedFixtureLine;
    const child = v.object.get(key) orelse return null;
    return switch (child) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32))
            @intCast(i)
        else {
            log.err(
                "line {d}: field '{s}' integer {d} out of u32 range [0, {d}]",
                .{ line_no, key, i, std.math.maxInt(u32) },
            );
            return error.MalformedFixtureLine;
        },
        .null => null,
        else => {
            log.err(
                "line {d}: field '{s}' must be an integer, got {s}",
                .{ line_no, key, @tagName(child) },
            );
            return error.MalformedFixtureLine;
        },
    };
}

// ---- bridge-level tests ----
//
// These exercise FakeProvider directly against agent.streamEventCb, which
// is the load-bearing seam every downstream doc depends on. The end-to-end
// agent.run test lives in `tests/agent_loop_test.zig`; what's here is the
// narrow "the bridge composes correctly" check.

const agent = @import("agent.zig");

test "FakeProvider hello_world: streamEventCb populates TurnState" {
    const gpa = std.testing.allocator;

    var io_threaded = std.Io.Threaded.init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var out_alloc: std.Io.Writer.Allocating = .init(gpa);
    defer out_alloc.deinit();
    var err_alloc: std.Io.Writer.Allocating = .init(gpa);
    defer err_alloc.deinit();

    var state = agent.TurnState{
        .gpa = gpa,
        .out = &out_alloc.writer,
        .err = &err_alloc.writer,
    };
    defer state.deinit();

    var provider = FakeProvider.init(gpa, .{
        .io = io,
        .fixture_path = "tests/fixtures/hello_world.jsonl",
    });
    defer provider.deinit();

    var tool_defs: [0]hs.ai.common.ToolDefinition = .{};
    const req_cfg: hs.ai.common.RequestConfig = .{
        .model = "fake-model",
        .max_tokens = 64,
        .temperature = 0.0,
        .system_prompt = null,
        .tools = &tool_defs,
        .stream = true,
    };

    try provider.sendMessageStreamingWithEvents(
        "",
        &.{},
        req_cfg,
        agent.streamEventCb,
        &state,
    );

    try std.testing.expectEqualStrings("Hello! How can I help?", state.text.items);
    try std.testing.expectEqualStrings("end_turn", state.stop_reason.items);
    try std.testing.expectEqual(@as(u32, 8), state.input_tokens);
    try std.testing.expectEqual(@as(u32, 6), state.output_tokens);
    try std.testing.expect(state.done);
    try std.testing.expect(!state.saw_tool_use);
    try std.testing.expectEqual(@as(usize, 0), state.tools.items.len);

    try std.testing.expectEqualStrings("Hello! How can I help?", out_alloc.written());
}

test "FakeProvider: callback returning false aborts the stream" {
    const gpa = std.testing.allocator;

    var io_threaded = std.Io.Threaded.init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var provider = FakeProvider.init(gpa, .{
        .io = io,
        .fixture_path = "tests/fixtures/hello_world.jsonl",
    });
    defer provider.deinit();

    const Counter = struct {
        count: u32 = 0,
        fn cb(event: hs.ai.common.StreamEvent, ctx: ?*anyopaque) bool {
            _ = event;
            const self: *@This() = @alignCast(@ptrCast(ctx orelse return false));
            self.count += 1;
            return false;
        }
    };
    var counter = Counter{};

    var tool_defs: [0]hs.ai.common.ToolDefinition = .{};
    const req_cfg: hs.ai.common.RequestConfig = .{
        .model = "fake-model",
        .max_tokens = 64,
        .temperature = 0.0,
        .system_prompt = null,
        .tools = &tool_defs,
        .stream = true,
    };

    try provider.sendMessageStreamingWithEvents(
        "",
        &.{},
        req_cfg,
        Counter.cb,
        &counter,
    );

    try std.testing.expectEqual(@as(u32, 1), counter.count);
}
