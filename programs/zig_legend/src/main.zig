//! zig_legend CLI: render templates from a legend.
//!
//!   zig_legend render    -l legend.toml -t letter.txt [-s NAME | --each-scenario] [--set K=V]...
//!   zig_legend sequence  -l legend.toml -t tpl.txt -n N [--seed S] [-s NAME] [--set K=V]...
//!   zig_legend matrix    -l legend.toml -t tpl.txt [--max N] [-s NAME] [--set K=V]...
//!   zig_legend profile   -l legend.toml -t brief.txt --out-dir DIR [-s NAME | --each-scenario] [--bind goal.json] [--set K=V|K=@file]...
//!   zig_legend check     -l legend.toml -t tpl.txt [-s NAME]
//!   zig_legend vars      -t tpl.txt [-l legend.toml]
//!   zig_legend scenarios -l legend.toml
//!
//! Output options for render/sequence/matrix: --json (array of variants),
//! --out-dir DIR (one file per variant), -o FILE (single variant), else stdout.
//! Exit codes: 0 ok, 1 runtime error, 2 usage, 3 check found problems.

const std = @import("std");
const Io = std.Io;
const lib = @import("zig_legend");
const KV = lib.KV;

const usage =
    \\zig_legend — typed {VARIABLE} substitution driven by a legend
    \\
    \\Usage:
    \\  zig_legend render    -l LEGEND -t TEMPLATE [-s SCENARIO | --each-scenario] [--set K=V]... [-o FILE | --out-dir DIR | --json]
    \\  zig_legend sequence  -l LEGEND -t TEMPLATE -n COUNT [--seed N] [-s SCENARIO] [--set K=V]... [--out-dir DIR | --json]
    \\  zig_legend matrix    -l LEGEND -t TEMPLATE [--max N] [-s SCENARIO] [--set K=V]... [--out-dir DIR | --json]
    \\  zig_legend profile   -l LEGEND -t BRIEF --out-dir DIR [-s SCENARIO | --each-scenario] [--bind FILE.json]... [--set K=V]...
    \\  zig_legend check     -l LEGEND -t TEMPLATE [-s SCENARIO]
    \\  zig_legend vars      -t TEMPLATE [-l LEGEND]
    \\  zig_legend scenarios -l LEGEND
    \\
    \\  render     bind from defaults, a scenario, and --set; print the text
    \\  sequence   COUNT variants; variant i takes values[i mod len] of each list variable
    \\             (--seed shuffles each list first, deterministically)
    \\  matrix     every combination of the list variables (default cap 1000, --max raises it)
    \\  profile    one agent brief per variant plus workflow.json (a `baton workflow run` spec)
    \\             and launch.json (`baton launch` argv per variant), from the legend's [launch]
    \\  check      report unknown placeholders, unbound required variables, unused legend
    \\             variables and type errors; exit 3 if anything is wrong
    \\  vars       list the placeholders a template reads
    \\
    \\  --set K=@FILE binds the file's contents (trailing newlines dropped).
    \\  --set SCENARIO:K=V applies to that scenario's variant only.
    \\  --bind FILE.json binds every legend variable whose `json` key is in the object,
    \\             so `baton work show <id> --json > goal.json` feeds a brief directly.
    \\
    \\Template syntax: {NAME}  {NAME|upper|title|lower|trim}  {DATE|long|us|uk}  {AMOUNT|plain|raw}
    \\                 {?VAR=value}…{:}…{/}  {?VAR!=value}…{/}  {?FLAG}…{/}  {! comment }  {{ }}
    \\A legend may set its own delimiters ([legend] open = "<<", close = ">>").
    \\
;

const Command = enum { render, sequence, matrix, profile, check, vars, scenarios };

/// `--set K=V` for every variant, or `--set SCENARIO:K=V` for one.
const ScopedSet = struct { scope: ?[]const u8, kv: KV };

const Opts = struct {
    cmd: Command,
    legend_path: ?[]const u8 = null,
    template_path: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    each_scenario: bool = false,
    sets: std.ArrayList(ScopedSet) = .empty,
    binds: std.ArrayList([]const u8) = .empty,
    count: ?usize = null,
    seed: ?u64 = null,
    max: usize = 1000,
    json: bool = false,
    out_file: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
};

const ArgError = error{ ShowedHelp, BadArgs, OutOfMemory, WriteFailed };

fn parseArgs(gpa: std.mem.Allocator, args: []const []const u8, stderr: *Io.Writer, stdout: *Io.Writer) ArgError!Opts {
    if (args.len < 2 or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help")) {
        try stdout.writeAll(usage);
        return error.ShowedHelp;
    }
    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        try stderr.print("unknown command '{s}'\n\n{s}", .{ args[1], usage });
        return error.BadArgs;
    };
    var o = Opts{ .cmd = cmd };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const needs_value = std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--legend") or
            std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--template") or
            std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--scenario") or
            std.mem.eql(u8, a, "--set") or std.mem.eql(u8, a, "--bind") or std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--count") or
            std.mem.eql(u8, a, "--seed") or std.mem.eql(u8, a, "--max") or
            std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out") or std.mem.eql(u8, a, "--out-dir");
        if (needs_value and i + 1 >= args.len) {
            try stderr.print("{s} needs a value\n", .{a});
            return error.BadArgs;
        }
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--legend")) {
            i += 1;
            o.legend_path = args[i];
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--template")) {
            i += 1;
            o.template_path = args[i];
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--scenario")) {
            i += 1;
            o.scenario = args[i];
        } else if (std.mem.eql(u8, a, "--each-scenario")) {
            o.each_scenario = true;
        } else if (std.mem.eql(u8, a, "--set")) {
            i += 1;
            const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse {
                try stderr.print("--set expects NAME=value or SCENARIO:NAME=value, got '{s}'\n", .{args[i]});
                return error.BadArgs;
            };
            var key = args[i][0..eq];
            var scope: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, key, ':')) |c| {
                scope = key[0..c];
                key = key[c + 1 ..];
            }
            try o.sets.append(gpa, .{ .scope = scope, .kv = .{ .key = key, .value = args[i][eq + 1 ..] } });
        } else if (std.mem.eql(u8, a, "--bind")) {
            i += 1;
            try o.binds.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--count")) {
            i += 1;
            o.count = std.fmt.parseInt(usize, args[i], 10) catch {
                try stderr.print("--count expects a positive integer\n", .{});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            o.seed = std.fmt.parseInt(u64, args[i], 10) catch {
                try stderr.print("--seed expects an unsigned integer\n", .{});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, a, "--max")) {
            i += 1;
            o.max = std.fmt.parseInt(usize, args[i], 10) catch {
                try stderr.print("--max expects a positive integer\n", .{});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out")) {
            i += 1;
            o.out_file = args[i];
        } else if (std.mem.eql(u8, a, "--out-dir")) {
            i += 1;
            o.out_dir = args[i];
        } else {
            try stderr.print("unknown option '{s}'\n\n{s}", .{ a, usage });
            return error.BadArgs;
        }
    }

    const needs_legend = cmd != .vars;
    const needs_template = cmd != .scenarios;
    if (needs_legend and o.legend_path == null) {
        try stderr.print("{s} needs -l LEGEND\n", .{args[1]});
        return error.BadArgs;
    }
    if (needs_template and o.template_path == null) {
        try stderr.print("{s} needs -t TEMPLATE\n", .{args[1]});
        return error.BadArgs;
    }
    if (cmd == .sequence and (o.count == null or o.count.? == 0)) {
        try stderr.print("sequence needs -n COUNT (at least 1)\n", .{});
        return error.BadArgs;
    }
    if (cmd == .profile and o.out_dir == null) {
        try stderr.print("profile needs --out-dir DIR\n", .{});
        return error.BadArgs;
    }
    if (o.scenario != null and o.each_scenario) {
        try stderr.print("-s and --each-scenario are exclusive\n", .{});
        return error.BadArgs;
    }
    var sinks: u8 = 0;
    if (o.json) sinks += 1;
    if (o.out_file != null) sinks += 1;
    if (o.out_dir != null) sinks += 1;
    if (sinks > 1) {
        try stderr.print("--json, -o and --out-dir are exclusive\n", .{});
        return error.BadArgs;
    }
    return o;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(gpa);
    const opts = parseArgs(gpa, args, stderr, stdout) catch |err| switch (err) {
        error.ShowedHelp => return 0,
        error.BadArgs => return 2,
        else => return err,
    };

    var diag = lib.Diag{};

    var legend: ?lib.Legend = null;
    if (opts.legend_path) |path| {
        const src = readFile(io, gpa, path, stderr) orelse return 1;
        legend = lib.Legend.load(gpa, src, &diag) catch {
            try stderr.print("{s}: {s}\n", .{ path, diag.text() });
            return 1;
        };
    }
    const delims = if (legend) |l| l.delims else lib.template.Delims{};

    var tpl: ?lib.Template = null;
    if (opts.template_path) |path| {
        const src = readFile(io, gpa, path, stderr) orelse return 1;
        tpl = lib.template.parse(gpa, src, delims, &diag) catch {
            try stderr.print("{s}:{d}: {s}\n", .{ path, diag.line, diag.text() });
            return 1;
        };
    }

    // Overrides: --bind files first, then --set (later wins), @file expanded.
    var overrides: std.ArrayList(ScopedSet) = .empty;
    if (opts.binds.items.len > 0 and legend == null) {
        try stderr.writeAll("--bind needs -l LEGEND\n");
        return 2;
    }
    for (opts.binds.items) |path| {
        const bytes = readFile(io, gpa, path, stderr) orelse return 1;
        const kvs = lib.render.bindingsFromJson(gpa, &legend.?, bytes, &diag) catch {
            try stderr.print("{s}: {s}\n", .{ path, diag.text() });
            return 1;
        };
        for (kvs) |kv| try overrides.append(gpa, .{ .scope = null, .kv = kv });
    }
    for (opts.sets.items) |ss| {
        if (ss.scope) |sc| {
            if (legend == null or legend.?.scenario(sc) == null) {
                try stderr.print("--set {s}:{s}: unknown scenario '{s}'\n", .{ sc, ss.kv.key, sc });
                return 1;
            }
        }
        if (ss.kv.value.len > 0 and ss.kv.value[0] == '@') {
            const bytes = readFile(io, gpa, ss.kv.value[1..], stderr) orelse return 1;
            try overrides.append(gpa, .{ .scope = ss.scope, .kv = .{ .key = ss.kv.key, .value = std.mem.trimEnd(u8, bytes, "\r\n") } });
        } else try overrides.append(gpa, ss);
    }
    var opts_bound = opts;
    opts_bound.sets = overrides;

    switch (opts.cmd) {
        .scenarios => {
            for (legend.?.scenarios) |s| {
                try stdout.print("{s}", .{s.name});
                for (s.set) |kv| try stdout.print("  {s}={s}", .{ kv.key, kv.value });
                try stdout.writeByte('\n');
            }
            return 0;
        },
        .vars => {
            const names = try tpl.?.variables(gpa);
            for (names) |n| {
                if (legend) |*l| {
                    if (l.find(n)) |spec| {
                        try stdout.print("{s}\t{s}", .{ n, spec.kind.label() });
                        if (spec.required) try stdout.writeAll("\trequired");
                        if (spec.default) |d| try stdout.print("\tdefault={s}", .{d});
                        if (spec.by) |by| try stdout.print("\tby={s}", .{by});
                        if (spec.values.len > 0) try stdout.print("\t{d} values", .{spec.values.len});
                        try stdout.writeByte('\n');
                    } else try stdout.print("{s}\tNOT IN LEGEND\n", .{n});
                } else try stdout.print("{s}\n", .{n});
            }
            return 0;
        },
        .check => return check(gpa, &legend.?, &tpl.?, opts_bound, stdout),
        .render, .sequence, .matrix => return produce(io, gpa, &legend.?, &tpl.?, opts_bound, stdout, stderr),
        .profile => return profile(io, gpa, &legend.?, &tpl.?, opts_bound, stdout, stderr),
    }
}

/// The overrides that apply to `scenario`: unscoped ones plus those scoped to it.
fn setsFor(gpa: std.mem.Allocator, sets: []const ScopedSet, scenario: ?[]const u8) ![]const KV {
    var out: std.ArrayList(KV) = .empty;
    for (sets) |ss| {
        if (ss.scope) |sc| {
            if (scenario == null or !std.mem.eql(u8, sc, scenario.?)) continue;
        }
        try out.append(gpa, ss.kv);
    }
    return out.toOwnedSlice(gpa);
}

fn readFile(io: Io, gpa: std.mem.Allocator, path: []const u8, stderr: *Io.Writer) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
        stderr.print("cannot read '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        return null;
    };
}

/// Lint: everything a render would trip over, all at once, plus unused
/// legend variables. Exit 3 when anything is wrong.
fn check(gpa: std.mem.Allocator, legend: *const lib.Legend, tpl: *const lib.Template, opts: Opts, out: *Io.Writer) !u8 {
    var problems: usize = 0;
    const used = try tpl.variables(gpa);

    for (used) |n| if (legend.find(n) == null) {
        try out.print("error: placeholder '{s}' is not in the legend\n", .{n});
        problems += 1;
    };
    // [launch] strings read variables too.
    var launch_used: std.ArrayList([]const u8) = .empty;
    if (legend.launch) |l| {
        var strings: std.ArrayList([]const u8) = .empty;
        try strings.appendSlice(gpa, &.{ l.cwd, l.provider, l.model, l.runner });
        try strings.appendSlice(gpa, l.flags);
        for (strings.items) |src| {
            if (std.mem.indexOf(u8, src, legend.delims.open) == null) continue;
            var diag = lib.Diag{};
            var t = lib.template.parse(gpa, src, legend.delims, &diag) catch {
                try out.print("error: [launch] '{s}': {s}\n", .{ src, diag.text() });
                problems += 1;
                continue;
            };
            defer t.deinit();
            try launch_used.appendSlice(gpa, try t.variables(gpa));
        }
    }
    for (legend.vars) |v| {
        var hit = false;
        for (used) |n| if (std.mem.eql(u8, n, v.name)) {
            hit = true;
        };
        for (launch_used.items) |n| if (std.mem.eql(u8, n, v.name)) {
            hit = true;
        };
        if (!hit) try out.print("note: legend variable '{s}' is never used by the template\n", .{v.name});
    }

    // Resolve for the chosen scenario, or every scenario, or none.
    var names: std.ArrayList(?[]const u8) = .empty;
    if (opts.scenario) |s| {
        try names.append(gpa, s);
    } else if (legend.scenarios.len > 0) {
        for (legend.scenarios) |s| try names.append(gpa, s.name);
    } else try names.append(gpa, null);

    for (names.items) |sn| {
        var diag = lib.Diag{};
        var b = lib.render.resolve(gpa, legend, sn, &.{}, try setsFor(gpa, opts.sets.items, sn), &diag) catch {
            try out.print("error [{s}]: {s}\n", .{ sn orelse "defaults", diag.text() });
            problems += 1;
            continue;
        };
        defer b.deinit(gpa);
        var sink = Io.Writer.Discarding.init(&.{});
        lib.render.render(gpa, tpl, legend, &b, &sink.writer, &diag) catch {
            try out.print("error [{s}] line {d}: {s}\n", .{ sn orelse "defaults", diag.line, diag.text() });
            problems += 1;
        };
    }
    if (problems == 0) {
        try out.print("ok: {d} placeholders, {d} scenarios checked\n", .{ used.len, names.items.len });
        return 0;
    }
    try out.print("{d} problem(s)\n", .{problems});
    return 3;
}

const Variant = struct {
    name: []const u8,
    bindings: lib.Bindings,
    text: []const u8,
};

fn produce(io: Io, gpa: std.mem.Allocator, legend: *const lib.Legend, tpl: *const lib.Template, opts: Opts, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    var variants: std.ArrayList(Variant) = .empty;
    var diag = lib.Diag{};

    switch (opts.cmd) {
        .render => {
            if (opts.each_scenario) {
                if (legend.scenarios.len == 0) {
                    try stderr.writeAll("--each-scenario: the legend has no scenarios\n");
                    return 1;
                }
                for (legend.scenarios) |s| {
                    try variants.append(gpa, try makeVariant(gpa, legend, tpl, s.name, s.name, &.{}, try setsFor(gpa, opts.sets.items, s.name), stderr) orelse return 1);
                }
            } else {
                const name = opts.scenario orelse "render";
                try variants.append(gpa, try makeVariant(gpa, legend, tpl, name, opts.scenario, &.{}, try setsFor(gpa, opts.sets.items, opts.scenario), stderr) orelse return 1);
            }
        },
        .sequence, .matrix => {
            // Variables pinned by the scenario or --set do not vary.
            const plan_sets = try setsFor(gpa, opts.sets.items, opts.scenario);
            var pinned: std.ArrayList([]const u8) = .empty;
            for (plan_sets) |kv| try pinned.append(gpa, kv.key);
            if (opts.scenario) |sn| {
                const s = legend.scenario(sn) orelse {
                    try stderr.print("unknown scenario '{s}'\n", .{sn});
                    return 1;
                };
                for (s.set) |kv| try pinned.append(gpa, kv.key);
            }
            const vars = try lib.plan.participants(gpa, legend, pinned.items);
            var plan = (if (opts.cmd == .sequence)
                lib.plan.sequence(gpa, vars, opts.count.?, opts.seed)
            else
                lib.plan.matrix(gpa, vars, opts.max)) catch |err| switch (err) {
                error.NoListVariables => {
                    try stderr.writeAll("no list variables to vary: give some variables a `values` list (and do not pin them all)\n");
                    return 1;
                },
                error.TooManyVariants => {
                    try stderr.print("matrix exceeds --max {d} variants\n", .{opts.max});
                    return 1;
                },
                error.OutOfMemory => return err,
            };
            var i: usize = 0;
            while (i < plan.count) : (i += 1) {
                const picks = try plan.pick(gpa, i);
                const name = try std.fmt.allocPrint(gpa, "{d:0>4}", .{i + 1});
                try variants.append(gpa, try makeVariant(gpa, legend, tpl, name, opts.scenario, picks, plan_sets, stderr) orelse return 1);
            }
        },
        else => unreachable,
    }
    _ = &diag;

    if (opts.json) {
        try writeJson(gpa, variants.items, stdout);
        return 0;
    }
    if (opts.out_dir) |dir| {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(io, dir) catch |err| {
            try stderr.print("cannot create '{s}': {s}\n", .{ dir, @errorName(err) });
            return 1;
        };
        var d = cwd.openDir(io, dir, .{}) catch |err| {
            try stderr.print("cannot open '{s}': {s}\n", .{ dir, @errorName(err) });
            return 1;
        };
        defer d.close(io);
        for (variants.items) |v| {
            const fname = try std.fmt.allocPrint(gpa, "{s}.txt", .{v.name});
            d.writeFile(io, .{ .sub_path = fname, .data = v.text }) catch |err| {
                try stderr.print("cannot write '{s}/{s}': {s}\n", .{ dir, fname, @errorName(err) });
                return 1;
            };
        }
        try stderr.print("wrote {d} file(s) to {s}\n", .{ variants.items.len, dir });
        return 0;
    }
    if (opts.out_file) |path| {
        if (variants.items.len != 1) {
            try stderr.print("-o takes one variant; this run produced {d}. Use --out-dir or --json.\n", .{variants.items.len});
            return 1;
        }
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = variants.items[0].text }) catch |err| {
            try stderr.print("cannot write '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
        return 0;
    }
    if (variants.items.len == 1) {
        try stdout.writeAll(variants.items[0].text);
        return 0;
    }
    for (variants.items) |v| {
        try stdout.print("===== {s}", .{v.name});
        for (v.bindings.map.keys(), v.bindings.map.values()) |k, val| {
            if (legend.find(k)) |spec| if (spec.values.len > 0) try stdout.print("  {s}={s}", .{ k, val });
        }
        try stdout.writeAll(" =====\n");
        try stdout.writeAll(v.text);
        if (v.text.len == 0 or v.text[v.text.len - 1] != '\n') try stdout.writeByte('\n');
    }
    return 0;
}

fn makeVariant(
    gpa: std.mem.Allocator,
    legend: *const lib.Legend,
    tpl: *const lib.Template,
    name: []const u8,
    scenario: ?[]const u8,
    picks: []const KV,
    sets: []const KV,
    stderr: *Io.Writer,
) !?Variant {
    var diag = lib.Diag{};
    const b = lib.render.resolve(gpa, legend, scenario, picks, sets, &diag) catch {
        try stderr.print("{s}: {s}\n", .{ name, diag.text() });
        return null;
    };
    const text = lib.render.renderAlloc(gpa, tpl, legend, &b, &diag) catch {
        try stderr.print("{s}: line {d}: {s}\n", .{ name, diag.line, diag.text() });
        return null;
    };
    return .{ .name = name, .bindings = b, .text = text };
}

/// [{"variant": "...", "bindings": {...}, "text": "..."}] via std.json, so
/// values with quotes or newlines are escaped correctly.
fn writeJson(gpa: std.mem.Allocator, variants: []const Variant, out: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try s.beginArray();
    for (variants) |v| {
        try s.beginObject();
        try s.objectField("variant");
        try s.write(v.name);
        try s.objectField("bindings");
        try s.beginObject();
        const keys = try v.bindings.sortedKeys(gpa);
        for (keys) |k| {
            try s.objectField(k);
            try s.write(v.bindings.get(k).?);
        }
        try s.endObject();
        try s.objectField("text");
        try s.write(v.text);
        try s.endObject();
    }
    try s.endArray();
    try out.writeByte('\n');
}

// ---------------------------------------------------------------------------
// profile: briefs + launch specs
// ---------------------------------------------------------------------------

const LaunchVariant = struct {
    name: []const u8,
    brief_path: []const u8,
    text: []const u8,
    cwd: []const u8,
    provider: []const u8,
    model: []const u8,
    runner: []const u8,
    flags: []const []const u8,
};

/// Render each variant's brief to DIR/<name>.md, then write DIR/workflow.json
/// (a `baton workflow run` spec whose per-target assignment is the whole
/// rendered brief) and DIR/launch.json (`baton launch` argv per variant), and
/// print those command lines.
fn profile(io: Io, gpa: std.mem.Allocator, legend: *const lib.Legend, tpl: *const lib.Template, opts: Opts, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const launch = legend.launch orelse {
        try stderr.writeAll("profile needs a [launch] table in the legend (cwd at least)\n");
        return 1;
    };
    const dir = opts.out_dir.?;

    var names: std.ArrayList(struct { name: []const u8, scenario: ?[]const u8 }) = .empty;
    if (opts.each_scenario) {
        if (legend.scenarios.len == 0) {
            try stderr.writeAll("--each-scenario: the legend has no scenarios\n");
            return 1;
        }
        for (legend.scenarios) |s| try names.append(gpa, .{ .name = s.name, .scenario = s.name });
    } else {
        try names.append(gpa, .{ .name = opts.scenario orelse "agent", .scenario = opts.scenario });
    }

    var variants: std.ArrayList(LaunchVariant) = .empty;
    for (names.items) |n| {
        var diag = lib.Diag{};
        const b = lib.render.resolve(gpa, legend, n.scenario, &.{}, try setsFor(gpa, opts.sets.items, n.scenario), &diag) catch {
            try stderr.print("{s}: {s}\n", .{ n.name, diag.text() });
            return 1;
        };
        const text = lib.render.renderAlloc(gpa, tpl, legend, &b, &diag) catch {
            try stderr.print("{s}: line {d}: {s}\n", .{ n.name, diag.line, diag.text() });
            return 1;
        };
        const flags = try gpa.alloc([]const u8, launch.flags.len);
        for (launch.flags, 0..) |f, i| flags[i] = renderString(gpa, legend, &b, f, "launch.flags", stderr) orelse return 1;
        try variants.append(gpa, .{
            .name = n.name,
            .brief_path = try std.fmt.allocPrint(gpa, "{s}/{s}.md", .{ dir, n.name }),
            .text = text,
            .cwd = renderString(gpa, legend, &b, launch.cwd, "launch.cwd", stderr) orelse return 1,
            .provider = renderString(gpa, legend, &b, launch.provider, "launch.provider", stderr) orelse return 1,
            .model = renderString(gpa, legend, &b, launch.model, "launch.model", stderr) orelse return 1,
            .runner = renderString(gpa, legend, &b, launch.runner, "launch.runner", stderr) orelse return 1,
            .flags = flags,
        });
    }

    const cwd_dir = Io.Dir.cwd();
    cwd_dir.createDirPath(io, dir) catch |err| {
        try stderr.print("cannot create '{s}': {s}\n", .{ dir, @errorName(err) });
        return 1;
    };
    var d = cwd_dir.openDir(io, dir, .{}) catch |err| {
        try stderr.print("cannot open '{s}': {s}\n", .{ dir, @errorName(err) });
        return 1;
    };
    defer d.close(io);
    for (variants.items) |v| {
        const fname = try std.fmt.allocPrint(gpa, "{s}.md", .{v.name});
        d.writeFile(io, .{ .sub_path = fname, .data = v.text }) catch |err| {
            try stderr.print("cannot write '{s}': {s}\n", .{ v.brief_path, @errorName(err) });
            return 1;
        };
    }

    // workflow.json: flags are global in a baton spec, so every variant must
    // agree on them; the brief itself is the per-target assignment.
    const first = variants.items[0];
    const global_flags = try launchFlags(gpa, first);
    for (variants.items[1..]) |v| {
        const f = try launchFlags(gpa, v);
        if (!sameStrings(global_flags, f)) {
            try stderr.print("workflow.json: variant '{s}' launches with different provider/model/runner/flags than '{s}'; a workflow spec has one flag set. launch.json still lists each variant.\n", .{ v.name, first.name });
            return 1;
        }
    }
    const shared_path = try std.fmt.allocPrint(gpa, "{s}/shared.md", .{dir});
    d.writeFile(io, .{ .sub_path = "shared.md", .data = "" }) catch |err| {
        try stderr.print("cannot write '{s}': {s}\n", .{ shared_path, @errorName(err) });
        return 1;
    };
    {
        var w = Io.Writer.Allocating.init(gpa);
        var s: std.json.Stringify = .{ .writer = &w.writer, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("name");
        try s.write(if (legend.name.len > 0) legend.name else "zig_legend profile");
        try s.objectField("brief_file");
        try s.write(shared_path);
        try s.objectField("assignment");
        try s.write("{brief}");
        try s.objectField("flags");
        try s.write(global_flags);
        try s.objectField("concurrency");
        try s.write(launch.concurrency);
        try s.objectField("targets");
        try s.beginArray();
        for (variants.items) |v| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(v.name);
            try s.objectField("cwd");
            try s.write(v.cwd);
            try s.objectField("vars");
            try s.beginObject();
            try s.objectField("brief");
            try s.write(v.text);
            try s.endObject();
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try w.writer.writeByte('\n');
        d.writeFile(io, .{ .sub_path = "workflow.json", .data = w.written() }) catch |err| {
            try stderr.print("cannot write '{s}/workflow.json': {s}\n", .{ dir, @errorName(err) });
            return 1;
        };
    }
    {
        var w = Io.Writer.Allocating.init(gpa);
        var s: std.json.Stringify = .{ .writer = &w.writer, .options = .{ .whitespace = .indent_2 } };
        try s.beginArray();
        for (variants.items) |v| {
            const argv = try launchArgv(gpa, v);
            try s.beginObject();
            try s.objectField("variant");
            try s.write(v.name);
            try s.objectField("brief_file");
            try s.write(v.brief_path);
            try s.objectField("argv");
            try s.write(argv);
            try s.endObject();
        }
        try s.endArray();
        try w.writer.writeByte('\n');
        d.writeFile(io, .{ .sub_path = "launch.json", .data = w.written() }) catch |err| {
            try stderr.print("cannot write '{s}/launch.json': {s}\n", .{ dir, @errorName(err) });
            return 1;
        };
    }

    for (variants.items) |v| {
        const argv = try launchArgv(gpa, v);
        for (argv, 0..) |a, i| {
            if (i != 0) try stdout.writeByte(' ');
            try writeShellQuoted(stdout, a);
        }
        try stdout.writeByte('\n');
    }
    try stderr.print("wrote {d} brief(s), workflow.json and launch.json to {s}\n", .{ variants.items.len, dir });
    return 0;
}

/// Render a [launch] string that may hold placeholders.
fn renderString(gpa: std.mem.Allocator, legend: *const lib.Legend, b: *const lib.Bindings, src: []const u8, what: []const u8, stderr: *Io.Writer) ?[]const u8 {
    if (std.mem.indexOf(u8, src, legend.delims.open) == null) return src;
    var diag = lib.Diag{};
    var t = lib.template.parse(gpa, src, legend.delims, &diag) catch {
        stderr.print("{s}: {s}\n", .{ what, diag.text() }) catch {};
        return null;
    };
    defer t.deinit();
    return lib.render.renderAlloc(gpa, &t, legend, b, &diag) catch {
        stderr.print("{s}: {s}\n", .{ what, diag.text() }) catch {};
        return null;
    };
}

/// The flags after `--cwd D --brief-file F`: provider, model, runner, then
/// the legend's own flags.
fn launchFlags(gpa: std.mem.Allocator, v: LaunchVariant) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (v.provider.len > 0) try out.appendSlice(gpa, &.{ "--provider", v.provider });
    if (v.model.len > 0) try out.appendSlice(gpa, &.{ "--model", v.model });
    if (v.runner.len > 0) try out.appendSlice(gpa, &.{ "--runner", v.runner });
    try out.appendSlice(gpa, v.flags);
    return out.toOwnedSlice(gpa);
}

fn launchArgv(gpa: std.mem.Allocator, v: LaunchVariant) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(gpa, &.{ "baton", "launch", "--cwd", v.cwd, "--brief-file", v.brief_path });
    try out.appendSlice(gpa, try launchFlags(gpa, v));
    return out.toOwnedSlice(gpa);
}

fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// POSIX single-quoting; safe for any bytes.
fn writeShellQuoted(w: *Io.Writer, s: []const u8) !void {
    var plain = s.len > 0;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or c == '-' or c == '=' or c == ':' or c == '~')) {
            plain = false;
            break;
        }
    }
    if (plain) return w.writeAll(s);
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}
