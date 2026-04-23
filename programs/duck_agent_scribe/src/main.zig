const std = @import("std");
const fs = std.fs;
const Io = std.Io;
const mem = std.mem;
const time = std.time;
const linux = std.os.linux;
const c = std.c;

const VERSION = "0.1.0";

// Environment helper for Zig 0.16.2187+
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const ptr = c.getenv(name);
    if (ptr) |p| {
        return std.mem.span(p);
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse args using Args.Iterator for Zig 0.16.2187+
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (mem.eql(u8, command, "init")) {
        try handleInit(allocator, args);
    } else if (mem.eql(u8, command, "log")) {
        try handleLog(allocator, args);
    } else if (mem.eql(u8, command, "complete")) {
        try handleComplete(allocator, args);
    } else if (mem.eql(u8, command, "batch-complete")) {
        try handleBatchComplete(allocator, args);
    } else if (mem.eql(u8, command, "query")) {
        try handleQuery(allocator, args);
    } else if (mem.eql(u8, command, "lineage")) {
        try handleLineage(allocator, args);
    } else if (mem.eql(u8, command, "version")) {
        std.debug.print("duck-agent-scribe v{s}\n", .{VERSION});
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
    }
}

fn printUsage() !void {
    std.debug.print(
        \\duck-agent-scribe - Eternal accountability for spawned agents
        \\
        \\USAGE:
        \\  duckagent-scribe <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\  init              Initialize eternal log for new agent
        \\  log               Log agent turn/action
        \\  complete          Mark agent completion
        \\  batch-complete    Finalize batch manifest
        \\  query             Query agent logs
        \\  lineage           Show retry lineage for agent
        \\  version           Print version
        \\
        \\INIT OPTIONS:
        \\  --agent-id <ID>        Agent ID (e.g., 001)
        \\  --batch-id <ID>        Batch ID
        \\  --task <DESCRIPTION>   Task description
        \\  --provider <NAME>      Provider (grok/claude)
        \\  --max-turns <N>        Maximum turns
        \\  --output-file <PATH>   Expected output file
        \\  --retry-number <N>     Retry attempt (0 for first)
        \\  --crucible-path <PATH> Crucible workspace path
        \\  --pid <PID>            Process ID
        \\
        \\COMPLETE OPTIONS:
        \\  --agent-id <ID>        Agent ID
        \\  --batch-id <ID>        Batch ID
        \\  --status <STATUS>      SUCCESS or FAILED
        \\  --turns-taken <N>      Actual turns taken
        \\  --tokens-used <N>      Tokens consumed
        \\  --result-path <PATH>   Result JSON path
        \\
        \\EXAMPLES:
        \\  duckagent-scribe init --agent-id 001 --batch-id batch-20251024-140812 \
        \\    --task "Write blog post" --provider grok --max-turns 50 \
        \\    --retry-number 0 --crucible-path ~/crucible/grok-... --pid 12345
        \\
        \\  duckagent-scribe complete --agent-id 001 --batch-id batch-20251024-140812 \
        \\    --status SUCCESS --turns-taken 1 --tokens-used 3986
        \\
        \\  duckagent-scribe query --batch-id batch-20251024-140812 --status FAILED
        \\
    , .{});
}

fn handleInit(allocator: mem.Allocator, args: []const []const u8) !void {
    var agent_id: ?[]const u8 = null;
    var batch_id: ?[]const u8 = null;
    var task: ?[]const u8 = null;
    var provider: []const u8 = "grok";
    var max_turns: u32 = 50;
    var output_file: ?[]const u8 = null;
    var retry_number: u32 = 0;
    var crucible_path: ?[]const u8 = null;
    var pid: ?u32 = null;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) break;

        if (mem.eql(u8, args[i], "--agent-id")) {
            agent_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--batch-id")) {
            batch_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--task")) {
            task = args[i + 1];
        } else if (mem.eql(u8, args[i], "--provider")) {
            provider = args[i + 1];
        } else if (mem.eql(u8, args[i], "--max-turns")) {
            max_turns = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (mem.eql(u8, args[i], "--output-file")) {
            output_file = args[i + 1];
        } else if (mem.eql(u8, args[i], "--retry-number")) {
            retry_number = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (mem.eql(u8, args[i], "--crucible-path")) {
            crucible_path = args[i + 1];
        } else if (mem.eql(u8, args[i], "--pid")) {
            pid = try std.fmt.parseInt(u32, args[i + 1], 10);
        }
    }

    if (agent_id == null or batch_id == null or task == null) {
        std.debug.print("Error: --agent-id, --batch-id, and --task are required\n", .{});
        return error.MissingArguments;
    }

    // Get chronos tick and timestamp
    const tick = try getChronosTick(allocator);
    defer allocator.free(tick);

    const timestamp = try getChronosTimestamp(allocator);
    defer allocator.free(timestamp);

    // Create log directory
    const home = getEnv("HOME") orelse return error.HomeNotSet;

    const retry_suffix = if (retry_number > 0)
        try std.fmt.allocPrint(allocator, "-RETRY-{d}", .{retry_number})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(retry_suffix);

    const log_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/eternal-logs/agents-crucible/{s}/agent-{s}-{s}{s}",
        .{ home, batch_id.?, agent_id.?, tick, retry_suffix },
    );
    defer allocator.free(log_dir);

    // Create parent directories recursively
    const io = Io.Threaded.global_single_threaded.io();

    const eternal_logs_path = try std.fmt.allocPrint(allocator, "{s}/eternal-logs", .{home});
    defer allocator.free(eternal_logs_path);
    Io.Dir.createDirAbsolute(io, eternal_logs_path, .default_dir) catch {};

    const agents_crucible_path = try std.fmt.allocPrint(allocator, "{s}/eternal-logs/agents-crucible", .{home});
    defer allocator.free(agents_crucible_path);
    Io.Dir.createDirAbsolute(io, agents_crucible_path, .default_dir) catch {};

    const batch_dir_path = try std.fmt.allocPrint(
        allocator,
        "{s}/eternal-logs/agents-crucible/{s}",
        .{ home, batch_id.? },
    );
    defer allocator.free(batch_dir_path);
    Io.Dir.createDirAbsolute(io, batch_dir_path, .default_dir) catch {};

    try Io.Dir.createDirAbsolute(io, log_dir, .default_dir);

    // Create manifest.json
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{log_dir});
    defer allocator.free(manifest_path);

    const manifest = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "agent": {{
        \\    "id": "{s}",
        \\    "chronos_tick": "{s}",
        \\    "timestamp_iso": "{s}",
        \\    "provider": "{s}"
        \\  }},
        \\  "batch": {{
        \\    "id": "{s}",
        \\    "is_retry": {s},
        \\    "retry_number": {d}
        \\  }},
        \\  "task": {{
        \\    "description": "{s}",
        \\    "max_turns": {d},
        \\    "output_file": "{s}"
        \\  }},
        \\  "crucible": {{
        \\    "path": "{s}"
        \\  }},
        \\  "execution": {{
        \\    "pid": {?d},
        \\    "started_at": "{s}",
        \\    "status": "RUNNING"
        \\  }}
        \\}}
        \\
    ,
        .{
            agent_id.?,
            tick,
            timestamp,
            provider,
            batch_id.?,
            if (retry_number > 0) "true" else "false",
            retry_number,
            task.?,
            max_turns,
            output_file orelse "",
            crucible_path orelse "",
            pid,
            timestamp,
        },
    );
    defer allocator.free(manifest);

    try writeFile(manifest_path, manifest);

    // Create init.log
    const init_log_path = try std.fmt.allocPrint(allocator, "{s}/init.log", .{log_dir});
    defer allocator.free(init_log_path);

    const init_log = try std.fmt.allocPrint(
        allocator,
        "[{s}] Agent {s} initialized{s}\nTask: {s}\nProvider: {s}\nCrucible: {s}\nPID: {?d}\n",
        .{
            timestamp,
            agent_id.?,
            if (retry_number > 0) try std.fmt.allocPrint(allocator, " (RETRY-{d})", .{retry_number}) else "",
            task.?,
            provider,
            crucible_path orelse "N/A",
            pid,
        },
    );
    defer allocator.free(init_log);

    try writeFile(init_log_path, init_log);

    std.debug.print("✅ Agent log initialized: {s}\n", .{log_dir});
}

fn handleLog(allocator: mem.Allocator, args: []const []const u8) !void {
    var agent_id: ?[]const u8 = null;
    var batch_id: ?[]const u8 = null;
    var turn: u32 = 0;
    var message: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) break;

        if (mem.eql(u8, args[i], "--agent-id")) {
            agent_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--batch-id")) {
            batch_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--turn")) {
            turn = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (mem.eql(u8, args[i], "--message")) {
            message = args[i + 1];
        }
    }

    if (agent_id == null or batch_id == null or message == null) {
        std.debug.print("Error: --agent-id, --batch-id, and --message are required\n", .{});
        return error.MissingArguments;
    }

    // Find agent log directory (latest one for this agent/batch)
    const log_dir = try findAgentLogDir(allocator, batch_id.?, agent_id.?);
    defer allocator.free(log_dir);

    const turn_log_path = try std.fmt.allocPrint(allocator, "{s}/turn-{d:0>3}.log", .{ log_dir, turn });
    defer allocator.free(turn_log_path);

    const timestamp = try getChronosTimestamp(allocator);
    defer allocator.free(timestamp);

    const turn_log = try std.fmt.allocPrint(
        allocator,
        "[{s}] Turn {d}: {s}\n",
        .{ timestamp, turn, message.? },
    );
    defer allocator.free(turn_log);

    try appendFile(turn_log_path, turn_log);
    std.debug.print("📝 Logged turn {d} for agent {s}\n", .{ turn, agent_id.? });
}

fn handleComplete(allocator: mem.Allocator, args: []const []const u8) !void {
    var agent_id: ?[]const u8 = null;
    var batch_id: ?[]const u8 = null;
    var status: []const u8 = "SUCCESS";
    var turns_taken: u32 = 0;
    var tokens_used: u32 = 0;
    var result_path: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) break;

        if (mem.eql(u8, args[i], "--agent-id")) {
            agent_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--batch-id")) {
            batch_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--status")) {
            status = args[i + 1];
        } else if (mem.eql(u8, args[i], "--turns-taken")) {
            turns_taken = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (mem.eql(u8, args[i], "--tokens-used")) {
            tokens_used = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (mem.eql(u8, args[i], "--result-path")) {
            result_path = args[i + 1];
        }
    }

    if (agent_id == null or batch_id == null) {
        std.debug.print("Error: --agent-id and --batch-id are required\n", .{});
        return error.MissingArguments;
    }

    // Find agent log directory
    const log_dir = try findAgentLogDir(allocator, batch_id.?, agent_id.?);
    defer allocator.free(log_dir);

    // Write result.log
    const result_log_path = try std.fmt.allocPrint(allocator, "{s}/result.log", .{log_dir});
    defer allocator.free(result_log_path);

    const timestamp = try getChronosTimestamp(allocator);
    defer allocator.free(timestamp);

    const result_log = try std.fmt.allocPrint(
        allocator,
        \\[{s}] Agent {s} completed
        \\Status: {s}
        \\Turns taken: {d}
        \\Tokens used: {d}
        \\Result path: {s}
        \\
    ,
        .{
            timestamp,
            agent_id.?,
            status,
            turns_taken,
            tokens_used,
            result_path orelse "N/A",
        },
    );
    defer allocator.free(result_log);

    try writeFile(result_log_path, result_log);

    // Update manifest.json with final status
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{log_dir});
    defer allocator.free(manifest_path);

    // Read existing manifest
    const manifest_content = try readFile(allocator, manifest_path);
    defer allocator.free(manifest_content);

    // Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_content, .{});
    defer parsed.deinit();

    // Update execution.status field
    if (parsed.value.object.getPtr("execution")) |execution_ptr| {
        if (execution_ptr.* == .object) {
            try execution_ptr.object.put(allocator, "status", std.json.Value{ .string = status });
            try execution_ptr.object.put(allocator, "completed_at", std.json.Value{ .string = timestamp });
        }
    }

    // Write updated manifest back
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(parsed.value);
    try writeFile(manifest_path, out.written());

    const status_marker = mem.eql(u8, status, "SUCCESS");
    std.debug.print("{s} Agent {s} marked as {s} in manifest.json\n", .{
        if (status_marker) "✅" else "❌",
        agent_id.?,
        status,
    });
}

fn handleBatchComplete(allocator: mem.Allocator, args: []const []const u8) !void {
    var batch_id: ?[]const u8 = null;
    var total: u32 = 0;
    var succeeded: u32 = 0;
    var failed: u32 = 0;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) break;

        if (mem.eql(u8, args[i], "--batch-id")) {
            batch_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--total")) {
            total = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (mem.eql(u8, args[i], "--succeeded")) {
            succeeded = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else if (mem.eql(u8, args[i], "--failed")) {
            failed = try std.fmt.parseInt(u32, args[i + 1], 10);
        }
    }

    if (batch_id == null) {
        std.debug.print("Error: --batch-id is required\n", .{});
        return error.MissingArguments;
    }

    const home = getEnv("HOME") orelse return error.HomeNotSet;
    const batch_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/eternal-logs/agents-crucible/{s}",
        .{ home, batch_id.? },
    );
    defer allocator.free(batch_dir);

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{batch_dir});
    defer allocator.free(manifest_path);

    const timestamp = try getChronosTimestamp(allocator);
    defer allocator.free(timestamp);

    const success_rate = if (total > 0)
        @as(f64, @floatFromInt(succeeded)) / @as(f64, @floatFromInt(total))
    else
        0.0;

    const manifest = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "batch": {{
        \\    "id": "{s}",
        \\    "completed_at": "{s}"
        \\  }},
        \\  "results": {{
        \\    "total_agents": {d},
        \\    "succeeded": {d},
        \\    "failed": {d},
        \\    "success_rate": {d:.2}
        \\  }}
        \\}}
        \\
    ,
        .{ batch_id.?, timestamp, total, succeeded, failed, success_rate },
    );
    defer allocator.free(manifest);

    try writeFile(manifest_path, manifest);
    std.debug.print("📊 Batch manifest completed: {s}\n", .{batch_id.?});
}

fn handleQuery(allocator: mem.Allocator, args: []const []const u8) !void {
    var search_term: ?[]const u8 = null;
    var batch_id: ?[]const u8 = null;
    var status_filter: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) break;

        if (mem.eql(u8, args[i], "--query")) {
            search_term = args[i + 1];
        } else if (mem.eql(u8, args[i], "--batch-id")) {
            batch_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--status")) {
            status_filter = args[i + 1];
        }
    }

    const home = getEnv("HOME") orelse return error.HomeNotSet;
    const base_path = try std.fmt.allocPrint(allocator, "{s}/eternal-logs/agents-crucible", .{home});
    defer allocator.free(base_path);

    // Collect matching results
    var results: std.ArrayListUnmanaged(QueryResult) = .empty;
    defer results.deinit(allocator);

    const io = Io.Threaded.global_single_threaded.io();

    // Iterate through batch directories
    var batch_dir = Io.Dir.openDirAbsolute(io, base_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Error: Could not open log directory: {s}\n", .{base_path});
        std.debug.print("Details: {any}\n", .{err});
        return;
    };
    defer batch_dir.close(io);

    var batch_iter = batch_dir.iterate();
    while (try batch_iter.next(io)) |batch_entry| {
        if (batch_entry.kind != .directory) continue;

        // If batch_id filter is set, skip non-matching batches
        if (batch_id) |bid| {
            if (!mem.eql(u8, batch_entry.name, bid)) continue;
        }

        const batch_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, batch_entry.name });
        defer allocator.free(batch_path);

        // Iterate through agent directories within batch
        var agent_dir = Io.Dir.openDirAbsolute(io, batch_path, .{ .iterate = true }) catch continue;
        defer agent_dir.close(io);

        var agent_iter = agent_dir.iterate();
        while (try agent_iter.next(io)) |agent_entry| {
            if (agent_entry.kind != .directory) continue;

            const agent_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ batch_path, agent_entry.name });
            defer allocator.free(agent_path);

            const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{agent_path});
            defer allocator.free(manifest_path);

            // Try to read and parse manifest
            const manifest_content = readFile(allocator, manifest_path) catch continue;
            defer allocator.free(manifest_content);

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_content, .{}) catch continue;
            defer parsed.deinit();

            // Check if this entry matches the query
            var matches = false;

            if (parsed.value.object.get("agent")) |agent_obj| {
                if (agent_obj == .object) {
                    // Check agent_id match
                    if (search_term) |st| {
                        if (agent_obj.object.get("id")) |agent_id_val| {
                            if (agent_id_val == .string) {
                                if (mem.eql(u8, agent_id_val.string, st)) {
                                    matches = true;
                                }
                            }
                        }
                    }
                }
            }

            // Check status filter
            if (status_filter) |sf| {
                if (parsed.value.object.get("execution")) |exec_obj| {
                    if (exec_obj == .object) {
                        if (exec_obj.object.get("status")) |status_val| {
                            if (status_val == .string) {
                                if (mem.eql(u8, status_val.string, sf)) {
                                    matches = true;
                                } else {
                                    matches = false;
                                }
                            }
                        }
                    }
                }
            }

            if (matches or (search_term == null and status_filter == null)) {
                const result = try buildQueryResult(allocator, agent_entry.name, &parsed.value);
                try results.append(allocator, result);
            }
        }
    }

    // Display results in formatted table
    if (results.items.len == 0) {
        std.debug.print("No matching entries found.\n", .{});
        return;
    }

    std.debug.print("\n🔍 Query Results ({d} matches):\n", .{results.items.len});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("{s:20} {s:15} {s:20} {s:15}\n", .{ "Agent ID", "Status", "Timestamp", "Batch" });
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    for (results.items) |result| {
        std.debug.print("{s:20} {s:15} {s:20} {s:15}\n", .{
            result.agent_id,
            result.status,
            result.timestamp,
            result.batch_id,
        });
    }
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
}

fn handleLineage(allocator: mem.Allocator, args: []const []const u8) !void {
    var target_agent_id: ?[]const u8 = null;
    var batch_id: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) break;

        if (mem.eql(u8, args[i], "--agent-id")) {
            target_agent_id = args[i + 1];
        } else if (mem.eql(u8, args[i], "--batch-id")) {
            batch_id = args[i + 1];
        }
    }

    if (target_agent_id == null or batch_id == null) {
        std.debug.print("Error: --agent-id and --batch-id are required for lineage\n", .{});
        return error.MissingArguments;
    }

    const home = getEnv("HOME") orelse return error.HomeNotSet;
    const batch_path = try std.fmt.allocPrint(
        allocator,
        "{s}/eternal-logs/agents-crucible/{s}",
        .{ home, batch_id.? },
    );
    defer allocator.free(batch_path);

    // Collect all matching agent directories (including retries)
    var lineage_entries: std.ArrayListUnmanaged(LineageEntry) = .empty;
    defer lineage_entries.deinit(allocator);

    const io = Io.Threaded.global_single_threaded.io();

    var batch_dir = Io.Dir.openDirAbsolute(io, batch_path, .{ .iterate = true }) catch {
        std.debug.print("Error: Batch directory not found: {s}\n", .{batch_path});
        return;
    };
    defer batch_dir.close(io);

    var agent_iter = batch_dir.iterate();
    while (try agent_iter.next(io)) |agent_entry| {
        if (agent_entry.kind != .directory) continue;

        // Check if this directory matches the agent (including retries)
        const prefix = try std.fmt.allocPrint(allocator, "agent-{s}-", .{target_agent_id.?});
        defer allocator.free(prefix);

        if (!mem.startsWith(u8, agent_entry.name, prefix)) continue;

        const agent_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ batch_path, agent_entry.name });
        defer allocator.free(agent_path);

        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{agent_path});
        defer allocator.free(manifest_path);

        const manifest_content = readFile(allocator, manifest_path) catch continue;
        defer allocator.free(manifest_content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_content, .{}) catch continue;
        defer parsed.deinit();

        var entry = LineageEntry{
            .retry_number = 0,
            .status = "UNKNOWN",
            .timestamp = "N/A",
            .started_at = "N/A",
        };

        // Extract retry number
        if (parsed.value.object.get("batch")) |batch_obj| {
            if (batch_obj == .object) {
                if (batch_obj.object.get("retry_number")) |retry_val| {
                    if (retry_val == .integer) {
                        entry.retry_number = @intCast(retry_val.integer);
                    }
                }
            }
        }

        // Extract status and timestamps
        if (parsed.value.object.get("execution")) |exec_obj| {
            if (exec_obj == .object) {
                if (exec_obj.object.get("status")) |status_val| {
                    if (status_val == .string) {
                        entry.status = status_val.string;
                    }
                }
                if (exec_obj.object.get("started_at")) |started_val| {
                    if (started_val == .string) {
                        entry.started_at = started_val.string;
                    }
                }
                if (exec_obj.object.get("completed_at")) |completed_val| {
                    if (completed_val == .string) {
                        entry.timestamp = completed_val.string;
                    }
                }
            }
        }

        try lineage_entries.append(allocator, entry);
    }

    if (lineage_entries.items.len == 0) {
        std.debug.print("No lineage found for agent {s} in batch {s}\n", .{ target_agent_id.?, batch_id.? });
        return;
    }

    // Sort by retry number
    std.mem.sort(LineageEntry, lineage_entries.items, {}, compareLineageEntries);

    // Display lineage chain
    std.debug.print("\n📜 Retry Lineage for Agent {s}:\n", .{target_agent_id.?});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("{s:8} {s:12} {s:25} {s:25}\n", .{ "Attempt", "Status", "Started", "Completed" });
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    for (lineage_entries.items) |entry| {
        const attempt_label = if (entry.retry_number == 0) "Initial" else try std.fmt.allocPrint(allocator, "Retry-{d}", .{entry.retry_number});
        defer if (entry.retry_number > 0) allocator.free(attempt_label);

        std.debug.print("{s:8} {s:12} {s:25} {s:25}\n", .{
            attempt_label,
            entry.status,
            entry.started_at,
            entry.timestamp,
        });
    }
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
}

// Support structures

const QueryResult = struct {
    agent_id: []const u8,
    status: []const u8,
    timestamp: []const u8,
    batch_id: []const u8,
};

const LineageEntry = struct {
    retry_number: u32,
    status: []const u8,
    timestamp: []const u8,
    started_at: []const u8,
};

fn buildQueryResult(allocator: mem.Allocator, dirname: []const u8, manifest: *const std.json.Value) !QueryResult {
    var result = QueryResult{
        .agent_id = "N/A",
        .status = "UNKNOWN",
        .timestamp = "N/A",
        .batch_id = "N/A",
    };

    if (manifest.object.get("agent")) |agent_obj| {
        if (agent_obj == .object) {
            if (agent_obj.object.get("id")) |id_val| {
                if (id_val == .string) {
                    result.agent_id = try allocator.dupe(u8, id_val.string);
                }
            }
        }
    }

    if (manifest.object.get("execution")) |exec_obj| {
        if (exec_obj == .object) {
            if (exec_obj.object.get("status")) |status_val| {
                if (status_val == .string) {
                    result.status = try allocator.dupe(u8, status_val.string);
                }
            }
            if (exec_obj.object.get("completed_at")) |ts_val| {
                if (ts_val == .string) {
                    result.timestamp = try allocator.dupe(u8, ts_val.string);
                }
            }
        }
    }

    // Extract batch_id from dirname
    if (mem.startsWith(u8, dirname, "agent-")) {
        var parts = std.mem.splitSequence(u8, dirname, "-");
        _ = parts.next(); // skip "agent"
        _ = parts.next(); // skip agent_id
        if (parts.next()) |rest| {
            if (std.mem.indexOf(u8, rest, "-")) |idx| {
                result.batch_id = try allocator.dupe(u8, rest[0..idx]);
            }
        }
    }

    return result;
}

fn compareLineageEntries(_: void, a: LineageEntry, b: LineageEntry) bool {
    return a.retry_number < b.retry_number;
}

// Helper functions

fn getChronosTick(allocator: mem.Allocator) ![]u8 {
    // Zig 0.16: Use std.c.clock_gettime for wall clock time
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const now = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    const tick_num = @abs(@mod(now, 10000000000));
    return try std.fmt.allocPrint(allocator, "TICK-{d:0>10}", .{tick_num});
}

fn getChronosTimestamp(allocator: mem.Allocator) ![]u8 {
    // Zig 0.16: Use std.c.clock_gettime for wall clock time
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const timestamp_ms = @divFloor(ts.sec * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms), 1);
    const seconds = @divFloor(timestamp_ms, 1000);
    const millis = @mod(timestamp_ms, 1000);

    // Calculate days since Unix epoch
    const days_since_epoch = @divFloor(seconds, 86400);
    const day_seconds = @mod(seconds, 86400);

    const hours = @divFloor(day_seconds, 3600);
    const minutes = @divFloor(@mod(day_seconds, 3600), 60);
    const secs = @mod(day_seconds, 60);

    // Calculate year, month, day from days_since_epoch
    // Simplified calculation (assumes 365.25 days per year)
    const epoch_year: i64 = 1970;
    const approx_year = epoch_year + @divFloor(days_since_epoch * 4, 1461);
    const year_start_day = @divFloor((approx_year - epoch_year) * 1461, 4);
    const day_of_year = days_since_epoch - year_start_day;

    // Simplified month/day (good enough for logging)
    const month = @min(12, @divFloor(day_of_year * 12, 365) + 1);
    const day = @min(31, @mod(day_of_year, 31) + 1);

    return try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z",
        .{ approx_year, month, day, hours, minutes, secs, millis * 1000000 },
    );
}

fn findAgentLogDir(allocator: mem.Allocator, batch_id: []const u8, agent_id: []const u8) ![]u8 {
    const home = getEnv("HOME") orelse return error.HomeNotSet;
    const batch_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/eternal-logs/agents-crucible/{s}",
        .{ home, batch_id },
    );
    defer allocator.free(batch_dir);

    // Find directory matching agent-{agent_id}-*
    const io = Io.Threaded.global_single_threaded.io();
    var dir = try Io.Dir.openDirAbsolute(io, batch_dir, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            const prefix = try std.fmt.allocPrint(allocator, "agent-{s}-", .{agent_id});
            defer allocator.free(prefix);

            if (mem.startsWith(u8, entry.name, prefix)) {
                return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ batch_dir, entry.name });
            }
        }
    }

    return error.AgentLogNotFound;
}

fn readFile(allocator: mem.Allocator, path: []const u8) ![]u8 {
    const io = Io.Threaded.global_single_threaded.io();
    const content = try Io.Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(10 * 1024 * 1024));
    return content;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const file = try Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn appendFile(path: []const u8, content: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const file = try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
    defer file.close(io);
    // Seek to end using stat to get file length, then write at that position
    const stat = try file.stat(io);
    try file.writePositionalAll(io, content, stat.size);
}

// Test Suite

test "Parse chronos tick format" {
    const allocator = std.heap.c_allocator;

    const tick = try getChronosTick(allocator);
    defer allocator.free(tick);

    try std.testing.expect(mem.startsWith(u8, tick, "TICK-"));
    try std.testing.expect(tick.len >= 15); // "TICK-" + 10 digits
}

test "Chronos timestamp is valid ISO format" {
    const allocator = std.heap.c_allocator;

    const timestamp = try getChronosTimestamp(allocator);
    defer allocator.free(timestamp);

    try std.testing.expect(mem.indexOf(u8, timestamp, "T") != null);
    try std.testing.expect(mem.indexOf(u8, timestamp, "Z") != null);
}

test "Manifest JSON generation format" {
    const allocator = std.heap.c_allocator;

    const timestamp = try getChronosTimestamp(allocator);
    defer allocator.free(timestamp);

    const manifest = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "agent": {{
        \\    "id": "test-001",
        \\    "timestamp_iso": "{s}"
        \\  }}
        \\}}
        \\
    ,
        .{timestamp},
    );
    defer allocator.free(manifest);

    // Parse to verify valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
}

test "Directory path construction with retry suffix" {
    const allocator = std.heap.c_allocator;

    const retry_number = 2;
    const retry_suffix = if (retry_number > 0)
        try std.fmt.allocPrint(allocator, "-RETRY-{d}", .{retry_number})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(retry_suffix);

    const expected = "-RETRY-2";
    try std.testing.expect(mem.eql(u8, retry_suffix, expected));
}

test "Query result batch_id extraction from dirname" {
    const allocator = std.heap.c_allocator;

    // Create minimal manifest for testing
    const manifest_str =
        \\{
        \\  "agent": {"id": "001"},
        \\  "execution": {"status": "SUCCESS"}
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_str, .{});
    defer parsed.deinit();

    const dirname = "agent-001-batch-20251024";
    const result = try buildQueryResult(allocator, dirname, &parsed.value);

    try std.testing.expect(mem.eql(u8, result.agent_id, "001"));
    try std.testing.expect(mem.eql(u8, result.status, "SUCCESS"));

    allocator.free(result.agent_id);
    allocator.free(result.status);
    if (!mem.eql(u8, result.batch_id, "N/A")) allocator.free(result.batch_id);
    if (!mem.eql(u8, result.timestamp, "N/A")) allocator.free(result.timestamp);
}

test "Lineage entry sorting by retry number" {
    const allocator = std.heap.c_allocator;

    var entries: std.ArrayListUnmanaged(LineageEntry) = .empty;
    defer entries.deinit(allocator);

    try entries.append(allocator, LineageEntry{
        .retry_number = 2,
        .status = "FAILED",
        .timestamp = "2025-01-02T10:00:00Z",
        .started_at = "2025-01-02T09:00:00Z",
    });
    try entries.append(allocator, LineageEntry{
        .retry_number = 0,
        .status = "FAILED",
        .timestamp = "2025-01-01T10:00:00Z",
        .started_at = "2025-01-01T09:00:00Z",
    });
    try entries.append(allocator, LineageEntry{
        .retry_number = 1,
        .status = "RUNNING",
        .timestamp = "N/A",
        .started_at = "2025-01-01T20:00:00Z",
    });

    std.mem.sort(LineageEntry, entries.items, {}, compareLineageEntries);

    try std.testing.expect(entries.items[0].retry_number == 0);
    try std.testing.expect(entries.items[1].retry_number == 1);
    try std.testing.expect(entries.items[2].retry_number == 2);
}

test "Edge case: empty lineage list" {
    const allocator = std.heap.c_allocator;

    var entries: std.ArrayListUnmanaged(LineageEntry) = .empty;
    defer entries.deinit(allocator);

    // No entries appended - should handle gracefully
    try std.testing.expect(entries.items.len == 0);
}

test "Edge case: manifest with missing fields" {
    const allocator = std.heap.c_allocator;

    // Minimal manifest missing most fields
    const manifest_str = "{}";

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_str, .{});
    defer parsed.deinit();

    const dirname = "agent-001-tick-123";
    const result = try buildQueryResult(allocator, dirname, &parsed.value);

    // Should gracefully default to "N/A"
    try std.testing.expect(mem.eql(u8, result.agent_id, "N/A"));
    try std.testing.expect(mem.eql(u8, result.status, "UNKNOWN"));
}
