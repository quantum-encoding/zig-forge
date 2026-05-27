//! JetStream JSON API Handler
//!
//! Routes $JS.API.* subjects to handlers. Parses JSON requests
//! and formats JSON responses for JetStream admin operations.
//! Handles both stream and consumer CRUD.

const std = @import("std");
const jetstream_mod = @import("jetstream.zig");
const stream_mod = @import("stream.zig");
const consumer_mod = @import("consumer.zig");

pub const JsApiHandler = struct {
    js: *jetstream_mod.JetStream,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, js: *jetstream_mod.JetStream) JsApiHandler {
        return .{ .js = js, .allocator = allocator };
    }

    /// Handle a JetStream API request. Returns response JSON (caller must free).
    /// Returns null if the subject is not a recognized JS API subject.
    pub fn handleRequest(self: *JsApiHandler, subject: []const u8, data: []const u8) ?[]u8 {
        self.js.api_total += 1;

        const response = self.dispatch(subject, data) catch |err| {
            self.js.api_errors += 1;
            return self.errorResponse(errCode(err), errDescription(err));
        };
        return response;
    }

    fn dispatch(self: *JsApiHandler, subject: []const u8, data: []const u8) ![]u8 {
        // --- Account Info ---
        if (std.mem.eql(u8, subject, "$JS.API.INFO")) {
            return self.handleAccountInfo();
        }

        // --- Stream endpoints ---

        if (startsWith(subject, "$JS.API.STREAM.CREATE.")) {
            const name = subject["$JS.API.STREAM.CREATE.".len..];
            return self.handleStreamCreate(name, data);
        }
        if (startsWith(subject, "$JS.API.STREAM.DELETE.")) {
            const name = subject["$JS.API.STREAM.DELETE.".len..];
            return self.handleStreamDelete(name);
        }
        if (startsWith(subject, "$JS.API.STREAM.INFO.")) {
            const name = subject["$JS.API.STREAM.INFO.".len..];
            return self.handleStreamInfo(name);
        }
        if (startsWith(subject, "$JS.API.STREAM.PURGE.")) {
            const name = subject["$JS.API.STREAM.PURGE.".len..];
            return self.handleStreamPurge(name, data);
        }
        if (startsWith(subject, "$JS.API.STREAM.MSG.GET.")) {
            const name = subject["$JS.API.STREAM.MSG.GET.".len..];
            return self.handleStreamMsgGet(name, data);
        }
        if (startsWith(subject, "$JS.API.STREAM.MSG.DELETE.")) {
            const name = subject["$JS.API.STREAM.MSG.DELETE.".len..];
            return self.handleStreamMsgDelete(name, data);
        }
        if (std.mem.eql(u8, subject, "$JS.API.STREAM.LIST")) {
            return self.handleStreamList();
        }
        if (std.mem.eql(u8, subject, "$JS.API.STREAM.NAMES")) {
            return self.handleStreamNames();
        }

        // --- Consumer endpoints ---

        if (startsWith(subject, "$JS.API.CONSUMER.CREATE.")) {
            const rest = subject["$JS.API.CONSUMER.CREATE.".len..];
            if (splitFirst(rest, '.')) |parts| {
                return self.handleConsumerCreate(parts.first, parts.rest, data);
            }
            return self.errorResponse(10_003, "bad request") orelse return error.EncodeFailed;
        }
        if (startsWith(subject, "$JS.API.CONSUMER.DELETE.")) {
            const rest = subject["$JS.API.CONSUMER.DELETE.".len..];
            if (splitFirst(rest, '.')) |parts| {
                return self.handleConsumerDelete(parts.first, parts.rest);
            }
            return self.errorResponse(10_003, "bad request") orelse return error.EncodeFailed;
        }
        if (startsWith(subject, "$JS.API.CONSUMER.INFO.")) {
            const rest = subject["$JS.API.CONSUMER.INFO.".len..];
            if (splitFirst(rest, '.')) |parts| {
                return self.handleConsumerInfo(parts.first, parts.rest);
            }
            return self.errorResponse(10_003, "bad request") orelse return error.EncodeFailed;
        }
        if (startsWith(subject, "$JS.API.CONSUMER.LIST.")) {
            const stream_name = subject["$JS.API.CONSUMER.LIST.".len..];
            return self.handleConsumerList(stream_name);
        }
        if (startsWith(subject, "$JS.API.CONSUMER.NAMES.")) {
            const stream_name = subject["$JS.API.CONSUMER.NAMES.".len..];
            return self.handleConsumerNames(stream_name);
        }

        self.js.api_errors += 1;
        return self.errorResponse(10_000, "unknown JetStream API subject") orelse return error.EncodeFailed;
    }

    // --- Stream handlers ---

    fn handleAccountInfo(self: *JsApiHandler) ![]u8 {
        const info = self.js.accountInfo();
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .type = "io.nats.jetstream.api.v1.account_info_response",
            .memory = info.memory,
            .storage = info.storage,
            .streams = info.streams,
            .consumers = info.consumers,
            .api = .{ .total = info.api_total, .errors = info.api_errors },
        }, .{});
    }

    fn handleStreamCreate(self: *JsApiHandler, name: []const u8, data: []const u8) ![]u8 {
        const parsed = parseStreamConfig(self.allocator, name, data) catch {
            return self.errorResponse(10_052, "invalid stream configuration") orelse return error.EncodeFailed;
        };
        const config = parsed.config;
        defer if (parsed.owned_subjects) |s| self.allocator.free(s);

        const stream = self.js.createStream(config) catch |err| {
            return switch (err) {
                error.StreamNameExists => self.errorResponse(10_058, "stream name already in use") orelse return error.EncodeFailed,
                error.InvalidStreamName => self.errorResponse(10_059, "stream name is invalid") orelse return error.EncodeFailed,
                else => self.errorResponse(10_052, "failed to create stream") orelse return error.EncodeFailed,
            };
        };

        return self.streamInfoResponse(stream);
    }

    fn handleStreamDelete(self: *JsApiHandler, name: []const u8) ![]u8 {
        if (!self.js.deleteStream(name)) {
            return self.errorResponse(10_059, "stream not found") orelse return error.EncodeFailed;
        }
        return std.json.Stringify.valueAlloc(self.allocator, .{ .success = true }, .{});
    }

    fn handleStreamInfo(self: *JsApiHandler, name: []const u8) ![]u8 {
        const stream = self.js.getStream(name) orelse {
            return self.errorResponse(10_059, "stream not found") orelse return error.EncodeFailed;
        };
        return self.streamInfoResponse(stream);
    }

    fn handleStreamPurge(self: *JsApiHandler, name: []const u8, data: []const u8) ![]u8 {
        const stream = self.js.getStream(name) orelse {
            return self.errorResponse(10_059, "stream not found") orelse return error.EncodeFailed;
        };

        var filter: ?[]const u8 = null;
        if (data.len > 0) {
            filter = jsonGetString(data, "filter");
        }

        const purged = stream.purge(filter);
        return std.json.Stringify.valueAlloc(self.allocator, .{ .success = true, .purged = purged }, .{});
    }

    fn handleStreamMsgGet(self: *JsApiHandler, name: []const u8, data: []const u8) ![]u8 {
        const stream = self.js.getStream(name) orelse {
            return self.errorResponse(10_059, "stream not found") orelse return error.EncodeFailed;
        };

        if (data.len == 0) {
            return self.errorResponse(10_003, "bad request") orelse return error.EncodeFailed;
        }

        if (jsonGetString(data, "last_by_subj")) |subj| {
            const msg = stream.getMessageBySubject(subj) orelse {
                return self.errorResponse(10_037, "no message found") orelse return error.EncodeFailed;
            };
            return self.storedMessageResponse(msg);
        }

        if (jsonGetInt(data, "seq")) |seq| {
            const msg = stream.getMessage(seq) orelse {
                return self.errorResponse(10_037, "no message found") orelse return error.EncodeFailed;
            };
            return self.storedMessageResponse(msg);
        }

        return self.errorResponse(10_003, "bad request") orelse return error.EncodeFailed;
    }

    fn handleStreamMsgDelete(self: *JsApiHandler, name: []const u8, data: []const u8) ![]u8 {
        const stream = self.js.getStream(name) orelse {
            return self.errorResponse(10_059, "stream not found") orelse return error.EncodeFailed;
        };

        const seq = jsonGetInt(data, "seq") orelse {
            return self.errorResponse(10_003, "bad request") orelse return error.EncodeFailed;
        };

        if (!stream.deleteMessage(seq)) {
            return self.errorResponse(10_037, "no message found") orelse return error.EncodeFailed;
        }

        return std.json.Stringify.valueAlloc(self.allocator, .{ .success = true }, .{});
    }

    fn handleStreamList(self: *JsApiHandler) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        var jw: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("total");
        try jw.write(self.js.streams.count());
        try jw.objectField("streams");
        try jw.beginArray();
        var it = self.js.streams.iterator();
        while (it.next()) |entry| {
            try writeStreamInfo(&jw, entry.value_ptr.*);
        }
        try jw.endArray();
        try jw.endObject();
        return self.allocator.dupe(u8, buf.written());
    }

    fn handleStreamNames(self: *JsApiHandler) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        var jw: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("total");
        try jw.write(self.js.streams.count());
        try jw.objectField("streams");
        try jw.beginArray();
        var it = self.js.streams.iterator();
        while (it.next()) |entry| {
            try jw.write(entry.key_ptr.*);
        }
        try jw.endArray();
        try jw.endObject();
        return self.allocator.dupe(u8, buf.written());
    }

    // --- Consumer handlers ---

    fn handleConsumerCreate(self: *JsApiHandler, stream_name: []const u8, consumer_name: []const u8, data: []const u8) ![]u8 {
        var config = parseConsumerConfig(data);
        config.name = consumer_name;

        const consumer = self.js.addConsumer(stream_name, config) catch |err| {
            return switch (err) {
                error.StreamNotFound => self.errorResponse(10_059, "stream not found") orelse return error.EncodeFailed,
                error.ConsumerNameExists => self.errorResponse(10_148, "consumer name already in use") orelse return error.EncodeFailed,
                error.InvalidConsumerName => self.errorResponse(10_153, "consumer name is invalid") orelse return error.EncodeFailed,
                else => self.errorResponse(10_000, "failed to create consumer") orelse return error.EncodeFailed,
            };
        };

        return self.consumerInfoResponse(consumer);
    }

    fn handleConsumerDelete(self: *JsApiHandler, stream_name: []const u8, consumer_name: []const u8) ![]u8 {
        if (!self.js.deleteConsumer(stream_name, consumer_name)) {
            return self.errorResponse(10_014, "consumer not found") orelse return error.EncodeFailed;
        }
        return std.json.Stringify.valueAlloc(self.allocator, .{ .success = true }, .{});
    }

    fn handleConsumerInfo(self: *JsApiHandler, stream_name: []const u8, consumer_name: []const u8) ![]u8 {
        const consumer = self.js.getConsumer(stream_name, consumer_name) orelse {
            return self.errorResponse(10_014, "consumer not found") orelse return error.EncodeFailed;
        };
        return self.consumerInfoResponse(consumer);
    }

    fn handleConsumerList(self: *JsApiHandler, stream_name: []const u8) ![]u8 {
        if (self.js.getStream(stream_name) == null) {
            return self.errorResponse(10_059, "stream not found") orelse return error.EncodeFailed;
        }

        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}.", .{stream_name}) catch
            return self.errorResponse(10_000, "internal error") orelse return error.EncodeFailed;

        var count: u32 = 0;
        var count_it = self.js.consumers.iterator();
        while (count_it.next()) |entry| {
            if (entry.key_ptr.*.len >= prefix.len and std.mem.eql(u8, entry.key_ptr.*[0..prefix.len], prefix)) {
                count += 1;
            }
        }

        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        var jw: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("total");
        try jw.write(count);
        try jw.objectField("consumers");
        try jw.beginArray();
        var it = self.js.consumers.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.*.len >= prefix.len and std.mem.eql(u8, entry.key_ptr.*[0..prefix.len], prefix)) {
                try writeConsumerInfo(&jw, entry.value_ptr.*);
            }
        }
        try jw.endArray();
        try jw.endObject();
        return self.allocator.dupe(u8, buf.written());
    }

    fn handleConsumerNames(self: *JsApiHandler, stream_name: []const u8) ![]u8 {
        if (self.js.getStream(stream_name) == null) {
            return self.errorResponse(10_059, "stream not found") orelse return error.EncodeFailed;
        }

        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}.", .{stream_name}) catch
            return self.errorResponse(10_000, "internal error") orelse return error.EncodeFailed;

        var count: u32 = 0;
        var count_it = self.js.consumers.iterator();
        while (count_it.next()) |entry| {
            if (entry.key_ptr.*.len >= prefix.len and std.mem.eql(u8, entry.key_ptr.*[0..prefix.len], prefix)) {
                count += 1;
            }
        }

        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        var jw: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("total");
        try jw.write(count);
        try jw.objectField("consumers");
        try jw.beginArray();
        var it = self.js.consumers.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.*.len >= prefix.len and std.mem.eql(u8, entry.key_ptr.*[0..prefix.len], prefix)) {
                try jw.write(entry.value_ptr.*.name);
            }
        }
        try jw.endArray();
        try jw.endObject();
        return self.allocator.dupe(u8, buf.written());
    }

    // --- Response formatters ---

    fn streamInfoResponse(self: *JsApiHandler, stream: *stream_mod.Stream) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        var jw: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        try writeStreamInfo(&jw, stream);
        return self.allocator.dupe(u8, buf.written());
    }

    fn consumerInfoResponse(self: *JsApiHandler, consumer: *consumer_mod.Consumer) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        var jw: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        try writeConsumerInfo(&jw, consumer);
        return self.allocator.dupe(u8, buf.written());
    }

    fn storedMessageResponse(self: *JsApiHandler, msg: anytype) ![]u8 {
        var ts_buf: [24]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{msg.timestamp_ns});
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .message = .{
                .subject = msg.subject,
                .seq = msg.sequence,
                .time = ts_str,
            },
        }, .{});
    }

    fn errorResponse(self: *JsApiHandler, code: u32, description: []const u8) ?[]u8 {
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .@"error" = .{ .code = code, .description = description },
        }, .{}) catch null;
    }

    fn errCode(err: anyerror) u32 {
        return switch (err) {
            error.StreamNameExists => 10_058,
            error.InvalidStreamName => 10_059,
            error.ConsumerNameExists => 10_148,
            error.InvalidConsumerName => 10_153,
            error.EncodeFailed => 10_000,
            else => 10_000,
        };
    }

    fn errDescription(err: anyerror) []const u8 {
        return switch (err) {
            error.StreamNameExists => "stream name already in use",
            error.InvalidStreamName => "stream name is invalid",
            error.ConsumerNameExists => "consumer name already in use",
            error.InvalidConsumerName => "consumer name is invalid",
            error.EncodeFailed => "encoding failed",
            else => "internal error",
        };
    }
};

// --- Stream/consumer JSON writers (shared by single + list response handlers) ---

fn writeStreamInfo(jw: *std.json.Stringify, stream: *stream_mod.Stream) !void {
    const si = stream.info();
    try jw.beginObject();
    try jw.objectField("config");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(si.config.name);
    try jw.objectField("subjects");
    try jw.beginArray();
    for (si.config.subjects) |s| try jw.write(s);
    try jw.endArray();
    try jw.objectField("retention");
    try jw.write(retentionStr(si.config.retention));
    try jw.objectField("max_msgs");
    try jw.write(si.config.max_msgs);
    try jw.objectField("max_bytes");
    try jw.write(si.config.max_bytes);
    try jw.objectField("max_age");
    try jw.write(si.config.max_age_ns);
    try jw.objectField("storage");
    try jw.write(storageStr(si.config.storage));
    try jw.objectField("discard");
    try jw.write(discardStr(si.config.discard));
    try jw.objectField("duplicate_window");
    try jw.write(si.config.duplicate_window_ns);
    try jw.objectField("no_ack");
    try jw.write(si.config.no_ack);
    try jw.endObject();

    try jw.objectField("state");
    try jw.beginObject();
    try jw.objectField("messages");
    try jw.write(si.state.messages);
    try jw.objectField("bytes");
    try jw.write(si.state.bytes);
    try jw.objectField("first_seq");
    try jw.write(si.state.first_seq);
    try jw.objectField("last_seq");
    try jw.write(si.state.last_seq);
    try jw.objectField("consumer_count");
    try jw.write(si.state.consumer_count);
    try jw.endObject();

    // created emitted as a string ("{d}") to match prior wire shape.
    var created_buf: [24]u8 = undefined;
    const created_str = try std.fmt.bufPrint(&created_buf, "{d}", .{si.created_ns});
    try jw.objectField("created");
    try jw.write(created_str);
    try jw.endObject();
}

fn writeConsumerInfo(jw: *std.json.Stringify, consumer: *consumer_mod.Consumer) !void {
    const ci = consumer.info();
    try jw.beginObject();
    try jw.objectField("stream_name");
    try jw.write(ci.stream_name);
    try jw.objectField("name");
    try jw.write(ci.name);

    try jw.objectField("config");
    try jw.beginObject();
    try jw.objectField("deliver_policy");
    try jw.write(deliverPolicyStr(ci.config.deliver_policy));
    try jw.objectField("ack_policy");
    try jw.write(ackPolicyStr(ci.config.ack_policy));
    try jw.objectField("ack_wait");
    try jw.write(ci.config.ack_wait_ns);
    try jw.objectField("max_deliver");
    try jw.write(ci.config.max_deliver);
    try jw.objectField("max_ack_pending");
    try jw.write(ci.config.max_ack_pending);
    try jw.objectField("filter_subject");
    try jw.write(if (ci.config.filter_subject) |fs| fs else "");
    if (ci.config.deliver_subject) |ds| {
        try jw.objectField("deliver_subject");
        try jw.write(ds);
    }
    if (ci.config.deliver_group) |dg| {
        try jw.objectField("deliver_group");
        try jw.write(dg);
    }
    try jw.endObject();

    try jw.objectField("state");
    try jw.beginObject();
    try jw.objectField("delivered");
    try jw.beginObject();
    try jw.objectField("stream_seq");
    try jw.write(ci.state.delivered.stream_seq);
    try jw.objectField("consumer_seq");
    try jw.write(ci.state.delivered.consumer_seq);
    try jw.endObject();
    try jw.objectField("ack_floor");
    try jw.beginObject();
    try jw.objectField("stream_seq");
    try jw.write(ci.state.ack_floor.stream_seq);
    try jw.objectField("consumer_seq");
    try jw.write(ci.state.ack_floor.consumer_seq);
    try jw.endObject();
    try jw.objectField("num_ack_pending");
    try jw.write(ci.state.num_ack_pending);
    try jw.objectField("num_redelivered");
    try jw.write(ci.state.num_redelivered);
    try jw.objectField("num_pending");
    try jw.write(ci.state.num_pending);
    try jw.endObject();

    var created_buf: [24]u8 = undefined;
    const created_str = try std.fmt.bufPrint(&created_buf, "{d}", .{ci.created_ns});
    try jw.objectField("created");
    try jw.write(created_str);
    try jw.endObject();
}

// --- JSON helpers (pub for use by server.zig) ---

pub fn jsonGetString(data: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos + key.len + 4 < data.len) : (pos += 1) {
        if (data[pos] != '"') continue;
        const key_start = pos + 1;
        if (key_start + key.len >= data.len) break;
        if (!std.mem.eql(u8, data[key_start..][0..key.len], key)) continue;
        if (data[key_start + key.len] != '"') continue;
        var scan = key_start + key.len + 1;
        while (scan < data.len and (data[scan] == ' ' or data[scan] == ':')) : (scan += 1) {}
        if (scan >= data.len or data[scan] != '"') continue;
        const val_start = scan + 1;
        var val_end = val_start;
        while (val_end < data.len and data[val_end] != '"') : (val_end += 1) {}
        if (val_end >= data.len) continue;
        return data[val_start..val_end];
    }
    return null;
}

pub fn jsonGetInt(data: []const u8, key: []const u8) ?u64 {
    var pos: usize = 0;
    while (pos + key.len + 4 < data.len) : (pos += 1) {
        if (data[pos] != '"') continue;
        const key_start = pos + 1;
        if (key_start + key.len >= data.len) break;
        if (!std.mem.eql(u8, data[key_start..][0..key.len], key)) continue;
        if (data[key_start + key.len] != '"') continue;
        var scan = key_start + key.len + 1;
        while (scan < data.len and (data[scan] == ' ' or data[scan] == ':')) : (scan += 1) {}
        if (scan >= data.len) continue;
        var end = scan;
        while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
        if (end == scan) continue;
        return std.fmt.parseInt(u64, data[scan..end], 10) catch continue;
    }
    return null;
}

fn jsonGetStringArray(allocator: std.mem.Allocator, data: []const u8, key: []const u8) ?[][]const u8 {
    var pos: usize = 0;
    while (pos + key.len + 4 < data.len) : (pos += 1) {
        if (data[pos] != '"') continue;
        const key_start = pos + 1;
        if (key_start + key.len >= data.len) break;
        if (!std.mem.eql(u8, data[key_start..][0..key.len], key)) continue;
        if (data[key_start + key.len] != '"') continue;
        var scan = key_start + key.len + 1;
        while (scan < data.len and (data[scan] == ' ' or data[scan] == ':')) : (scan += 1) {}
        if (scan >= data.len or data[scan] != '[') continue;
        scan += 1;

        var items: std.ArrayListUnmanaged([]const u8) = .empty;
        while (scan < data.len and data[scan] != ']') {
            while (scan < data.len and (data[scan] == ' ' or data[scan] == ',')) : (scan += 1) {}
            if (scan >= data.len or data[scan] == ']') break;
            if (data[scan] != '"') break;
            const str_start = scan + 1;
            var str_end = str_start;
            while (str_end < data.len and data[str_end] != '"') : (str_end += 1) {}
            if (str_end >= data.len) break;
            items.append(allocator, data[str_start..str_end]) catch return null;
            scan = str_end + 1;
        }
        return items.toOwnedSlice(allocator) catch null;
    }
    return null;
}

const ParsedConfig = struct {
    config: stream_mod.StreamConfig,
    owned_subjects: ?[][]const u8,
};

fn parseStreamConfig(allocator: std.mem.Allocator, name: []const u8, data: []const u8) !ParsedConfig {
    var config = stream_mod.StreamConfig{
        .name = name,
    };
    var owned_subjects: ?[][]const u8 = null;

    if (data.len > 0) {
        if (jsonGetStringArray(allocator, data, "subjects")) |subjects| {
            config.subjects = subjects;
            owned_subjects = subjects;
        }

        if (jsonGetInt(data, "max_msgs")) |v| config.max_msgs = @intCast(v);
        if (jsonGetInt(data, "max_bytes")) |v| config.max_bytes = @intCast(v);
        if (jsonGetInt(data, "max_age")) |v| config.max_age_ns = @intCast(v);
        if (jsonGetInt(data, "max_msg_size")) |v| config.max_msg_size = @intCast(v);
        if (jsonGetInt(data, "duplicate_window")) |v| config.duplicate_window_ns = @intCast(v);

        if (jsonGetString(data, "retention")) |r| {
            if (std.mem.eql(u8, r, "interest")) config.retention = .interest;
            if (std.mem.eql(u8, r, "workqueue")) config.retention = .work_queue;
        }
        if (jsonGetString(data, "storage")) |s| {
            if (std.mem.eql(u8, s, "file")) config.storage = .file;
        }
        if (jsonGetString(data, "discard")) |d| {
            if (std.mem.eql(u8, d, "new")) config.discard = .new;
        }
    }

    return .{ .config = config, .owned_subjects = owned_subjects };
}

fn parseConsumerConfig(data: []const u8) consumer_mod.ConsumerConfig {
    var config = consumer_mod.ConsumerConfig{};
    if (data.len == 0) return config;

    if (jsonGetString(data, "filter_subject")) |fs| config.filter_subject = fs;
    if (jsonGetString(data, "durable_name")) |dn| config.durable_name = dn;
    if (jsonGetString(data, "description")) |d| config.description = d;
    if (jsonGetString(data, "deliver_subject")) |ds| config.deliver_subject = ds;
    if (jsonGetString(data, "deliver_group")) |dg| config.deliver_group = dg;

    if (jsonGetInt(data, "ack_wait")) |v| config.ack_wait_ns = @intCast(v);
    if (jsonGetInt(data, "max_deliver")) |v| config.max_deliver = @intCast(v);
    if (jsonGetInt(data, "max_ack_pending")) |v| config.max_ack_pending = @intCast(v);
    if (jsonGetInt(data, "max_waiting")) |v| config.max_waiting = @intCast(v);
    if (jsonGetInt(data, "opt_start_seq")) |v| config.opt_start_seq = v;

    if (jsonGetString(data, "deliver_policy")) |dp| {
        if (std.mem.eql(u8, dp, "last")) config.deliver_policy = .last;
        if (std.mem.eql(u8, dp, "new")) config.deliver_policy = .new;
        if (std.mem.eql(u8, dp, "by_start_sequence")) config.deliver_policy = .by_start_sequence;
    }
    if (jsonGetString(data, "ack_policy")) |ap| {
        if (std.mem.eql(u8, ap, "none")) config.ack_policy = .none;
        if (std.mem.eql(u8, ap, "all")) config.ack_policy = .all;
    }

    return config;
}

// --- Formatting helpers ---

fn retentionStr(r: stream_mod.RetentionPolicy) []const u8 {
    return switch (r) {
        .limits => "limits",
        .interest => "interest",
        .work_queue => "workqueue",
    };
}

fn storageStr(s: stream_mod.StorageType) []const u8 {
    return switch (s) {
        .memory => "memory",
        .file => "file",
    };
}

fn discardStr(d: stream_mod.DiscardPolicy) []const u8 {
    return switch (d) {
        .old => "old",
        .new => "new",
    };
}

fn deliverPolicyStr(dp: consumer_mod.DeliverPolicy) []const u8 {
    return switch (dp) {
        .all => "all",
        .last => "last",
        .new => "new",
        .by_start_sequence => "by_start_sequence",
        .by_start_time => "by_start_time",
        .last_per_subject => "last_per_subject",
    };
}

fn ackPolicyStr(ap: consumer_mod.AckPolicy) []const u8 {
    return switch (ap) {
        .none => "none",
        .all => "all",
        .explicit => "explicit",
    };
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

const SplitResult = struct { first: []const u8, rest: []const u8 };

fn splitFirst(s: []const u8, delim: u8) ?SplitResult {
    for (s, 0..) |c, i| {
        if (c == delim) return .{ .first = s[0..i], .rest = s[i + 1 ..] };
    }
    return null;
}

fn appendStr(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(allocator, s);
}

fn appendInt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: anytype) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
    try buf.appendSlice(allocator, s);
}

// --- Tests ---

test "js_api account info" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest("$JS.API.INFO", "").?;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"streams\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"memory\":0") != null);
}

test "js_api stream create" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest(
        "$JS.API.STREAM.CREATE.ORDERS",
        "{\"subjects\":[\"orders.>\"]}",
    ).?;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"ORDERS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"messages\":0") != null);
}

test "js_api stream create duplicate" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    var handler = JsApiHandler.init(allocator, js);
    const resp1 = handler.handleRequest("$JS.API.STREAM.CREATE.TEST", "{}").?;
    defer allocator.free(resp1);

    const resp2 = handler.handleRequest("$JS.API.STREAM.CREATE.TEST", "{}").?;
    defer allocator.free(resp2);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "\"code\":10058") != null);
}

test "js_api stream info" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    var handler = JsApiHandler.init(allocator, js);
    const cr = handler.handleRequest("$JS.API.STREAM.CREATE.TEST", "{}").?;
    defer allocator.free(cr);

    const resp = handler.handleRequest("$JS.API.STREAM.INFO.TEST", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"TEST\"") != null);
}

test "js_api stream info not found" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest("$JS.API.STREAM.INFO.MISSING", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"code\":10059") != null);
}

test "js_api stream delete" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    var handler = JsApiHandler.init(allocator, js);
    const cr = handler.handleRequest("$JS.API.STREAM.CREATE.TEST", "{}").?;
    defer allocator.free(cr);

    const resp = handler.handleRequest("$JS.API.STREAM.DELETE.TEST", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"success\":true") != null);

    const resp2 = handler.handleRequest("$JS.API.STREAM.INFO.TEST", "").?;
    defer allocator.free(resp2);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "\"code\":10059") != null);
}

test "js_api stream purge" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"foo"};
    const stream = try js.createStream(.{ .name = "TEST", .subjects = &subjects });
    _ = try stream.storeMessage("foo", null, "data1", null);
    _ = try stream.storeMessage("foo", null, "data2", null);

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest("$JS.API.STREAM.PURGE.TEST", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"purged\":2") != null);
}

test "js_api stream names" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "A" });
    _ = try js.createStream(.{ .name = "B" });

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest("$JS.API.STREAM.NAMES", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"total\":2") != null);
}

test "js_api stream msg get by seq" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"foo"};
    const stream = try js.createStream(.{ .name = "TEST", .subjects = &subjects });
    _ = try stream.storeMessage("foo", null, "hello", null);

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest("$JS.API.STREAM.MSG.GET.TEST", "{\"seq\":1}").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"subject\":\"foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"seq\":1") != null);
}

test "js_api stream msg delete" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    const subjects = [_][]const u8{"foo"};
    const stream = try js.createStream(.{ .name = "TEST", .subjects = &subjects });
    _ = try stream.storeMessage("foo", null, "hello", null);

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest("$JS.API.STREAM.MSG.DELETE.TEST", "{\"seq\":1}").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"success\":true") != null);
}

test "js_api unknown subject" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest("$JS.API.UNKNOWN", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"code\":10000") != null);
}

test "js_api consumer create" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "ORDERS" });

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest(
        "$JS.API.CONSUMER.CREATE.ORDERS.processor",
        "{\"ack_policy\":\"explicit\"}",
    ).?;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"processor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"stream_name\":\"ORDERS\"") != null);
}

test "js_api consumer create duplicate" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });

    var handler = JsApiHandler.init(allocator, js);
    const resp1 = handler.handleRequest("$JS.API.CONSUMER.CREATE.TEST.C1", "{}").?;
    defer allocator.free(resp1);

    const resp2 = handler.handleRequest("$JS.API.CONSUMER.CREATE.TEST.C1", "{}").?;
    defer allocator.free(resp2);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "\"code\":10148") != null);
}

test "js_api consumer info" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });

    var handler = JsApiHandler.init(allocator, js);
    const cr = handler.handleRequest("$JS.API.CONSUMER.CREATE.TEST.C1", "{}").?;
    defer allocator.free(cr);

    const resp = handler.handleRequest("$JS.API.CONSUMER.INFO.TEST.C1", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"C1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ack_policy\":\"explicit\"") != null);
}

test "js_api consumer delete" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });

    var handler = JsApiHandler.init(allocator, js);
    const cr = handler.handleRequest("$JS.API.CONSUMER.CREATE.TEST.C1", "{}").?;
    defer allocator.free(cr);

    const resp = handler.handleRequest("$JS.API.CONSUMER.DELETE.TEST.C1", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"success\":true") != null);

    const resp2 = handler.handleRequest("$JS.API.CONSUMER.INFO.TEST.C1", "").?;
    defer allocator.free(resp2);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "\"code\":10014") != null);
}

test "js_api consumer names" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });
    _ = try js.addConsumer("TEST", .{ .name = "A" });
    _ = try js.addConsumer("TEST", .{ .name = "B" });

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest("$JS.API.CONSUMER.NAMES.TEST", "").?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"total\":2") != null);
}

test "js_api consumer create with deliver_subject" {
    const allocator = std.testing.allocator;
    var js = try jetstream_mod.JetStream.init(allocator, .{});
    defer js.deinit();

    _ = try js.createStream(.{ .name = "TEST" });

    var handler = JsApiHandler.init(allocator, js);
    const resp = handler.handleRequest(
        "$JS.API.CONSUMER.CREATE.TEST.push1",
        "{\"deliver_subject\":\"my.delivery\",\"deliver_group\":\"workers\"}",
    ).?;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"push1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"deliver_subject\":\"my.delivery\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"deliver_group\":\"workers\"") != null);
}
