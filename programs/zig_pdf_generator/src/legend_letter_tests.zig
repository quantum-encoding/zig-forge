//! Tests for legend letters, driven by the debt-recovery pack in
//! templates/letters/ (read at run time; `zig build test` pins the cwd to the
//! package root).

const std = @import("std");
const legend_letter = @import("legend_letter.zig");
const ffi = @import("ffi.zig");

const testing = std.testing;
const pack_dir = "templates/letters/";

fn readPack(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try std.fmt.allocPrint(a, pack_dir ++ "{s}", .{name});
    defer a.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

/// Build the legend-letter input for one pack letter: the legend, the
/// template, its letter frame, the scenario, and bindings made of the shared
/// creditor, the stage (for the chasing letters) and `extra`.
fn packInput(
    a: std.mem.Allocator,
    legend_file: []const u8,
    letter_name: []const u8,
    scenario: ?[]const u8,
    stage: ?[]const u8,
    extra: []const [2][]const u8,
) ![]u8 {
    const legend_src = try readPack(a, legend_file);
    const tpl_name = try std.fmt.allocPrint(a, "{s}.tpl.md", .{letter_name});
    const frame_name = try std.fmt.allocPrint(a, "{s}.letter.json", .{letter_name});
    const tpl_src = try readPack(a, tpl_name);
    const frame_src = try readPack(a, frame_name);
    const stages_src = try readPack(a, "stages.json");

    const frame = try std.json.parseFromSliceLeaky(std.json.Value, a, frame_src, .{});
    const stage_doc = try std.json.parseFromSliceLeaky(std.json.Value, a, stages_src, .{});

    var bindings = std.json.ObjectMap.empty;
    var cit = stage_doc.object.get("creditor").?.object.iterator();
    while (cit.next()) |e| try bindings.put(a, e.key_ptr.*, e.value_ptr.*);
    if (stage) |st| {
        var sit = stage_doc.object.get("stages").?.object.get(st).?.object.iterator();
        while (sit.next()) |e| try bindings.put(a, e.key_ptr.*, e.value_ptr.*);
    }
    for (extra) |kv| try bindings.put(a, kv[0], .{ .string = kv[1] });

    var root = std.json.ObjectMap.empty;
    try root.put(a, "legend_toml", .{ .string = legend_src });
    try root.put(a, "template", .{ .string = tpl_src });
    if (scenario) |s| try root.put(a, "scenario", .{ .string = s });
    try root.put(a, "bindings", .{ .object = bindings });
    try root.put(a, "letter", frame);
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
}

fn renderBody(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    var diag = legend_letter.Diagnostic{};
    const r = legend_letter.renderText(a, input, &diag) catch |err| {
        std.debug.print("legend letter refused: {s}\n", .{diag.text()});
        return err;
    };
    return r.body_markdown;
}

fn expectRefused(input: []const u8, want: legend_letter.Error, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag = legend_letter.Diagnostic{};
    try testing.expectError(want, legend_letter.renderText(arena.allocator(), input, &diag));
    if (std.mem.indexOf(u8, diag.text(), needle) == null) {
        std.debug.print("diagnostic '{s}' lacks '{s}'\n", .{ diag.text(), needle });
        return error.TestUnexpectedDiagnostic;
    }
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

const debt_scenarios = [_][]const u8{ "company-unpaid", "company-partial", "sole-trader-plan", "individual-unpaid", "individual-instalments" };
const stages = [_][]const u8{ "reminder", "second-reminder", "final-demand" };

test "legend letter: every debt-recovery letter renders for every scenario" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (stages) |stage| {
        for (debt_scenarios) |sc| {
            const input = try packInput(a, "debt-recovery.toml", stage, sc, stage, &.{});
            const body = try renderBody(a, input);
            // No placeholder, block tag or comment survives into the letter.
            try testing.expect(!has(body, "{"));
            try testing.expect(!has(body, "}"));
            try testing.expect(has(body, "Dear "));

            var diag = legend_letter.Diagnostic{};
            const pdf = legend_letter.generate(testing.allocator, input, &diag) catch |err| {
                std.debug.print("{s}/{s}: {s}\n", .{ stage, sc, diag.text() });
                return err;
            };
            defer testing.allocator.free(pdf);
            try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-"));
            try testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
        }
    }
}

test "legend letter: final demand follows the protocol only for individuals and sole traders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const company = try renderBody(a, try packInput(a, "debt-recovery.toml", "final-demand", "company-unpaid", "final-demand", &.{}));
    try testing.expect(has(company, "Letter before action"));
    try testing.expect(has(company, "29 September 2026"));
    try testing.expect(has(company, "Practice Direction on Pre-Action Conduct"));
    try testing.expect(!has(company, "Pre-Action Protocol for Debt Claims"));
    try testing.expect(!has(company, "Reply Form"));
    try testing.expect(has(company, "| Fixed-sum compensation for late payment | £70.00 |"));
    try testing.expect(has(company, "**£1,937.83**"));

    const partial = try renderBody(a, try packInput(a, "debt-recovery.toml", "final-demand", "company-partial", "final-demand", &.{}));
    try testing.expect(has(partial, "(£2,000.00)"));
    try testing.expect(!has(partial, "Statutory interest"));

    const individual = try renderBody(a, try packInput(a, "debt-recovery.toml", "final-demand", "individual-unpaid", "final-demand", &.{}));
    try testing.expect(has(individual, "Letter of Claim"));
    try testing.expect(has(individual, "Pre-Action Protocol for Debt Claims"));
    try testing.expect(has(individual, "within 30 days of the date at the top of this letter"));
    try testing.expect(has(individual, "Information Sheet and Reply Form"));
    try testing.expect(has(individual, "Financial Statement"));
    try testing.expect(has(individual, "statement of account"));
    try testing.expect(has(individual, "No interest or other charges are being added"));
    try testing.expect(has(individual, "You can ask us for a copy of the agreement"));
    try testing.expect(has(individual, "Unit 4, Example Trading Estate, Anytown, ZZ9 9ZZ"));
    try testing.expect(!has(individual, "Late Payment"));
    try testing.expect(!has(individual, "29 September 2026")); // the 30-day period is not a computed date

    const oral = try renderBody(a, try packInput(a, "debt-recovery.toml", "final-demand", "individual-instalments", "final-demand", &.{}));
    try testing.expect(has(oral, "oral agreement"));
    try testing.expect(has(oral, "You have offered to pay £10 a month"));

    const sole = try renderBody(a, try packInput(a, "debt-recovery.toml", "final-demand", "sole-trader-plan", "final-demand", &.{}));
    try testing.expect(has(sole, "Pre-Action Protocol for Debt Claims"));
    try testing.expect(has(sole, "Late Payment of Commercial Debts (Interest) Act 1998"));
    try testing.expect(has(sole, "5 monthly payments of £470.00"));
}

test "legend letter: second reminder mentions statutory interest only between businesses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b2b = try renderBody(a, try packInput(a, "debt-recovery.toml", "second-reminder", "company-unpaid", "second-reminder", &.{}));
    try testing.expect(has(b2b, "Late Payment of Commercial Debts"));
    try testing.expect(has(b2b, "letter before action"));
    const consumer = try renderBody(a, try packInput(a, "debt-recovery.toml", "second-reminder", "individual-unpaid", "second-reminder", &.{}));
    try testing.expect(!has(consumer, "Late Payment"));
    try testing.expect(has(consumer, "Letter of Claim"));
}

test "legend letter: statutory interest claim renders for both business scenarios" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "company-unpaid", "company-paid-late", "sole-trader-unpaid" }) |sc| {
        const input = try packInput(a, "statutory-interest.toml", "statutory-interest", sc, null, &.{});
        const body = try renderBody(a, input);
        try testing.expect(!has(body, "{"));
        try testing.expect(has(body, "8% a year above"));
        var diag = legend_letter.Diagnostic{};
        const pdf = try legend_letter.generate(testing.allocator, input, &diag);
        defer testing.allocator.free(pdf);
        try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-"));
    }
    const late = try renderBody(a, try packInput(a, "statutory-interest.toml", "statutory-interest", "company-paid-late", null, &.{}));
    try testing.expect(has(late, "£100.00"));
    try testing.expect(has(late, "£10,000 or more"));
}

test "legend letter: statutory interest is refused for a consumer debtor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try packInput(a, "statutory-interest.toml", "statutory-interest", "company-unpaid", null, &.{.{ "DEBTOR_TYPE", "individual" }});
    try expectRefused(input, error.BindingInvalid, "'individual' is not a value of enum 'DEBTOR_TYPE'");
}

test "legend letter: bad bindings are refused with the reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const L = "debt-recovery.toml";

    // Bad enum value.
    try expectRefused(try packInput(a, L, "reminder", "company-unpaid", "reminder", &.{.{ "DEBTOR_TYPE", "partnership" }}), error.BindingInvalid, "'partnership' is not a value of enum 'DEBTOR_TYPE'");
    // Bad date and bad money.
    try expectRefused(try packInput(a, L, "reminder", "company-unpaid", "reminder", &.{.{ "DUE_DATE", "2026-02-30" }}), error.BindingInvalid, "not a calendar date");
    try expectRefused(try packInput(a, L, "reminder", "company-unpaid", "reminder", &.{.{ "AMOUNT_OUTSTANDING", "1,840" }}), error.BindingInvalid, "not an amount");
    // Unknown variable and unknown scenario.
    try expectRefused(try packInput(a, L, "reminder", "company-unpaid", "reminder", &.{.{ "AMOUNT_OUTSTANDNG", "1" }}), error.BindingInvalid, "'AMOUNT_OUTSTANDNG' is not in the legend");
    try expectRefused(try packInput(a, L, "reminder", "no-such-debtor", "reminder", &.{}), error.BindingInvalid, "unknown scenario 'no-such-debtor'");
    // Required variable missing (no scenario, so DEBTOR_TYPE is unbound).
    try expectRefused(try packInput(a, L, "reminder", null, "reminder", &.{}), error.BindingInvalid, "is not bound");
    // Required variable bound to blank text.
    try expectRefused(try packInput(a, L, "reminder", "company-unpaid", "reminder", &.{.{ "SALUTATION", "  " }}), error.BindingInvalid, "'SALUTATION' is blank");
    // A dependent variable cannot be bound around its map.
    try expectRefused(try packInput(a, L, "final-demand", "company-unpaid", "final-demand", &.{.{ "COMPENSATION", "5" }}), error.BindingInvalid, "'COMPENSATION' follows 'DEBT_BAND'");
    // A branch that is taken needs its variables: the reminder without PAY_BY.
    try expectRefused(try packInput(a, L, "reminder", "company-unpaid", null, &.{ .{ "LETTER_DATE", "2026-08-14" }, .{ "DAYS_OVERDUE", "14" } }), error.RenderFailed, "'PAY_BY' is not bound");
    // A Letter of Claim for an oral agreement needs its details.
    try expectRefused(try packInput(a, L, "final-demand", "individual-unpaid", "final-demand", &.{.{ "AGREEMENT_TYPE", "oral" }}), error.RenderFailed, "'ORAL_AGREEMENT' is not bound");
}

test "legend letter: template names the legend lacks are refused, in any branch" {
    const input =
        \\{"legend_toml": "[[var]]\nname = \"A\"\ntype = \"bool\"\nvalue = false\n",
        \\ "template": "Hello.{?A} {GHOST}{/}"}
    ;
    try expectRefused(input, error.TemplateInvalid, "'GHOST', which the legend does not declare");
    const frame =
        \\{"legend_toml": "[[var]]\nname = \"A\"\nvalue = \"x\"\n",
        \\ "template": "Hello {A}.", "letter": {"subject": "Re {B}"}}
    ;
    try expectRefused(frame, error.TemplateInvalid, "letter.subject uses 'B'");
    try expectRefused("{\"template\": \"x\"}", error.InvalidInput, "'legend_toml' is required");
    try expectRefused("[1]", error.InvalidInput, "JSON object");
    try expectRefused("{\"legend_toml\": \"[[var]\", \"template\": \"x\"}", error.LegendInvalid, "legend");
}

test "legend letter: describe lists variables, scenarios and template use" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = std.json.ObjectMap.empty;
    try root.put(a, "legend_toml", .{ .string = try readPack(a, "statutory-interest.toml") });
    try root.put(a, "template", .{ .string = try readPack(a, "statutory-interest.tpl.md") });
    const input = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});

    var diag = legend_letter.Diagnostic{};
    const out = try legend_letter.describe(testing.allocator, input, &diag);
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    const vars = parsed.object.get("variables").?.array.items;
    var saw_band = false;
    for (vars) |v| {
        if (std.mem.eql(u8, v.object.get("name").?.string, "COMPENSATION")) {
            try testing.expectEqualStrings("DEBT_BAND", v.object.get("by").?.string);
            try testing.expectEqualStrings("100", v.object.get("map").?.object.get("10000_or_more").?.string);
            saw_band = true;
        }
        try testing.expect(v.object.get("used_by_template") != null);
    }
    try testing.expect(saw_band);
    try testing.expect(parsed.object.get("scenarios").?.array.items.len >= 2);
    try testing.expectEqual(@as(usize, 0), parsed.object.get("template").?.object.get("undeclared").?.array.items.len);
}

test "legend letter: C exports return the PDF, or NULL with the reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try packInput(a, "debt-recovery.toml", "reminder", "individual-unpaid", "reminder", &.{});
    const good_z = try a.dupeZ(u8, good);
    var len: usize = 0;
    const pdf = ffi.zigpdf_generate_legend_letter(good_z, &len) orelse return error.TestUnexpectedNull;
    defer ffi.zigpdf_free(pdf, len);
    try testing.expect(std.mem.startsWith(u8, pdf[0..len], "%PDF-"));

    const bad = try packInput(a, "debt-recovery.toml", "reminder", "individual-unpaid", "reminder", &.{.{ "DEBTOR_TYPE", "trust" }});
    const bad_z = try a.dupeZ(u8, bad);
    try testing.expect(ffi.zigpdf_generate_legend_letter(bad_z, &len) == null);
    const msg = std.mem.span(ffi.zigpdf_get_error());
    try testing.expect(std.mem.startsWith(u8, msg, "Legend letter: bindings: 'trust' is not a value of enum 'DEBTOR_TYPE'"));

    // The plain letter export.
    const plain = "{\"company_name\":\"Harbourlight Joinery Ltd\",\"body_markdown\":\"Dear Sir or Madam,\\n\\nThank you.\"}";
    const letter_pdf = ffi.zigpdf_generate_letter(plain, &len) orelse return error.TestUnexpectedNull;
    defer ffi.zigpdf_free(letter_pdf, len);
    try testing.expect(std.mem.startsWith(u8, letter_pdf[0..len], "%PDF-"));

    // Text-only render.
    const text = ffi.zigpdf_legend_render_text(good_z, &len) orelse return error.TestUnexpectedNull;
    defer ffi.zigpdf_free(text, len);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text[0..len], .{});
    try testing.expectEqualStrings("Payment reminder: invoice INV-1043", parsed.object.get("letter").?.object.get("subject").?.string);
    try testing.expectEqualStrings("14 August 2026", parsed.object.get("letter").?.object.get("date").?.string);
}
