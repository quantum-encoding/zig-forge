//! FIX 5.0 SP2 Protocol Implementation for Coinbase Exchange
//!
//! This implements the FIX 5.0 SP2 protocol with Coinbase-specific extensions.
//! Key differences from FIX 4.4:
//! - Session layer uses FIXT.1.1
//! - Application layer specified via DefaultApplVerID (1137) = 9
//! - Coinbase requires HMAC-SHA256 signed Logon messages
//!
//! Reference: https://docs.cdp.coinbase.com/exchange/docs/fix-order-entry

const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const order_book = @import("order_book_v2.zig");

// Zig 0.16 compatible timestamp function
fn getTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn getNanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

// =============================================================================
// FIX 5.0 SP2 Constants
// =============================================================================

/// FIX session layer version (FIXT.1.1 for FIX 5.0+)
pub const FIX_SESSION_VERSION = "FIXT.1.1";

/// FIX application version ID (9 = FIX50SP2)
pub const FIX_APP_VERSION_ID = "9";

/// Coinbase target comp ID
pub const COINBASE_TARGET = "Coinbase";

/// SOH delimiter
pub const SOH: u8 = 0x01;

// =============================================================================
// Message Types
// =============================================================================

/// FIX 5.0 message types
pub const MsgType = enum {
    // Administrative messages
    Heartbeat,          // '0'
    TestRequest,        // '1'
    ResendRequest,      // '2'
    Reject,             // '3'
    SequenceReset,      // '4'
    Logout,             // '5'
    Logon,              // 'A'

    // Application messages
    ExecutionReport,    // '8'
    OrderCancelReject,  // '9'
    NewOrderSingle,     // 'D'
    OrderCancelRequest, // 'F'
    OrderCancelReplaceRequest, // 'G'
    OrderStatusRequest, // 'H'
    BusinessMessageReject, // 'j'

    // Coinbase batch messages
    OrderCancelBatch,       // 'U4'
    OrderCancelBatchReject, // 'U5'
    NewOrderBatch,          // 'U6'
    NewOrderBatchReject,    // 'U7'

    pub fn toString(self: MsgType) []const u8 {
        return switch (self) {
            .Heartbeat => "0",
            .TestRequest => "1",
            .ResendRequest => "2",
            .Reject => "3",
            .SequenceReset => "4",
            .Logout => "5",
            .Logon => "A",
            .ExecutionReport => "8",
            .OrderCancelReject => "9",
            .NewOrderSingle => "D",
            .OrderCancelRequest => "F",
            .OrderCancelReplaceRequest => "G",
            .OrderStatusRequest => "H",
            .BusinessMessageReject => "j",
            .OrderCancelBatch => "U4",
            .OrderCancelBatchReject => "U5",
            .NewOrderBatch => "U6",
            .NewOrderBatchReject => "U7",
        };
    }

    pub fn fromString(s: []const u8) ?MsgType {
        if (std.mem.eql(u8, s, "0")) return .Heartbeat;
        if (std.mem.eql(u8, s, "1")) return .TestRequest;
        if (std.mem.eql(u8, s, "2")) return .ResendRequest;
        if (std.mem.eql(u8, s, "3")) return .Reject;
        if (std.mem.eql(u8, s, "4")) return .SequenceReset;
        if (std.mem.eql(u8, s, "5")) return .Logout;
        if (std.mem.eql(u8, s, "A")) return .Logon;
        if (std.mem.eql(u8, s, "8")) return .ExecutionReport;
        if (std.mem.eql(u8, s, "9")) return .OrderCancelReject;
        if (std.mem.eql(u8, s, "D")) return .NewOrderSingle;
        if (std.mem.eql(u8, s, "F")) return .OrderCancelRequest;
        if (std.mem.eql(u8, s, "G")) return .OrderCancelReplaceRequest;
        if (std.mem.eql(u8, s, "H")) return .OrderStatusRequest;
        if (std.mem.eql(u8, s, "j")) return .BusinessMessageReject;
        if (std.mem.eql(u8, s, "U4")) return .OrderCancelBatch;
        if (std.mem.eql(u8, s, "U5")) return .OrderCancelBatchReject;
        if (std.mem.eql(u8, s, "U6")) return .NewOrderBatch;
        if (std.mem.eql(u8, s, "U7")) return .NewOrderBatchReject;
        return null;
    }
};

// =============================================================================
// Field Tags
// =============================================================================

/// FIX field tags
pub const Tag = struct {
    // Standard header fields
    pub const BeginString: u16 = 8;
    pub const BodyLength: u16 = 9;
    pub const CheckSum: u16 = 10;
    pub const MsgType: u16 = 35;
    pub const SenderCompID: u16 = 49;
    pub const TargetCompID: u16 = 56;
    pub const MsgSeqNum: u16 = 34;
    pub const SendingTime: u16 = 52;
    pub const PossDupFlag: u16 = 43;
    pub const SenderSubID: u16 = 50;
    pub const RptSeq: u16 = 83;

    // Logon fields
    pub const EncryptMethod: u16 = 98;
    pub const HeartBtInt: u16 = 108;
    pub const ResetSeqNumFlag: u16 = 141;
    pub const Username: u16 = 553;
    pub const Password: u16 = 554;
    pub const RawDataLength: u16 = 95;
    pub const RawData: u16 = 96;
    pub const DefaultApplVerID: u16 = 1137;

    // Coinbase-specific Logon fields
    pub const DefaultSelfTradePreventionStrategy: u16 = 8001;
    pub const CancelOrdersOnDisconnect: u16 = 8013;
    pub const DropCopyFlag: u16 = 9406;

    // Order fields
    pub const ClOrdID: u16 = 11;
    pub const OrderID: u16 = 37;
    pub const OrigClOrdID: u16 = 41;
    pub const Symbol: u16 = 55;
    pub const Side: u16 = 54;
    pub const OrderQty: u16 = 38;
    pub const CashOrderQty: u16 = 152;
    pub const OrdType: u16 = 40;
    pub const Price: u16 = 44;
    pub const StopPx: u16 = 99;
    pub const TimeInForce: u16 = 59;
    pub const ExpireTime: u16 = 126;
    pub const TransactTime: u16 = 60;
    pub const ExecInst: u16 = 18;
    pub const HandlInst: u16 = 21;
    pub const TriggerPriceDirection: u16 = 1109;
    pub const SelfTradeType: u16 = 7928;

    // Execution report fields
    pub const ExecID: u16 = 17;
    pub const ExecType: u16 = 150;
    pub const OrdStatus: u16 = 39;
    pub const OrdRejReason: u16 = 103;
    pub const LeavesQty: u16 = 151;
    pub const CumQty: u16 = 14;
    pub const AvgPx: u16 = 6;
    pub const LastQty: u16 = 32;
    pub const LastPx: u16 = 31;
    pub const TradeID: u16 = 1003;
    pub const AggressorIndicator: u16 = 1057;
    pub const Text: u16 = 58;

    // Fee fields
    pub const NoMiscFees: u16 = 136;
    pub const MiscFeeAmt: u16 = 137;
    pub const MiscFeeCurr: u16 = 138;
    pub const MiscFeeType: u16 = 139;
    pub const MiscFeeBasis: u16 = 891;

    // Batch order fields
    pub const BatchID: u16 = 8014;
    pub const NoOrders: u16 = 73;

    // Resend request fields
    pub const BeginSeqNo: u16 = 7;
    pub const EndSeqNo: u16 = 16;
    pub const NewSeqNo: u16 = 36;
    pub const GapFillFlag: u16 = 123;

    // Reject fields
    pub const RefSeqNum: u16 = 45;
    pub const RefTagID: u16 = 371;
    pub const RefMsgType: u16 = 372;
    pub const SessionRejectReason: u16 = 373;
    pub const BusinessRejectRefID: u16 = 379;
    pub const BusinessRejectReason: u16 = 380;

    // Cancel reject fields
    pub const CxlRejReason: u16 = 102;
    pub const CxlRejResponseTo: u16 = 434;

    // Test request
    pub const TestReqID: u16 = 112;
};

// =============================================================================
// Enums for field values
// =============================================================================

/// Order side
pub const Side = enum(u8) {
    Buy = '1',
    Sell = '2',

    pub fn toChar(self: Side) u8 {
        return @intFromEnum(self);
    }
};

/// Order type
pub const OrdType = enum(u8) {
    Market = '1',
    Limit = '2',
    StopLimit = '4',
    TakeProfitStopLoss = 'O',

    pub fn toChar(self: OrdType) u8 {
        return @intFromEnum(self);
    }
};

/// Time in force
pub const TimeInForce = enum(u8) {
    GoodTillCancel = '1',
    ImmediateOrCancel = '3',
    FillOrKill = '4',
    GoodTillDate = '6',

    pub fn toChar(self: TimeInForce) u8 {
        return @intFromEnum(self);
    }
};

/// Execution type
pub const ExecType = enum(u8) {
    New = '0',
    Canceled = '4',
    Replaced = '5',
    Rejected = '8',
    Expired = 'C',
    Restated = 'D',
    Trade = 'F',
    OrderStatus = 'I',

    pub fn fromChar(c: u8) ?ExecType {
        return switch (c) {
            '0' => .New,
            '4' => .Canceled,
            '5' => .Replaced,
            '8' => .Rejected,
            'C' => .Expired,
            'D' => .Restated,
            'F' => .Trade,
            'I' => .OrderStatus,
            else => null,
        };
    }
};

/// Order status
pub const OrdStatus = enum(u8) {
    New = '0',
    PartiallyFilled = '1',
    Filled = '2',
    Canceled = '4',
    Replaced = '5',
    Rejected = '8',
    Expired = 'C',

    pub fn fromChar(c: u8) ?OrdStatus {
        return switch (c) {
            '0' => .New,
            '1' => .PartiallyFilled,
            '2' => .Filled,
            '4' => .Canceled,
            '5' => .Replaced,
            '8' => .Rejected,
            'C' => .Expired,
            else => null,
        };
    }
};

/// Execution instruction (Post Only)
pub const ExecInst = enum(u8) {
    AddLiquidityOnly = 'A', // Post Only

    pub fn toChar(self: ExecInst) u8 {
        return @intFromEnum(self);
    }
};

/// Self trade prevention
pub const SelfTradeType = enum(u8) {
    DecrementAndCancel = 'D',
    CancelOldest = 'O',
    CancelNewest = 'N',
    CancelBoth = 'B',

    pub fn toChar(self: SelfTradeType) u8 {
        return @intFromEnum(self);
    }
};

// =============================================================================
// Message Builder
// =============================================================================

/// FIX 5.0 message builder with proper field ordering
pub const MessageBuilder = struct {
    const Self = @This();
    const Buffer = std.ArrayListAligned(u8, null);

    buffer: Buffer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .buffer = Buffer{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Add a field with tag and string value
    pub fn addField(self: *Self, tag: u16, value: []const u8) !void {
        var tag_buf: [16]u8 = undefined;
        const tag_str = std.fmt.bufPrint(&tag_buf, "{d}=", .{tag}) catch unreachable;
        try self.buffer.appendSlice(self.allocator, tag_str);
        try self.buffer.appendSlice(self.allocator, value);
        try self.buffer.append(self.allocator, SOH);
    }

    /// Add a field with tag and integer value
    pub fn addIntField(self: *Self, tag: u16, value: anytype) !void {
        var buf: [32]u8 = undefined;
        const val_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try self.addField(tag, val_str);
    }

    /// Add a field with tag and char value
    pub fn addCharField(self: *Self, tag: u16, value: u8) !void {
        const char_slice: [1]u8 = .{value};
        try self.addField(tag, &char_slice);
    }

    /// Add a field with tag and decimal value (formatted)
    pub fn addDecimalField(self: *Self, tag: u16, value: f64, precision: u8) !void {
        var buf: [32]u8 = undefined;
        const val_str = switch (precision) {
            2 => std.fmt.bufPrint(&buf, "{d:.2}", .{value}) catch unreachable,
            4 => std.fmt.bufPrint(&buf, "{d:.4}", .{value}) catch unreachable,
            6 => std.fmt.bufPrint(&buf, "{d:.6}", .{value}) catch unreachable,
            8 => std.fmt.bufPrint(&buf, "{d:.8}", .{value}) catch unreachable,
            else => std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable,
        };
        try self.addField(tag, val_str);
    }

    /// Get current buffer for body length calculation
    pub fn getBuffer(self: Self) []const u8 {
        return self.buffer.items;
    }

    /// Reset the buffer for reuse
    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
    }

    /// Build final message with header and trailer
    pub fn finalize(
        self: *Self,
        msg_type: MsgType,
        sender_comp_id: []const u8,
        target_comp_id: []const u8,
        msg_seq_num: u32,
        sending_time: []const u8,
    ) ![]u8 {
        // Build body first (everything after BodyLength, before CheckSum)
        var body = Buffer{ .items = &.{}, .capacity = 0 };
        defer body.deinit(self.allocator);

        // MsgType (35) - must be first in body
        try addFieldTo(&body, self.allocator, Tag.MsgType, msg_type.toString());

        // Standard header fields
        try addFieldTo(&body, self.allocator, Tag.SenderCompID, sender_comp_id);
        try addFieldTo(&body, self.allocator, Tag.TargetCompID, target_comp_id);

        var seq_buf: [16]u8 = undefined;
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d}", .{msg_seq_num}) catch unreachable;
        try addFieldTo(&body, self.allocator, Tag.MsgSeqNum, seq_str);

        try addFieldTo(&body, self.allocator, Tag.SendingTime, sending_time);

        // Append message-specific fields
        try body.appendSlice(self.allocator, self.buffer.items);

        // Calculate body length
        const body_len = body.items.len;

        // Build complete message
        var msg = Buffer{ .items = &.{}, .capacity = 0 };
        errdefer msg.deinit(self.allocator);

        // BeginString (8)
        try addFieldTo(&msg, self.allocator, Tag.BeginString, FIX_SESSION_VERSION);

        // BodyLength (9)
        var len_buf: [16]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body_len}) catch unreachable;
        try addFieldTo(&msg, self.allocator, Tag.BodyLength, len_str);

        // Append body
        try msg.appendSlice(self.allocator, body.items);

        // Calculate checksum
        var checksum: u32 = 0;
        for (msg.items) |byte| {
            checksum +%= byte;
        }
        checksum = checksum % 256;

        // CheckSum (10) - always 3 digits with leading zeros
        var cs_buf: [8]u8 = undefined;
        const cs_str = std.fmt.bufPrint(&cs_buf, "{d:0>3}", .{checksum}) catch unreachable;
        try addFieldTo(&msg, self.allocator, Tag.CheckSum, cs_str);

        return try msg.toOwnedSlice(self.allocator);
    }

    fn addFieldTo(list: *Buffer, allocator: std.mem.Allocator, tag: u16, value: []const u8) !void {
        var tag_buf: [16]u8 = undefined;
        const tag_str = std.fmt.bufPrint(&tag_buf, "{d}=", .{tag}) catch unreachable;
        try list.appendSlice(allocator, tag_str);
        try list.appendSlice(allocator, value);
        try list.append(allocator, SOH);
    }
};

// =============================================================================
// Message Parser
// =============================================================================

/// Parsed FIX message
pub const ParsedMessage = struct {
    msg_type: MsgType,
    fields: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ParsedMessage {
        return .{
            .msg_type = .Heartbeat,
            .fields = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParsedMessage) void {
        self.fields.deinit();
    }

    pub fn getField(self: ParsedMessage, tag: u16) ?[]const u8 {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{tag}) catch return null;
        return self.fields.get(key);
    }

    pub fn getIntField(self: ParsedMessage, tag: u16) ?i64 {
        const value = self.getField(tag) orelse return null;
        return std.fmt.parseInt(i64, value, 10) catch null;
    }

    pub fn getFloatField(self: ParsedMessage, tag: u16) ?f64 {
        const value = self.getField(tag) orelse return null;
        return std.fmt.parseFloat(f64, value) catch null;
    }
};

/// Parse a FIX message
pub fn parseMessage(allocator: std.mem.Allocator, data: []const u8) !ParsedMessage {
    var msg = ParsedMessage.init(allocator);
    errdefer msg.deinit();

    var iter = std.mem.splitScalar(u8, data, SOH);
    while (iter.next()) |field| {
        if (field.len == 0) continue;

        const eq_idx = std.mem.indexOf(u8, field, "=") orelse continue;
        const tag_str = field[0..eq_idx];
        const value = field[eq_idx + 1..];

        // Store the field
        const key = try allocator.dupe(u8, tag_str);
        const val = try allocator.dupe(u8, value);
        try msg.fields.put(key, val);

        // Check for MsgType
        if (std.mem.eql(u8, tag_str, "35")) {
            if (MsgType.fromString(value)) |mt| {
                msg.msg_type = mt;
            }
        }
    }

    return msg;
}

// =============================================================================
// Timestamp Utilities
// =============================================================================

/// Generate FIX timestamp in format: YYYYMMDD-HH:MM:SS.sss
pub fn generateTimestamp(buf: []u8) []const u8 {
    var ts_info: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts_info);
    const epoch_seconds: u64 = @intCast(ts_info.sec);

    // Get milliseconds from nanoseconds
    const millis: u64 = @intCast(@divFloor(ts_info.nsec, 1_000_000));

    // Convert epoch to date/time components
    const days_since_epoch = epoch_seconds / 86400;
    const time_of_day = epoch_seconds % 86400;

    const hours = time_of_day / 3600;
    const minutes = (time_of_day % 3600) / 60;
    const seconds = time_of_day % 60;

    // Calculate year, month, day from days since epoch (1970-01-01)
    var year: u32 = 1970;
    var remaining_days: u64 = days_since_epoch;

    while (true) {
        const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const month_days = if (isLeapYear(year))
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (month_days) |days| {
        if (remaining_days < days) break;
        remaining_days -= days;
        month += 1;
    }
    const day: u8 = @intCast(remaining_days + 1);

    // Format: YYYYMMDD-HH:MM:SS.sss
    const result = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        year, month, day, hours, minutes, seconds, millis,
    }) catch return buf[0..0];

    return result;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

// =============================================================================
// Coinbase Session
// =============================================================================

/// Coinbase FIX credentials
pub const CoinbaseCredentials = struct {
    api_key: []const u8,
    api_secret: []const u8,  // Base64-encoded
    passphrase: []const u8,
};

/// Coinbase FIX 5.0 session manager
pub const CoinbaseSession = struct {
    const Self = @This();

    credentials: CoinbaseCredentials,
    outgoing_seq_num: u32,
    incoming_seq_num: u32,
    is_connected: bool,
    heartbeat_interval: u32,
    last_heartbeat_time: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, credentials: CoinbaseCredentials) Self {
        return .{
            .credentials = credentials,
            .outgoing_seq_num = 1,
            .incoming_seq_num = 1,
            .is_connected = false,
            .heartbeat_interval = 30,
            .last_heartbeat_time = getTimestamp(),
            .allocator = allocator,
        };
    }

    /// Create a Logon message with HMAC-SHA256 signature
    pub fn createLogon(self: *Self) ![]u8 {
        var builder = MessageBuilder.init(self.allocator);
        defer builder.deinit();

        // Generate timestamp
        var ts_buf: [32]u8 = undefined;
        const sending_time = generateTimestamp(&ts_buf);

        // Create signature prehash: SendingTime|MsgType|MsgSeqNum|SenderCompID|TargetCompID|Passphrase
        // Joined with SOH (0x01)
        const Buffer = std.ArrayListAligned(u8, null);
        var prehash = Buffer{ .items = &.{}, .capacity = 0 };
        defer prehash.deinit(self.allocator);

        try prehash.appendSlice(self.allocator, sending_time);
        try prehash.append(self.allocator, SOH);
        try prehash.appendSlice(self.allocator, "A"); // MsgType = Logon
        try prehash.append(self.allocator, SOH);

        var seq_buf: [16]u8 = undefined;
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d}", .{self.outgoing_seq_num}) catch unreachable;
        try prehash.appendSlice(self.allocator, seq_str);
        try prehash.append(self.allocator, SOH);

        try prehash.appendSlice(self.allocator, self.credentials.api_key);
        try prehash.append(self.allocator, SOH);
        try prehash.appendSlice(self.allocator, COINBASE_TARGET);
        try prehash.append(self.allocator, SOH);
        try prehash.appendSlice(self.allocator, self.credentials.passphrase);
        // No trailing delimiter

        // Compute HMAC-SHA256 signature
        const signature = try self.computeSignature(prehash.items);
        defer self.allocator.free(signature);

        // Build Logon message body
        try builder.addField(Tag.EncryptMethod, "0");  // No encryption
        try builder.addIntField(Tag.HeartBtInt, self.heartbeat_interval);
        try builder.addField(Tag.ResetSeqNumFlag, "Y");
        try builder.addField(Tag.Username, self.credentials.api_key);
        try builder.addField(Tag.Password, self.credentials.passphrase);

        // Signature
        var sig_len_buf: [16]u8 = undefined;
        const sig_len_str = std.fmt.bufPrint(&sig_len_buf, "{d}", .{signature.len}) catch unreachable;
        try builder.addField(Tag.RawDataLength, sig_len_str);
        try builder.addField(Tag.RawData, signature);

        // FIX 5.0 application version
        try builder.addField(Tag.DefaultApplVerID, FIX_APP_VERSION_ID);

        // Coinbase-specific: Cancel orders on disconnect
        try builder.addField(Tag.CancelOrdersOnDisconnect, "Y");

        // Finalize
        const msg = try builder.finalize(
            .Logon,
            self.credentials.api_key,
            COINBASE_TARGET,
            self.outgoing_seq_num,
            sending_time,
        );

        self.outgoing_seq_num += 1;
        return msg;
    }

    /// Create a NewOrderSingle message
    pub fn createNewOrder(
        self: *Self,
        cl_ord_id: []const u8,  // Must be UUIDv4
        symbol: []const u8,     // e.g., "BTC-USD"
        side: Side,
        order_type: OrdType,
        quantity: f64,
        price: ?f64,
        time_in_force: TimeInForce,
    ) ![]u8 {
        var builder = MessageBuilder.init(self.allocator);
        defer builder.deinit();

        var ts_buf: [32]u8 = undefined;
        const sending_time = generateTimestamp(&ts_buf);

        // Order fields
        try builder.addField(Tag.ClOrdID, cl_ord_id);
        try builder.addField(Tag.Symbol, symbol);
        try builder.addCharField(Tag.Side, side.toChar());
        try builder.addDecimalField(Tag.OrderQty, quantity, 8);
        try builder.addCharField(Tag.OrdType, order_type.toChar());

        if (price) |p| {
            try builder.addDecimalField(Tag.Price, p, 2);
        }

        try builder.addCharField(Tag.TimeInForce, time_in_force.toChar());
        try builder.addField(Tag.TransactTime, sending_time);

        const msg = try builder.finalize(
            .NewOrderSingle,
            self.credentials.api_key,
            COINBASE_TARGET,
            self.outgoing_seq_num,
            sending_time,
        );

        self.outgoing_seq_num += 1;
        return msg;
    }

    /// Create an OrderCancelRequest message
    pub fn createCancelOrder(
        self: *Self,
        cl_ord_id: []const u8,
        orig_cl_ord_id: []const u8,
        order_id: []const u8,
        symbol: []const u8,
    ) ![]u8 {
        var builder = MessageBuilder.init(self.allocator);
        defer builder.deinit();

        var ts_buf: [32]u8 = undefined;
        const sending_time = generateTimestamp(&ts_buf);

        try builder.addField(Tag.ClOrdID, cl_ord_id);
        try builder.addField(Tag.OrigClOrdID, orig_cl_ord_id);
        try builder.addField(Tag.OrderID, order_id);
        try builder.addField(Tag.Symbol, symbol);

        const msg = try builder.finalize(
            .OrderCancelRequest,
            self.credentials.api_key,
            COINBASE_TARGET,
            self.outgoing_seq_num,
            sending_time,
        );

        self.outgoing_seq_num += 1;
        return msg;
    }

    /// Create a Heartbeat message
    pub fn createHeartbeat(self: *Self, test_req_id: ?[]const u8) ![]u8 {
        var builder = MessageBuilder.init(self.allocator);
        defer builder.deinit();

        var ts_buf: [32]u8 = undefined;
        const sending_time = generateTimestamp(&ts_buf);

        if (test_req_id) |id| {
            try builder.addField(Tag.TestReqID, id);
        }

        const msg = try builder.finalize(
            .Heartbeat,
            self.credentials.api_key,
            COINBASE_TARGET,
            self.outgoing_seq_num,
            sending_time,
        );

        self.outgoing_seq_num += 1;
        self.last_heartbeat_time = getTimestamp();
        return msg;
    }

    /// Create a TestRequest message
    pub fn createTestRequest(self: *Self, test_req_id: []const u8) ![]u8 {
        var builder = MessageBuilder.init(self.allocator);
        defer builder.deinit();

        var ts_buf: [32]u8 = undefined;
        const sending_time = generateTimestamp(&ts_buf);

        try builder.addField(Tag.TestReqID, test_req_id);

        const msg = try builder.finalize(
            .TestRequest,
            self.credentials.api_key,
            COINBASE_TARGET,
            self.outgoing_seq_num,
            sending_time,
        );

        self.outgoing_seq_num += 1;
        return msg;
    }

    /// Create a Logout message
    pub fn createLogout(self: *Self, text: ?[]const u8) ![]u8 {
        var builder = MessageBuilder.init(self.allocator);
        defer builder.deinit();

        var ts_buf: [32]u8 = undefined;
        const sending_time = generateTimestamp(&ts_buf);

        if (text) |t| {
            try builder.addField(Tag.Text, t);
        }

        const msg = try builder.finalize(
            .Logout,
            self.credentials.api_key,
            COINBASE_TARGET,
            self.outgoing_seq_num,
            sending_time,
        );

        self.outgoing_seq_num += 1;
        return msg;
    }

    /// Check if heartbeat is needed
    pub fn needsHeartbeat(self: Self) bool {
        const now = getTimestamp();
        return (now - self.last_heartbeat_time) >= self.heartbeat_interval;
    }

    /// Compute HMAC-SHA256 signature and return Base64 encoded
    fn computeSignature(self: Self, message: []const u8) ![]u8 {
        // Decode the base64 secret
        const secret = try decodeBase64(self.allocator, self.credentials.api_secret);
        defer self.allocator.free(secret);

        // Compute HMAC-SHA256
        var hmac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&hmac, message, secret);

        // Encode result as Base64
        return try encodeBase64(self.allocator, &hmac);
    }
};

// =============================================================================
// Base64 Utilities
// =============================================================================

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = ((data.len + 2) / 3) * 4;
    var result = try allocator.alloc(u8, encoded_len);

    var i: usize = 0;
    var j: usize = 0;

    while (i < data.len) {
        const b0 = data[i];
        const b1 = if (i + 1 < data.len) data[i + 1] else 0;
        const b2 = if (i + 2 < data.len) data[i + 2] else 0;

        result[j] = base64_alphabet[b0 >> 2];
        result[j + 1] = base64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        result[j + 2] = if (i + 1 < data.len) base64_alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)] else '=';
        result[j + 3] = if (i + 2 < data.len) base64_alphabet[b2 & 0x3f] else '=';

        i += 3;
        j += 4;
    }

    return result;
}

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len == 0) return try allocator.alloc(u8, 0);

    // Calculate decoded length
    var padding: usize = 0;
    if (encoded.len >= 2) {
        if (encoded[encoded.len - 1] == '=') padding += 1;
        if (encoded[encoded.len - 2] == '=') padding += 1;
    }

    const decoded_len = (encoded.len / 4) * 3 - padding;
    var result = try allocator.alloc(u8, decoded_len);

    var i: usize = 0;
    var j: usize = 0;

    while (i < encoded.len) {
        const v0 = decodeBase64Char(encoded[i]);
        const v1 = decodeBase64Char(encoded[i + 1]);
        const v2 = if (encoded[i + 2] != '=') decodeBase64Char(encoded[i + 2]) else 0;
        const v3 = if (encoded[i + 3] != '=') decodeBase64Char(encoded[i + 3]) else 0;

        if (j < decoded_len) result[j] = (v0 << 2) | (v1 >> 4);
        if (j + 1 < decoded_len) result[j + 1] = (v1 << 4) | (v2 >> 2);
        if (j + 2 < decoded_len) result[j + 2] = (v2 << 6) | v3;

        i += 4;
        j += 3;
    }

    return result;
}

fn decodeBase64Char(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return c - 'a' + 26;
    if (c >= '0' and c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return 0;
}

// =============================================================================
// Tests
// =============================================================================

test "timestamp generation" {
    var buf: [32]u8 = undefined;
    const ts = generateTimestamp(&buf);

    // Should be in format YYYYMMDD-HH:MM:SS.sss
    try std.testing.expect(ts.len == 21);
    try std.testing.expect(ts[8] == '-');
    try std.testing.expect(ts[11] == ':');
    try std.testing.expect(ts[14] == ':');
    try std.testing.expect(ts[17] == '.');
}

test "base64 encode/decode" {
    const allocator = std.testing.allocator;

    const original = "Hello, World!";
    const encoded = try encodeBase64(allocator, original);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("SGVsbG8sIFdvcmxkIQ==", encoded);

    const decoded = try decodeBase64(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "message builder" {
    const allocator = std.testing.allocator;

    var builder = MessageBuilder.init(allocator);
    defer builder.deinit();

    try builder.addField(Tag.Symbol, "BTC-USD");
    try builder.addIntField(Tag.OrderQty, 100);
    try builder.addCharField(Tag.Side, Side.Buy.toChar());

    const buf = builder.getBuffer();
    try std.testing.expect(buf.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf, "55=BTC-USD") != null);
}
