//! "Legend letter": a letter PDF whose body is rendered from a zig_legend
//! template and a typed legend, then laid out by the letter engine.
//!
//! A legend (TOML) declares every variable a template may use, with its type
//! (string, enum, int, money, date, bool, list), default, whether it is
//! required, and named scenarios. The template holds `{NAME}` placeholders,
//! filters and `{?VAR=value}…{:}…{/}` outcome blocks and renders to Markdown,
//! which `markdown.zig` flows across pages exactly like a plain letter.
//!
//! Input shape:
//! ```json
//! {
//!   "legend_toml": "[[var]]\nname = \"DEBTOR_NAME\"\nrequired = true\n...",
//!   "template":    "Dear {SALUTATION},\n\n...",
//!   "scenario":    "company-unpaid",            // optional
//!   "bindings":    { "DEBTOR_NAME": "Northwind Fabrication Ltd",
//!                    "AMOUNT_OUTSTANDING": "1840.00",
//!                    "INVOICE_NUMBERS": ["INV-1041", "INV-1047"] },
//!   "letter": {                                  // letter.zig fields
//!     "company_name": "{CREDITOR_NAME}",         // text fields may hold placeholders
//!     "date": "{LETTER_DATE|long}",
//!     "subject": "Invoice {INVOICE_NUMBERS} overdue",
//!     "accent_hex": "#1f4e79"
//!   }
//! }
//! ```
//!
//! Binding precedence, highest first: `bindings`, the scenario, legend
//! defaults; dependent (`by`) variables then follow from their map. Every
//! binding is type-checked against the legend.
//!
//! Refusals (each is an error with a message, never a PDF):
//!   - the legend or template does not parse;
//!   - the template (or a letter text field) uses a name the legend does not
//!     declare, in any branch, taken or not;
//!   - a binding names an undeclared variable or fails its type (enum member,
//!     integer bounds, money decimals, calendar date, boolean spelling);
//!   - a binding targets a dependent (`by`) variable, whose value must come
//!     from its map;
//!   - the scenario does not exist;
//!   - a required variable is unbound or bound to blank text;
//!   - a placeholder in a branch that is taken has no value;
//!   - the rendered body is empty.

const std = @import("std");
const zl = @import("zig_legend");
const letter = @import("letter.zig");
const markdown = @import("markdown.zig");

pub const Error = error{
    /// The input is not a JSON object or a field has the wrong JSON type.
    InvalidInput,
    /// legend_toml does not load.
    LegendInvalid,
    /// The template (or a letter text field) does not parse, or uses a name
    /// the legend does not declare.
    TemplateInvalid,
    /// A binding, scenario or required variable is wrong or missing.
    BindingInvalid,
    /// Rendering hit an unbound placeholder, a bad value or an empty body.
    RenderFailed,
    /// The letter engine failed to build the PDF.
    PdfFailed,
    OutOfMemory,
};

/// Human-readable reason for the last error, sized to fit the FFI error
/// buffer with room to spare.
pub const Diagnostic = struct {
    buf: [240]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            // Longer than the buffer: keep the prefix, marked as cut.
            const cut = "...";
            @memcpy(self.buf[self.buf.len - cut.len ..], cut);
            break :blk self.buf[0..];
        };
        self.len = s.len;
    }

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Letter text fields that may hold placeholders. Image sources, colours,
/// passwords and numbers are passed through untouched.
const text_fields = [_][]const u8{
    "company_name",   "company_address", "sender_contact",  "date",
    "reference",      "recipient_name",  "recipient_address", "subject",
    "closing",        "signature_name",  "signature_title",
};

/// The rendered text of a legend letter, before layout.
pub const Rendered = struct {
    /// Markdown body from the template.
    body_markdown: []const u8,
    /// The letter frame with its text fields rendered and the body set.
    input: markdown.LetterInput,
};

/// Render the body and letter fields. All memory comes from `arena`; the
/// result borrows from it and from nothing else.
pub fn renderText(arena: std.mem.Allocator, json_str: []const u8, diag: *Diagnostic) Error!Rendered {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json_str, .{}) catch {
        diag.set("input is not valid JSON", .{});
        return error.InvalidInput;
    };
    if (root != .object) {
        diag.set("input must be a JSON object", .{});
        return error.InvalidInput;
    }
    const o = root.object;

    const legend_src = try requireString(o, "legend_toml", diag);
    const template_src = try requireString(o, "template", diag);
    const scenario: ?[]const u8 = blk: {
        const v = o.get("scenario") orelse break :blk null;
        switch (v) {
            .null => break :blk null,
            .string => |s| break :blk if (s.len == 0) null else s,
            else => {
                diag.set("'scenario' must be a string", .{});
                return error.InvalidInput;
            },
        }
    };

    var ld = zl.Diag{};
    const legend = zl.Legend.load(arena, legend_src, &ld) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setFromLegend(diag, "legend", &ld);
            return error.LegendInvalid;
        },
    };

    const tpl = try parseChecked(arena, &legend, template_src, "template", diag);

    const overrides = try bindingsToOverrides(arena, &legend, o.get("bindings"), diag);

    const bindings = zl.render.resolve(arena, &legend, scenario, &.{}, overrides, &ld) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setFromLegend(diag, "bindings", &ld);
            return error.BindingInvalid;
        },
    };

    for (legend.vars) |*v| {
        if (!v.required) continue;
        const value = bindings.get(v.name) orelse continue; // resolve() already refused unbound
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) {
            diag.set("bindings: required variable '{s}' is blank", .{v.name});
            return error.BindingInvalid;
        }
    }

    const body = try renderChecked(arena, &tpl, &legend, &bindings, "template", diag);
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
        diag.set("template rendered an empty body", .{});
        return error.RenderFailed;
    }

    var in = markdown.LetterInput{};
    if (o.get("letter")) |lv| switch (lv) {
        .null => {},
        .object => |lo| {
            in = letter.letterInputFromObject(lo);
            inline for (text_fields) |field| {
                const src = @field(in, field);
                if (std.mem.indexOf(u8, src, legend.delims.open) != null) {
                    const t = try parseChecked(arena, &legend, src, "letter." ++ field, diag);
                    @field(in, field) = try renderChecked(arena, &t, &legend, &bindings, "letter." ++ field, diag);
                }
            }
        },
        else => {
            diag.set("'letter' must be an object", .{});
            return error.InvalidInput;
        },
    };
    in.body_markdown = body;
    return .{ .body_markdown = body, .input = in };
}

/// Render a legend letter to PDF bytes owned by `allocator`.
pub fn generate(allocator: std.mem.Allocator, json_str: []const u8, diag: *Diagnostic) Error![]u8 {
    return generateSeeded(allocator, json_str, null, diag);
}

/// As `generate`, with a host-supplied encryption seed (WASM has no
/// in-module CSPRNG); only used when `letter.password` is set.
pub fn generateSeeded(allocator: std.mem.Allocator, json_str: []const u8, seed: ?[32]u8, diag: *Diagnostic) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var r = try renderText(arena_state.allocator(), json_str, diag);
    r.input.seed = seed;
    return markdown.generateLetter(allocator, r.input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.set("letter layout failed: {s}", .{@errorName(err)});
            return error.PdfFailed;
        },
    };
}

/// The rendered text as JSON, for previews, email bodies or tests:
/// `{"body_markdown": "...", "letter": {"company_name": "...", ...}}`.
/// Bytes are owned by `allocator`.
pub fn renderTextJson(allocator: std.mem.Allocator, json_str: []const u8, diag: *Diagnostic) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const r = try renderText(arena_state.allocator(), json_str, diag);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    writeRenderedJson(&s, r) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeRenderedJson(s: *std.json.Stringify, r: Rendered) !void {
    try s.beginObject();
    try s.objectField("body_markdown");
    try s.write(r.body_markdown);
    try s.objectField("letter");
    try s.beginObject();
    inline for (text_fields) |field| {
        try s.objectField(field);
        try s.write(@field(r.input, field));
    }
    try s.endObject();
    try s.endObject();
}

/// Describe a legend so an app can build a form: its variables (type,
/// default, candidates, dependency), its scenarios and, when a template is
/// given, which names the template uses and which of those the legend lacks.
///
/// Input: `{"legend_toml": "...", "template": "..."}` (template optional).
/// Output (owned by `allocator`):
/// ```json
/// {"name": "...",
///  "variables": [{"name": "DEBTOR_TYPE", "type": "enum", "required": true,
///                 "description": "...", "default": null,
///                 "values": ["company", "sole_trader", "individual"],
///                 "used_by_template": true}, ...],
///  "scenarios": [{"name": "company-unpaid", "set": {"DEBTOR_TYPE": "company"}}],
///  "template": {"variables": ["..."], "undeclared": []}}
/// ```
pub fn describe(allocator: std.mem.Allocator, json_str: []const u8, diag: *Diagnostic) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json_str, .{}) catch {
        diag.set("input is not valid JSON", .{});
        return error.InvalidInput;
    };
    if (root != .object) {
        diag.set("input must be a JSON object", .{});
        return error.InvalidInput;
    }
    const legend_src = try requireString(root.object, "legend_toml", diag);

    var ld = zl.Diag{};
    const legend = zl.Legend.load(arena, legend_src, &ld) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setFromLegend(diag, "legend", &ld);
            return error.LegendInvalid;
        },
    };

    var used: ?[]const []const u8 = null;
    if (root.object.get("template")) |tv| switch (tv) {
        .null => {},
        .string => |src| {
            const t = zl.template.parse(arena, src, legend.delims, &ld) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    setFromLegend(diag, "template", &ld);
                    return error.TemplateInvalid;
                },
            };
            used = try t.variables(arena);
        },
        else => {
            diag.set("'template' must be a string", .{});
            return error.InvalidInput;
        },
    };

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    writeDescription(&s, &legend, used) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeDescription(s: *std.json.Stringify, legend: *const zl.Legend, used: ?[]const []const u8) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(legend.name);

    try s.objectField("variables");
    try s.beginArray();
    for (legend.vars) |*v| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(v.name);
        try s.objectField("type");
        try s.write(v.kind.label());
        try s.objectField("required");
        try s.write(v.required);
        try s.objectField("description");
        try s.write(v.description);
        try s.objectField("default");
        try s.write(v.default);
        try s.objectField("values");
        try s.write(v.values);
        switch (v.kind) {
            .money => {
                try s.objectField("currency");
                try s.write(v.currency);
                try s.objectField("decimals");
                try s.write(v.decimals);
            },
            .int => {
                try s.objectField("min");
                try s.write(v.min);
                try s.objectField("max");
                try s.write(v.max);
            },
            .list => {
                try s.objectField("sep");
                try s.write(v.sep);
            },
            else => {},
        }
        if (v.by) |by| {
            try s.objectField("by");
            try s.write(by);
            try s.objectField("map");
            try s.beginObject();
            for (v.map) |kv| {
                try s.objectField(kv.key);
                try s.write(kv.value);
            }
            try s.endObject();
        }
        if (used) |names| {
            try s.objectField("used_by_template");
            try s.write(contains(names, v.name));
        }
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("scenarios");
    try s.beginArray();
    for (legend.scenarios) |sc| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(sc.name);
        try s.objectField("set");
        try s.beginObject();
        for (sc.set) |kv| {
            try s.objectField(kv.key);
            try s.write(kv.value);
        }
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();

    if (used) |names| {
        try s.objectField("template");
        try s.beginObject();
        try s.objectField("variables");
        try s.write(names);
        try s.objectField("undeclared");
        try s.beginArray();
        for (names) |n| if (legend.find(n) == null) try s.write(n);
        try s.endArray();
        try s.endObject();
    }
    try s.endObject();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn requireString(o: std.json.ObjectMap, key: []const u8, diag: *Diagnostic) Error![]const u8 {
    const v = o.get(key) orelse {
        diag.set("'{s}' is required", .{key});
        return error.InvalidInput;
    };
    if (v != .string or v.string.len == 0) {
        diag.set("'{s}' must be a non-empty string", .{key});
        return error.InvalidInput;
    }
    return v.string;
}

fn setFromLegend(diag: *Diagnostic, where: []const u8, ld: *const zl.Diag) void {
    if (ld.line > 0) {
        diag.set("{s} line {d}: {s}", .{ where, ld.line, ld.text() });
    } else {
        diag.set("{s}: {s}", .{ where, ld.text() });
    }
}

/// Parse `src` and refuse any name the legend does not declare, whether or
/// not its branch would be taken, so a template error surfaces on the first
/// render rather than on the one scenario that reaches it.
fn parseChecked(arena: std.mem.Allocator, legend: *const zl.Legend, src: []const u8, where: []const u8, diag: *Diagnostic) Error!zl.Template {
    var ld = zl.Diag{};
    const t = zl.template.parse(arena, src, legend.delims, &ld) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setFromLegend(diag, where, &ld);
            return error.TemplateInvalid;
        },
    };
    const names = try t.variables(arena);
    for (names) |n| {
        if (legend.find(n) == null) {
            diag.set("{s} uses '{s}', which the legend does not declare", .{ where, n });
            return error.TemplateInvalid;
        }
    }
    return t;
}

fn renderChecked(
    arena: std.mem.Allocator,
    t: *const zl.Template,
    legend: *const zl.Legend,
    b: *const zl.Bindings,
    where: []const u8,
    diag: *Diagnostic,
) Error![]const u8 {
    var ld = zl.Diag{};
    return zl.render.renderAlloc(arena, t, legend, b, &ld) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setFromLegend(diag, where, &ld);
            return error.RenderFailed;
        },
    };
}

/// JSON `bindings` → zig_legend overrides. Strings bind as-is, numbers and
/// booleans as their text, arrays bind list variables (items joined by the
/// variable's `sep`), null leaves the variable to the scenario or default.
/// Names and types are checked by `resolve`; list items are checked here.
fn bindingsToOverrides(arena: std.mem.Allocator, legend: *const zl.Legend, value: ?std.json.Value, diag: *Diagnostic) Error![]const zl.KV {
    const v = value orelse return &.{};
    const obj = switch (v) {
        .null => return &.{},
        .object => |ob| ob,
        else => {
            diag.set("'bindings' must be an object", .{});
            return error.InvalidInput;
        },
    };
    var out: std.ArrayList(zl.KV) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        // A dependent variable's value is its map's (e.g. a statutory
        // compensation band); letting a binding replace it would defeat the
        // legend, so the controlling variable must be bound instead.
        if (legend.find(name)) |spec| if (spec.by) |by| {
            diag.set("bindings: '{s}' follows '{s}'; bind '{s}' instead", .{ name, by, by });
            return error.BindingInvalid;
        };
        const text: []const u8 = switch (entry.value_ptr.*) {
            .null => continue,
            .string => |s| s,
            .bool => |b| if (b) "true" else "false",
            .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
            .number_string => |n| n,
            .array => |arr| blk: {
                const spec = legend.find(name) orelse {
                    diag.set("bindings: '{s}' is not in the legend", .{name});
                    return error.BindingInvalid;
                };
                if (spec.kind != .list) {
                    diag.set("bindings: '{s}' is an array but not a list variable", .{name});
                    return error.BindingInvalid;
                }
                var joined: std.ArrayList(u8) = .empty;
                for (arr.items, 0..) |item, i| {
                    if (item != .string) {
                        diag.set("bindings: '{s}' list items must be strings", .{name});
                        return error.BindingInvalid;
                    }
                    if (std.mem.indexOf(u8, item.string, spec.sep) != null) {
                        diag.set("bindings: '{s}' item contains the separator '{s}'", .{ name, spec.sep });
                        return error.BindingInvalid;
                    }
                    if (i != 0) try joined.appendSlice(arena, spec.sep);
                    try joined.appendSlice(arena, item.string);
                }
                break :blk try joined.toOwnedSlice(arena);
            },
            .object => {
                diag.set("bindings: '{s}' is an object; bind a string, number, boolean or array", .{name});
                return error.BindingInvalid;
            },
        };
        try out.append(arena, .{ .key = name, .value = text });
    }
    return out.toOwnedSlice(arena);
}
