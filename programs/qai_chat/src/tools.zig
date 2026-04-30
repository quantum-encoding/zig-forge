//! Read-only tools for the qai_chat agent loop.
//!
//! These run locally on the user's machine. The server (or direct provider)
//! never sees the tool output — only the model's tool_use intent and the
//! result we choose to send back. Three tools for v1:
//!
//!   read_file(path)              — fetch a file (truncated to a cap)
//!   ls(path)                     — list a directory
//!   grep(pattern, path, glob)    — recursive substring search
//!
//! All tools are read-only, so we auto-approve and just print a one-line
//! "[tool] ..." trace. Write/exec tools will need a confirmation prompt;
//! that's the next layer.

const std = @import("std");

/// JSON schema descriptions sent to the model.
pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    /// Writable tools require user confirmation before execution. The agent
    /// loop is responsible for prompting; this flag just classifies the tool.
    is_writable: bool = false,
};

pub const all_tools: [6]Spec = .{
    .{
        .name = "read_file",
        .description = "Read the contents of a file. Returns up to 16 KB of text (longer files are truncated and noted). Use this to inspect source files, configs, READMEs, etc.",
        .input_schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file, relative to the current working directory or absolute."}},"required":["path"]}
        ,
    },
    .{
        .name = "ls",
        .description = "List entries in a directory. Returns one entry per line — directories are marked with a trailing slash, files with their byte size. Caps at 200 entries.",
        .input_schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Directory path. Defaults to the current directory.","default":"."}}}
        ,
    },
    .{
        .name = "grep",
        .description = "Recursively search for a literal substring across files. Returns matching lines as 'path:line: <text>'. Caps at 100 matches. Use this to locate identifiers, strings, or keywords.",
        .input_schema =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Literal substring to find (case-sensitive)."},"path":{"type":"string","description":"Root directory to search. Defaults to '.'.","default":"."},"glob":{"type":"string","description":"Optional file-name filter, e.g. '*.zig'. Default is no filter."}},"required":["pattern"]}
        ,
    },
    .{
        .name = "write_file",
        .description = "Create or overwrite a file with the given contents. Use sparingly — prefer edit_file when modifying existing content. The user will be prompted to approve each write.",
        .input_schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Destination path."},"content":{"type":"string","description":"Full file contents to write."}},"required":["path","content"]}
        ,
        .is_writable = true,
    },
    .{
        .name = "edit_file",
        .description = "Edit a file by replacing exactly one occurrence of old_string with new_string. Fails if old_string is not found or is not unique. Include enough surrounding context in old_string to make it unique. Preserve indentation exactly.",
        .input_schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File to edit."},"old_string":{"type":"string","description":"Text to find — must be unique in the file."},"new_string":{"type":"string","description":"Replacement text."}},"required":["path","old_string","new_string"]}
        ,
        .is_writable = true,
    },
    .{
        .name = "bash",
        .description = "Run a shell command via /bin/sh -c. Returns combined stdout+stderr (capped at 16 KB) and the exit code. The user will be prompted to approve each command. Use for builds, tests, git, or other side-effecting operations.",
        .input_schema =
        \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute."}},"required":["command"]}
        ,
        .is_writable = true,
    },
};

/// Look up a Spec by name. Returns null for unknown tools — useful for
/// classifying a tool call (writable vs read-only) before execution.
pub fn specByName(name: []const u8) ?Spec {
    for (all_tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Caps so a hostile or careless tool call can't blow up our terminal or context budget.
const MAX_FILE_BYTES: u64 = 16 * 1024;
const MAX_LS_ENTRIES: usize = 200;
const MAX_GREP_MATCHES: usize = 100;
const MAX_GREP_FILES: usize = 5_000;
const MAX_GREP_FILE_BYTES: usize = 1024 * 1024;
const MAX_OUTPUT_BYTES: usize = 64 * 1024;
const MAX_WRITE_BYTES: usize = 1024 * 1024;
const MAX_BASH_OUTPUT: usize = 16 * 1024;

pub const ExecError = error{
    UnknownTool,
    InvalidArguments,
    OutOfMemory,
} || std.Io.Cancelable || std.Io.UnexpectedError;

/// Execute a tool by name with its JSON-encoded arguments. Returns a freshly
/// allocated string (the tool result, plain text). Caller owns.
///
/// On any user-facing failure we still return Ok with an error message — the
/// model is allowed to see "permission denied", "file not found", etc. so it
/// can recover. We only return ExecError for invariant violations.
pub fn execute(
    io: std.Io,
    gpa: std.mem.Allocator,
    name: []const u8,
    args_json: []const u8,
) ![]u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        gpa,
        args_json,
        .{},
    ) catch return std.fmt.allocPrint(gpa, "error: tool args were not valid JSON: {s}", .{args_json});
    defer parsed.deinit();
    const args = parsed.value;

    if (std.mem.eql(u8, name, "read_file")) {
        const path = try requireString(gpa, args, "path");
        return readFile(io, gpa, path);
    } else if (std.mem.eql(u8, name, "ls")) {
        const path = optionalString(args, "path") orelse ".";
        return listDir(io, gpa, path);
    } else if (std.mem.eql(u8, name, "grep")) {
        const pattern = try requireString(gpa, args, "pattern");
        const path = optionalString(args, "path") orelse ".";
        const glob = optionalString(args, "glob");
        return grep(io, gpa, pattern, path, glob);
    } else if (std.mem.eql(u8, name, "write_file")) {
        const path = try requireString(gpa, args, "path");
        const content = try requireString(gpa, args, "content");
        return writeFile(io, gpa, path, content);
    } else if (std.mem.eql(u8, name, "edit_file")) {
        const path = try requireString(gpa, args, "path");
        const old_str = try requireString(gpa, args, "old_string");
        const new_str = try requireString(gpa, args, "new_string");
        return editFile(io, gpa, path, old_str, new_str);
    } else if (std.mem.eql(u8, name, "bash")) {
        const command = try requireString(gpa, args, "command");
        return bash(io, gpa, command);
    }

    return std.fmt.allocPrint(gpa, "error: unknown tool '{s}'", .{name});
}

fn requireString(gpa: std.mem.Allocator, args: std.json.Value, key: []const u8) ![]const u8 {
    if (args != .object) return std.fmt.allocPrint(gpa, "error: tool args must be a JSON object", .{}) catch return error.OutOfMemory;
    const v = args.object.get(key) orelse {
        // Caller will treat the returned slice as the result; switch to a synthetic error.
        return error.InvalidArguments;
    };
    if (v != .string) return error.InvalidArguments;
    return v.string;
}

fn optionalString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    if (v.string.len == 0) return null;
    return v.string;
}

// ─── read_file ──────────────────────────────────────────────────────────

fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(MAX_FILE_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return std.fmt.allocPrint(gpa, "error: file not found: {s}", .{path}),
        error.AccessDenied => return std.fmt.allocPrint(gpa, "error: access denied: {s}", .{path}),
        error.IsDir => return std.fmt.allocPrint(gpa, "error: '{s}' is a directory — use the ls tool", .{path}),
        error.StreamTooLong => {
            const truncated = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(MAX_FILE_BYTES - 256));
            defer gpa.free(truncated);
            return std.fmt.allocPrint(gpa, "{s}\n[truncated at {d} bytes — file is larger]", .{ truncated, MAX_FILE_BYTES - 256 });
        },
        else => return std.fmt.allocPrint(gpa, "error: read failed ({s}): {s}", .{ @errorName(err), path }),
    };
    return data;
}

// ─── ls ─────────────────────────────────────────────────────────────────

fn listDir(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return std.fmt.allocPrint(gpa, "error: directory not found: {s}", .{path}),
        error.NotDir => return std.fmt.allocPrint(gpa, "error: '{s}' is not a directory", .{path}),
        error.AccessDenied => return std.fmt.allocPrint(gpa, "error: access denied: {s}", .{path}),
        else => return std.fmt.allocPrint(gpa, "error: open failed ({s}): {s}", .{ @errorName(err), path }),
    };
    defer dir.close(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.print(gpa, "{s}/\n", .{std.mem.trimEnd(u8, path, "/")});

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        if (count >= MAX_LS_ENTRIES) {
            try out.print(gpa, "[...truncated at {d} entries]\n", .{MAX_LS_ENTRIES});
            break;
        }
        switch (entry.kind) {
            .directory => try out.print(gpa, "  [d] {s}/\n", .{entry.name}),
            .file => {
                if (dir.statFile(io, entry.name, .{})) |stat| {
                    try out.print(gpa, "  [f] {s} ({d} bytes)\n", .{ entry.name, stat.size });
                } else |_| {
                    try out.print(gpa, "  [f] {s}\n", .{entry.name});
                }
            },
            .sym_link => try out.print(gpa, "  [l] {s}\n", .{entry.name}),
            else => try out.print(gpa, "  [?] {s}\n", .{entry.name}),
        }
        count += 1;
    }

    return out.toOwnedSlice(gpa);
}

// ─── grep ───────────────────────────────────────────────────────────────

const GrepCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    pattern: []const u8,
    glob: ?[]const u8,
    out: *std.ArrayList(u8),
    matches: usize = 0,
    files_visited: usize = 0,
};

fn grep(
    io: std.Io,
    gpa: std.mem.Allocator,
    pattern: []const u8,
    root: []const u8,
    glob: ?[]const u8,
) ![]u8 {
    if (pattern.len == 0) return try gpa.dupe(u8, "error: empty pattern");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var ctx = GrepCtx{
        .io = io,
        .gpa = gpa,
        .pattern = pattern,
        .glob = glob,
        .out = &out,
    };

    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return std.fmt.allocPrint(gpa, "error: directory not found: {s}", .{root}),
        error.NotDir => {
            // Single file grep.
            try grepFile(&ctx, root, root);
            if (ctx.matches == 0) try out.print(gpa, "(no matches)\n", .{});
            return out.toOwnedSlice(gpa);
        },
        error.AccessDenied => return std.fmt.allocPrint(gpa, "error: access denied: {s}", .{root}),
        else => return std.fmt.allocPrint(gpa, "error: open failed ({s}): {s}", .{ @errorName(err), root }),
    };
    defer dir.close(io);

    grepWalk(&ctx, &dir, root) catch {};

    if (ctx.matches >= MAX_GREP_MATCHES) try out.print(gpa, "[...stopped at {d} matches]\n", .{MAX_GREP_MATCHES});
    if (ctx.matches == 0) try out.print(gpa, "(no matches)\n", .{});

    return out.toOwnedSlice(gpa);
}

fn grepWalk(ctx: *GrepCtx, dir: *std.Io.Dir, prefix: []const u8) !void {
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (ctx.matches >= MAX_GREP_MATCHES) return;
        if (ctx.files_visited >= MAX_GREP_FILES) return;
        if (skipName(entry.name)) continue;

        const child_path = try std.fs.path.join(ctx.gpa, &.{ prefix, entry.name });
        defer ctx.gpa.free(child_path);

        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(ctx.io);
                try grepWalk(ctx, &sub, child_path);
            },
            .file => {
                if (ctx.glob) |g| if (!matchGlob(g, entry.name)) continue;
                ctx.files_visited += 1;
                grepFile(ctx, child_path, child_path) catch {};
            },
            else => {},
        }
    }
}

fn grepFile(ctx: *GrepCtx, display_path: []const u8, fs_path: []const u8) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, fs_path, ctx.gpa, .limited(MAX_GREP_FILE_BYTES)) catch return;
    defer ctx.gpa.free(data);

    var line_no: usize = 1;
    var line_start: usize = 0;
    for (data, 0..) |c, i| {
        if (c == '\n') {
            const line = data[line_start..i];
            try maybeEmit(ctx, display_path, line_no, line);
            if (ctx.matches >= MAX_GREP_MATCHES) return;
            line_no += 1;
            line_start = i + 1;
        }
    }
    if (line_start < data.len) {
        try maybeEmit(ctx, display_path, line_no, data[line_start..]);
    }
}

fn maybeEmit(ctx: *GrepCtx, path: []const u8, line_no: usize, line: []const u8) !void {
    if (std.mem.indexOf(u8, line, ctx.pattern) == null) return;
    if (ctx.out.items.len >= MAX_OUTPUT_BYTES) {
        ctx.matches = MAX_GREP_MATCHES;
        return;
    }
    const trimmed = if (line.len > 240) line[0..240] else line;
    try ctx.out.print(ctx.gpa, "{s}:{d}: {s}\n", .{ path, line_no, trimmed });
    ctx.matches += 1;
}

/// Skip noisy names that explode walk time without ever being interesting.
fn skipName(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '.') {
        if (std.mem.eql(u8, name, ".")) return true;
        if (std.mem.eql(u8, name, "..")) return true;
        if (std.mem.eql(u8, name, ".git")) return true;
        if (std.mem.eql(u8, name, ".zig-cache")) return true;
    }
    if (std.mem.eql(u8, name, "node_modules")) return true;
    if (std.mem.eql(u8, name, "zig-out")) return true;
    if (std.mem.eql(u8, name, "target")) return true;
    return false;
}

/// Tiny glob matcher: supports leading/trailing `*` only (e.g. "*.zig", "main*").
fn matchGlob(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return true;
    if (std.mem.eql(u8, pattern, "*")) return true;

    const has_lead = pattern[0] == '*';
    const has_trail = pattern[pattern.len - 1] == '*';

    const core_start: usize = if (has_lead) 1 else 0;
    const core_end: usize = if (has_trail) pattern.len - 1 else pattern.len;
    if (core_start > core_end) return true;
    const core = pattern[core_start..core_end];

    if (has_lead and has_trail) return std.mem.indexOf(u8, name, core) != null;
    if (has_lead) return std.mem.endsWith(u8, name, core);
    if (has_trail) return std.mem.startsWith(u8, name, core);
    return std.mem.eql(u8, pattern, name);
}

test "matchGlob" {
    try std.testing.expect(matchGlob("*.zig", "main.zig"));
    try std.testing.expect(matchGlob("*.zig", "config.zig"));
    try std.testing.expect(!matchGlob("*.zig", "main.zon"));
    try std.testing.expect(matchGlob("main*", "main.zig"));
    try std.testing.expect(matchGlob("*", "anything"));
    try std.testing.expect(matchGlob("*main*", "src/main.zig"));
}

// ─── write_file ─────────────────────────────────────────────────────────

fn writeFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, content: []const u8) ![]u8 {
    if (content.len > MAX_WRITE_BYTES) {
        return std.fmt.allocPrint(gpa, "error: refusing to write {d} bytes — limit is {d}", .{ content.len, MAX_WRITE_BYTES });
    }

    // Did the file exist before this write? Used in the response text so the
    // model knows whether it created or overwrote.
    const existed = blk: {
        std.Io.Dir.cwd().access(io, path, .{}) catch break :blk false;
        break :blk true;
    };

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content }) catch |err| switch (err) {
        error.AccessDenied => return std.fmt.allocPrint(gpa, "error: access denied: {s}", .{path}),
        error.IsDir => return std.fmt.allocPrint(gpa, "error: '{s}' is a directory", .{path}),
        error.FileNotFound => return std.fmt.allocPrint(gpa, "error: parent directory of '{s}' does not exist", .{path}),
        error.NoSpaceLeft => return std.fmt.allocPrint(gpa, "error: no space left writing '{s}'", .{path}),
        else => return std.fmt.allocPrint(gpa, "error: write failed ({s}): {s}", .{ @errorName(err), path }),
    };

    return std.fmt.allocPrint(gpa, "{s} {d} bytes to {s}", .{
        if (existed) "Overwrote" else "Created",
        content.len,
        path,
    });
}

// ─── edit_file ──────────────────────────────────────────────────────────

fn editFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    old_string: []const u8,
    new_string: []const u8,
) ![]u8 {
    if (old_string.len == 0) return try gpa.dupe(u8, "error: old_string must not be empty");

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(MAX_WRITE_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return std.fmt.allocPrint(gpa, "error: file not found: {s}", .{path}),
        error.AccessDenied => return std.fmt.allocPrint(gpa, "error: access denied: {s}", .{path}),
        error.IsDir => return std.fmt.allocPrint(gpa, "error: '{s}' is a directory", .{path}),
        error.StreamTooLong => return std.fmt.allocPrint(gpa, "error: file '{s}' exceeds {d} byte edit limit", .{ path, MAX_WRITE_BYTES }),
        else => return std.fmt.allocPrint(gpa, "error: read failed ({s}): {s}", .{ @errorName(err), path }),
    };
    defer gpa.free(data);

    // Uniqueness: refuse the edit if the substring is missing or appears more
    // than once. Forces the model to include enough surrounding context.
    const first = std.mem.indexOf(u8, data, old_string) orelse {
        return std.fmt.allocPrint(gpa, "error: old_string not found in {s}", .{path});
    };
    if (std.mem.indexOfPos(u8, data, first + 1, old_string) != null) {
        return std.fmt.allocPrint(gpa, "error: old_string appears more than once in {s} — include more context to make it unique", .{path});
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, data[0..first]);
    try out.appendSlice(gpa, new_string);
    try out.appendSlice(gpa, data[first + old_string.len ..]);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch |err| {
        return std.fmt.allocPrint(gpa, "error: write failed ({s}): {s}", .{ @errorName(err), path });
    };

    const removed = old_string.len;
    const added = new_string.len;
    const line_no = countLinesBefore(data, first);
    return std.fmt.allocPrint(
        gpa,
        "Edited {s} at line {d}: -{d} +{d} bytes",
        .{ path, line_no, removed, added },
    );
}

fn countLinesBefore(data: []const u8, byte_offset: usize) usize {
    var n: usize = 1;
    for (data[0..byte_offset]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

// ─── bash ───────────────────────────────────────────────────────────────

fn bash(io: std.Io, gpa: std.mem.Allocator, command: []const u8) ![]u8 {
    if (command.len == 0) return try gpa.dupe(u8, "error: empty command");

    const argv = [_][]const u8{ "/bin/sh", "-c", command };

    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(MAX_BASH_OUTPUT),
        .stderr_limit = .limited(MAX_BASH_OUTPUT),
    }) catch |err| switch (err) {
        error.StreamTooLong => return std.fmt.allocPrint(gpa, "error: command output exceeded {d} bytes — refused", .{MAX_BASH_OUTPUT}),
        else => return std.fmt.allocPrint(gpa, "error: failed to spawn shell ({s})", .{@errorName(err)}),
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const term_str = switch (result.term) {
        .exited => |code| try std.fmt.allocPrint(gpa, "exit {d}", .{code}),
        .signal => |s| try std.fmt.allocPrint(gpa, "signal {d}", .{@intFromEnum(s)}),
        .stopped => |s| try std.fmt.allocPrint(gpa, "stopped (signal {d})", .{@intFromEnum(s)}),
        .unknown => |c| try std.fmt.allocPrint(gpa, "unknown ({d})", .{c}),
    };
    defer gpa.free(term_str);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.print(gpa, "[{s}]\n", .{term_str});
    if (result.stdout.len > 0) {
        try out.appendSlice(gpa, "--- stdout ---\n");
        try out.appendSlice(gpa, result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try out.appendSlice(gpa, "\n");
    }
    if (result.stderr.len > 0) {
        try out.appendSlice(gpa, "--- stderr ---\n");
        try out.appendSlice(gpa, result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try out.appendSlice(gpa, "\n");
    }
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try out.appendSlice(gpa, "(no output)\n");
    }

    return out.toOwnedSlice(gpa);
}
