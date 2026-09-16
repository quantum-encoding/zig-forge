//! Template parser. Turns text containing `{NAME}` placeholders and
//! `{?VAR=value}…{:}…{/}` outcome blocks into a node tree that `render.zig`
//! walks against a set of bindings.
//!
//! Syntax (delimiters are configurable, `{` and `}` by default):
//!
//!   {NAME}                substitute the binding of NAME
//!   {NAME|upper|trim}     substitute, then apply filters left to right
//!   {ID|left:8}           a filter may take one argument after ':'
//!   {?NAME}…{/}           block kept when NAME is truthy (bool true / non-empty)
//!   {?NAME=value}…{/}     block kept when NAME equals value
//!   {?NAME!=value}…{/}    block kept when NAME differs from value
//!   {:}                   else branch inside a block
//!   {! any text }         comment, removed from output
//!   {{  and  }}           literal delimiter characters
//!
//! A block tag (`{?…}`, `{:}`, `{/}`) or comment that is the only thing on its
//! line is removed together with the line, so letters do not gain blank lines
//! where a branch was not taken. Values may be quoted (`{?A="two words"}`).

const std = @import("std");
const Diag = @import("diag.zig").Diag;

pub const Filter = struct {
    name: []const u8,
    arg: []const u8 = "",
};

pub const Var = struct {
    name: []const u8,
    filters: []const Filter,
    line: u32,
};

pub const CondOp = enum { truthy, eq, ne };

pub const Cond = struct {
    name: []const u8,
    op: CondOp,
    value: []const u8,
    then_nodes: []const Node,
    else_nodes: []const Node,
    line: u32,
};

pub const Node = union(enum) {
    text: []const u8,
    variable: Var,
    cond: Cond,
};

pub const Delims = struct {
    open: []const u8 = "{",
    close: []const u8 = "}",
};

pub const ParseError = error{
    OutOfMemory,
    UnterminatedTag,
    EmptyTag,
    BadName,
    BadFilter,
    BadCondition,
    UnexpectedElse,
    UnexpectedClose,
    UnclosedBlock,
    BadDelimiters,
};

pub const Template = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const Node,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
    }

    /// Every distinct variable name the template reads, in first-use order
    /// (placeholders and block conditions alike).
    pub fn variables(self: *const Template, gpa: std.mem.Allocator) ![]const []const u8 {
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        try collectVars(self.nodes, gpa, &seen);
        const out = try gpa.alloc([]const u8, seen.count());
        for (seen.keys(), 0..) |k, i| out[i] = k;
        return out;
    }
};

fn collectVars(nodes: []const Node, gpa: std.mem.Allocator, seen: *std.StringArrayHashMapUnmanaged(void)) !void {
    for (nodes) |n| switch (n) {
        .text => {},
        .variable => |v| try seen.put(gpa, v.name, {}),
        .cond => |c| {
            try seen.put(gpa, c.name, {});
            try collectVars(c.then_nodes, gpa, seen);
            try collectVars(c.else_nodes, gpa, seen);
        },
    };
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
    }
    return true;
}

/// Parse `src`. All returned memory lives in the template's arena; `src` is
/// not retained.
pub fn parse(gpa: std.mem.Allocator, src: []const u8, delims: Delims, diag: *Diag) ParseError!Template {
    if (delims.open.len == 0 or delims.close.len == 0 or std.mem.eql(u8, delims.open, delims.close)) {
        diag.set(0, "delimiters must be non-empty and distinct", .{});
        return error.BadDelimiters;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p = Parser{
        .a = arena.allocator(),
        .src = src,
        .delims = delims,
        .diag = diag,
    };
    const r = try p.parseNodes(0);
    return .{ .arena = arena, .nodes = r.nodes };
}

const Terminator = enum { top, else_tag, close_tag };

const BlockResult = struct { nodes: []const Node, ended_by: Terminator };

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    delims: Delims,
    diag: *Diag,
    i: usize = 0,
    line: u32 = 1,
    /// Source index of the first byte of the current line.
    line_start: usize = 0,

    /// Parse nodes until `{:}`, `{/}` or end of input. `depth` is the block
    /// nesting depth, used to reject stray else/close tags at the top level.
    fn parseNodes(self: *Parser, depth: u32) ParseError!BlockResult {
        var nodes: std.ArrayList(Node) = .empty;
        var text: std.ArrayList(u8) = .empty;
        const open = self.delims.open;
        const close = self.delims.close;

        while (self.i < self.src.len) {
            if (std.mem.startsWith(u8, self.src[self.i..], open)) {
                // Escaped open delimiter.
                if (std.mem.startsWith(u8, self.src[self.i + open.len ..], open)) {
                    try text.appendSlice(self.a, open);
                    self.i += 2 * open.len;
                    continue;
                }
                const tag_start = self.i;
                const tag_line = self.line;
                const body_start = self.i + open.len;
                const end_rel = std.mem.indexOf(u8, self.src[body_start..], close) orelse {
                    self.diag.set(tag_line, "unterminated tag (missing '{s}')", .{close});
                    return error.UnterminatedTag;
                };
                const body = self.src[body_start .. body_start + end_rel];
                const tag_end = body_start + end_rel + close.len;
                if (std.mem.indexOfScalar(u8, body, '\n') != null) {
                    self.diag.set(tag_line, "tag spans a line break", .{});
                    return error.UnterminatedTag;
                }
                const trimmed = std.mem.trim(u8, body, " \t");
                if (trimmed.len == 0) {
                    self.diag.set(tag_line, "empty tag", .{});
                    return error.EmptyTag;
                }

                switch (trimmed[0]) {
                    '!' => {
                        try self.consumeTag(&text, tag_start, tag_end, true);
                    },
                    '?' => {
                        const c = try self.parseCondHead(trimmed[1..], tag_line);
                        try self.consumeTag(&text, tag_start, tag_end, true);
                        try flushText(&nodes, &text, self.a);
                        const then_r = try self.parseNodes(depth + 1);
                        var else_nodes: []const Node = &.{};
                        switch (then_r.ended_by) {
                            .top => {
                                self.diag.set(tag_line, "block '{s}' opened here is never closed", .{c.name});
                                return error.UnclosedBlock;
                            },
                            .else_tag => {
                                const else_r = try self.parseNodes(depth + 1);
                                switch (else_r.ended_by) {
                                    .close_tag => else_nodes = else_r.nodes,
                                    .else_tag => {
                                        self.diag.set(self.line, "second else in block '{s}'", .{c.name});
                                        return error.UnexpectedElse;
                                    },
                                    .top => {
                                        self.diag.set(tag_line, "block '{s}' opened here is never closed", .{c.name});
                                        return error.UnclosedBlock;
                                    },
                                }
                            },
                            .close_tag => {},
                        }
                        try nodes.append(self.a, .{ .cond = .{
                            .name = c.name,
                            .op = c.op,
                            .value = c.value,
                            .then_nodes = then_r.nodes,
                            .else_nodes = else_nodes,
                            .line = tag_line,
                        } });
                    },
                    ':' => {
                        if (trimmed.len != 1) {
                            self.diag.set(tag_line, "else tag must be exactly '{s}:{s}'", .{ open, close });
                            return error.BadCondition;
                        }
                        if (depth == 0) {
                            self.diag.set(tag_line, "else outside any block", .{});
                            return error.UnexpectedElse;
                        }
                        try self.consumeTag(&text, tag_start, tag_end, true);
                        try flushText(&nodes, &text, self.a);
                        return .{ .nodes = try nodes.toOwnedSlice(self.a), .ended_by = .else_tag };
                    },
                    '/' => {
                        if (trimmed.len != 1) {
                            self.diag.set(tag_line, "close tag must be exactly '{s}/{s}'", .{ open, close });
                            return error.BadCondition;
                        }
                        if (depth == 0) {
                            self.diag.set(tag_line, "close tag with no open block", .{});
                            return error.UnexpectedClose;
                        }
                        try self.consumeTag(&text, tag_start, tag_end, true);
                        try flushText(&nodes, &text, self.a);
                        return .{ .nodes = try nodes.toOwnedSlice(self.a), .ended_by = .close_tag };
                    },
                    else => {
                        const v = try self.parseVar(trimmed, tag_line);
                        try self.consumeTag(&text, tag_start, tag_end, false);
                        try flushText(&nodes, &text, self.a);
                        try nodes.append(self.a, .{ .variable = v });
                    },
                }
                continue;
            }
            // Escaped close delimiter in plain text.
            if (std.mem.startsWith(u8, self.src[self.i..], close) and
                std.mem.startsWith(u8, self.src[self.i + close.len ..], close))
            {
                try text.appendSlice(self.a, close);
                self.i += 2 * close.len;
                continue;
            }
            const c = self.src[self.i];
            try text.append(self.a, c);
            self.i += 1;
            if (c == '\n') {
                self.line += 1;
                self.line_start = self.i;
            }
        }
        try flushText(&nodes, &text, self.a);
        return .{ .nodes = try nodes.toOwnedSlice(self.a), .ended_by = .top };
    }

    /// Advance past a tag. For block/comment tags that stand alone on their
    /// line, also drop the line's leading whitespace (already in `text`) and
    /// the trailing whitespace + newline.
    fn consumeTag(self: *Parser, text: *std.ArrayList(u8), tag_start: usize, tag_end: usize, standalone_ok: bool) !void {
        self.i = tag_end;
        if (!standalone_ok) return;

        const before = self.src[self.line_start..tag_start];
        for (before) |b| if (b != ' ' and b != '\t') return;

        var j = tag_end;
        while (j < self.src.len and (self.src[j] == ' ' or self.src[j] == '\t')) j += 1;
        if (j < self.src.len) {
            if (self.src[j] == '\r' and j + 1 < self.src.len and self.src[j + 1] == '\n') {
                j += 2;
            } else if (self.src[j] == '\n') {
                j += 1;
            } else return;
        }
        // Standalone: the pending text ends with exactly `before` (no tag can
        // sit between line_start and tag_start, so no escape was expanded).
        std.debug.assert(text.items.len >= before.len);
        text.items.len -= before.len;
        if (j > tag_end and self.src[j - 1] == '\n') {
            self.line += 1;
            self.line_start = j;
        }
        self.i = j;
    }

    fn parseVar(self: *Parser, body: []const u8, line: u32) ParseError!Var {
        var it = std.mem.splitScalar(u8, body, '|');
        const raw_name = std.mem.trim(u8, it.first(), " \t");
        if (!isValidName(raw_name)) {
            self.diag.set(line, "bad variable name '{s}' (letters, digits, '_' and '.', must start with a letter)", .{raw_name});
            return error.BadName;
        }
        var filters: std.ArrayList(Filter) = .empty;
        while (it.next()) |f| {
            const spec = std.mem.trim(u8, f, " \t");
            const colon = std.mem.indexOfScalar(u8, spec, ':');
            const name = if (colon) |c| spec[0..c] else spec;
            const arg = if (colon) |c| spec[c + 1 ..] else "";
            if (name.len == 0 or !isValidName(name)) {
                self.diag.set(line, "bad filter '{s}' on '{s}'", .{ spec, raw_name });
                return error.BadFilter;
            }
            try filters.append(self.a, .{ .name = try self.a.dupe(u8, name), .arg = try self.a.dupe(u8, arg) });
        }
        return .{
            .name = try self.a.dupe(u8, raw_name),
            .filters = try filters.toOwnedSlice(self.a),
            .line = line,
        };
    }

    const CondHead = struct { name: []const u8, op: CondOp, value: []const u8 };

    fn parseCondHead(self: *Parser, body: []const u8, line: u32) ParseError!CondHead {
        const b = std.mem.trim(u8, body, " \t");
        if (std.mem.indexOf(u8, b, "!=")) |k| {
            return self.finishCond(b[0..k], .ne, b[k + 2 ..], line);
        }
        if (std.mem.indexOfScalar(u8, b, '=')) |k| {
            return self.finishCond(b[0..k], .eq, b[k + 1 ..], line);
        }
        return self.finishCond(b, .truthy, "", line);
    }

    fn finishCond(self: *Parser, raw_name: []const u8, op: CondOp, raw_value: []const u8, line: u32) ParseError!CondHead {
        const name = std.mem.trim(u8, raw_name, " \t");
        if (!isValidName(name)) {
            self.diag.set(line, "bad variable name '{s}' in condition", .{name});
            return error.BadCondition;
        }
        var value = std.mem.trim(u8, raw_value, " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        } else if (op != .truthy and value.len == 0) {
            self.diag.set(line, "condition on '{s}' compares against an empty value; quote it as \"\" if intended", .{name});
            return error.BadCondition;
        }
        return .{
            .name = try self.a.dupe(u8, name),
            .op = op,
            .value = try self.a.dupe(u8, value),
        };
    }
};

fn flushText(nodes: *std.ArrayList(Node), text: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    if (text.items.len == 0) return;
    try nodes.append(a, .{ .text = try a.dupe(u8, text.items) });
    text.items.len = 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseT(src: []const u8) !Template {
    var d = Diag{};
    return parse(testing.allocator, src, .{}, &d);
}

test "plain text and placeholders" {
    var t = try parseT("Dear {NAME|title}, ref {REF}.");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 5), t.nodes.len);
    try testing.expectEqualStrings("Dear ", t.nodes[0].text);
    try testing.expectEqualStrings("NAME", t.nodes[1].variable.name);
    try testing.expectEqualStrings("title", t.nodes[1].variable.filters[0].name);
    try testing.expectEqualStrings("REF", t.nodes[3].variable.name);
    try testing.expectEqualStrings(".", t.nodes[4].text);
}

test "escaped delimiters" {
    var t = try parseT("a {{b}} c");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.nodes.len);
    try testing.expectEqualStrings("a {b} c", t.nodes[0].text);
}

test "block with else, standalone lines removed" {
    var t = try parseT("x\n{?O=yes}\nY\n{:}\nN\n{/}\nz\n");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 3), t.nodes.len);
    try testing.expectEqualStrings("x\n", t.nodes[0].text);
    const c = t.nodes[1].cond;
    try testing.expectEqual(CondOp.eq, c.op);
    try testing.expectEqualStrings("yes", c.value);
    try testing.expectEqualStrings("Y\n", c.then_nodes[0].text);
    try testing.expectEqualStrings("N\n", c.else_nodes[0].text);
    try testing.expectEqualStrings("z\n", t.nodes[2].text);
}

test "inline block keeps surrounding text" {
    var t = try parseT("a {?B}b{/} c");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 3), t.nodes.len);
    try testing.expectEqualStrings("a ", t.nodes[0].text);
    try testing.expectEqualStrings(" c", t.nodes[2].text);
}

test "indented standalone tag strips indentation and newline" {
    var t = try parseT("  {?A}  \n  body\n  {/}\n");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.nodes.len);
    try testing.expectEqualStrings("  body\n", t.nodes[0].cond.then_nodes[0].text);
}

test "comment removed" {
    var t = try parseT("a{! note }b\n{! whole line }\nc");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.nodes.len);
    try testing.expectEqualStrings("ab\nc", t.nodes[0].text);
}

test "quoted condition value and ne" {
    var t = try parseT("{?K!=\"two words\"}x{/}");
    defer t.deinit();
    try testing.expectEqual(CondOp.ne, t.nodes[0].cond.op);
    try testing.expectEqualStrings("two words", t.nodes[0].cond.value);
}

test "errors carry line numbers" {
    var d = Diag{};
    try testing.expectError(error.UnclosedBlock, parse(testing.allocator, "a\n\n{?X}\nb", .{}, &d));
    try testing.expectEqual(@as(u32, 3), d.line);
    try testing.expectError(error.UnterminatedTag, parse(testing.allocator, "ok\n{NAME", .{}, &d));
    try testing.expectEqual(@as(u32, 2), d.line);
    try testing.expectError(error.UnexpectedClose, parse(testing.allocator, "{/}", .{}, &d));
    try testing.expectError(error.UnexpectedElse, parse(testing.allocator, "{:}", .{}, &d));
    try testing.expectError(error.BadName, parse(testing.allocator, "{9x}", .{}, &d));
    try testing.expectError(error.EmptyTag, parse(testing.allocator, "{ }", .{}, &d));
    try testing.expectError(error.BadCondition, parse(testing.allocator, "{?A=}{/}", .{}, &d));
}

test "filter argument" {
    var t = try parseT("{ID|left:8|upper}");
    defer t.deinit();
    const f = t.nodes[0].variable.filters;
    try testing.expectEqualStrings("left", f[0].name);
    try testing.expectEqualStrings("8", f[0].arg);
    try testing.expectEqualStrings("upper", f[1].name);
    try testing.expectEqualStrings("", f[1].arg);
}

test "custom delimiters" {
    var d = Diag{};
    var t = try parse(testing.allocator, "<<A>> and {B}", .{ .open = "<<", .close = ">>" }, &d);
    defer t.deinit();
    try testing.expectEqualStrings("A", t.nodes[0].variable.name);
    try testing.expectEqualStrings(" and {B}", t.nodes[1].text);
}

test "variables() lists names in first-use order without duplicates" {
    var t = try parseT("{B}{?A=1}{B}{C}{/}{A}");
    defer t.deinit();
    const vars = try t.variables(testing.allocator);
    defer testing.allocator.free(vars);
    try testing.expectEqual(@as(usize, 3), vars.len);
    try testing.expectEqualStrings("B", vars[0]);
    try testing.expectEqualStrings("A", vars[1]);
    try testing.expectEqualStrings("C", vars[2]);
}
