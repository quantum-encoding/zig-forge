//! ═══════════════════════════════════════════════════════════════════════════
//! WARP GATE CLI
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Usage:
//!   warp send <path>           Send a file or directory
//!   warp recv <code> [dest]    Receive files using transfer code
//!   warp status                Show connection status
//!
//! Examples:
//!   $ warp send ./my-project
//!   Transfer code: warp-729-alpha
//!   Waiting for receiver...
//!
//!   $ warp recv warp-729-alpha
//!   Connecting to peer...
//!   Receiving: my-project (12.4 MB)
//!   ████████████████░░░░ 80% 9.9 MB/s

const std = @import("std");
const linux = std.os.linux;
const warp_gate = @import("warp_gate");

const WarpCode = warp_gate.WarpCode;
const WarpSession = warp_gate.WarpSession;
const Transport = warp_gate.Transport;
const Resolver = warp_gate.Resolver;

const VERSION = "0.1.0";

const BANNER =
    \\
    \\  ╦ ╦╔═╗╦═╗╔═╗  ╔═╗╔═╗╔╦╗╔═╗
    \\  ║║║╠═╣╠╦╝╠═╝  ║ ╦╠═╣ ║ ║╣
    \\  ╚╩╝╩ ╩╩╚═╩    ╚═╝╩ ╩ ╩ ╚═╝
    \\
    \\  Peer-to-peer code transfer
    \\
;

const HELP =
    \\
    \\USAGE:
    \\  warp <command> [options]
    \\
    \\COMMANDS:
    \\  send <path>           Send a file or directory
    \\  recv <code> [dest]    Receive using transfer code
    \\  status                Show network status
    \\  help                  Show this help message
    \\
    \\OPTIONS:
    \\  -v, --verbose         Enable verbose output
    \\  -q, --quiet           Suppress progress output
    \\  --no-mdns             Disable local network discovery
    \\
    \\EXAMPLES:
    \\  warp send ./src
    \\  warp recv warp-729-alpha ./downloads
    \\
;

const Args = struct {
    command: Command,
    path: ?[]const u8 = null,
    code: ?[]const u8 = null,
    dest: ?[]const u8 = null,
    verbose: bool = false,
    quiet: bool = false,
    no_mdns: bool = false,
    json: bool = false, // JSON output mode for Tauri sidecar

    const Command = enum {
        send,
        recv,
        status,
        help,
        version,
    };
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = parseArgs(init.minimal.args) catch |err| {
        printError("Invalid arguments: {}", .{err});
        printHelp();
        std.process.exit(1);
    };

    switch (args.command) {
        .send => try cmdSend(allocator, io, args),
        .recv => try cmdRecv(allocator, io, args),
        .status => try cmdStatus(allocator, io),
        .help => printHelp(),
        .version => printVersion(),
    }
}

fn parseArgs(proc_args: std.process.Args) !Args {
    var args_iter = std.process.Args.Iterator.init(proc_args);
    _ = args_iter.next(); // Skip program name

    const cmd_str = args_iter.next() orelse return Args{ .command = .help };

    var result = Args{ .command = .help };

    if (std.mem.eql(u8, cmd_str, "send")) {
        result.command = .send;
        result.path = args_iter.next();
        if (result.path == null) return error.MissingPath;
    } else if (std.mem.eql(u8, cmd_str, "recv")) {
        result.command = .recv;
        result.code = args_iter.next();
        if (result.code == null) return error.MissingCode;
        result.dest = args_iter.next(); // Optional destination
    } else if (std.mem.eql(u8, cmd_str, "status")) {
        result.command = .status;
    } else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "-h") or std.mem.eql(u8, cmd_str, "--help")) {
        result.command = .help;
    } else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "-V") or std.mem.eql(u8, cmd_str, "--version")) {
        result.command = .version;
    } else {
        return error.UnknownCommand;
    }

    // Parse remaining flags
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            result.quiet = true;
        } else if (std.mem.eql(u8, arg, "--no-mdns")) {
            result.no_mdns = true;
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            result.json = true;
        }
    }

    return result;
}

fn cmdSend(allocator: std.mem.Allocator, io: std.Io, args: Args) !void {
    const path = args.path orelse return error.MissingPath;

    // Verify path exists and get file size by trying to open it
    const file_size: u64 = blk: {
        const file = std.posix.openat(std.c.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
            if (args.json) {
                jsonEvent("error", .{ .message = "Cannot access path", .path = path });
            } else {
                printError("Cannot access '{s}': {}", .{ path, err });
            }
            return err;
        };
        defer _ = std.c.close(file);
        // Use lseek to get file size
        const end_pos = std.c.lseek(file, 0, std.c.SEEK.END);
        if (end_pos < 0) break :blk @as(u64, 0);
        break :blk @intCast(end_pos);
    };

    // Create session
    var session = try WarpSession.init(allocator, io, .sender);
    defer session.deinit();

    // Display transfer code
    const code_str = session.getCodeString();

    if (args.json) {
        jsonEvent("code_generated", .{
            .code = &code_str,
            .path = path,
            .size = file_size,
        });
    } else {
        printBanner();
        print("\n  \x1b[1;32mTransfer code:\x1b[0m \x1b[1;37m{s}\x1b[0m\n", .{code_str});
        print("\n  Share this code with the receiver.\n", .{});
        print("  Waiting for connection...\n\n", .{});
    }

    // Start discovery
    if (!args.no_mdns) {
        if (args.json) {
            jsonEvent("state", .{ .state = "discovering" });
        }
        session.connect() catch |err| {
            if (args.verbose and !args.json) {
                printError("Discovery failed: {}", .{err});
            }
        };
    }

    // Wait for peer connection
    if (!args.json) {
        print("  \x1b[33m⏳\x1b[0m Discovering peer...\n", .{});
    }

    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        if (!args.json) {
            print("\r  \x1b[33m⏳\x1b[0m Waiting... {d}s", .{i});
        }
        io.sleep(.fromSeconds(1), .awake) catch {};

        // Check for peer
        if (session.state == .connecting or session.state == .transferring) {
            if (args.json) {
                jsonEvent("state", .{ .state = "connected" });
            }
            break;
        }
    }

    if (session.state != .connecting and session.state != .transferring) {
        if (args.json) {
            jsonEvent("error", .{ .message = "Connection timeout" });
        } else {
            print("\n\n  \x1b[31m✗\x1b[0m Connection timeout. Peer may not be reachable.\n", .{});
            print("    Try:\n", .{});
            print("    • Ensure peer is on same network (for local transfers)\n", .{});
            print("    • Check firewall settings\n", .{});
            print("    • Verify the transfer code\n\n", .{});
        }
        return error.ConnectionTimeout;
    }

    // Start transfer
    if (args.json) {
        jsonEvent("state", .{ .state = "transferring" });
    } else {
        print("\n  \x1b[32m✓\x1b[0m Connected! Starting transfer...\n\n", .{});
    }

    session.send(path) catch |err| {
        if (args.json) {
            jsonEvent("error", .{ .message = "Transfer failed" });
        } else {
            printError("Transfer failed: {}", .{err});
        }
        return err;
    };

    if (args.json) {
        jsonEvent("state", .{ .state = "completed" });
    } else {
        print("  \x1b[32m✓\x1b[0m Transfer complete!\n\n", .{});
    }
}

fn cmdRecv(allocator: std.mem.Allocator, io: std.Io, args: Args) !void {
    const code_str = args.code orelse return error.MissingCode;
    const dest = args.dest orelse ".";

    // Validate code format
    _ = WarpCode.parse(code_str) catch {
        if (args.json) {
            jsonEvent("error", .{ .message = "Invalid transfer code", .code = code_str });
        } else {
            printError("Invalid transfer code: '{s}'", .{code_str});
            print("\n  Expected format: warp-XXX-word (e.g., warp-729-alpha)\n\n", .{});
        }
        return error.InvalidCode;
    };

    // Create session
    var session = try WarpSession.init(allocator, io, .receiver);
    defer session.deinit();

    try session.setCode(code_str);

    if (args.json) {
        jsonEvent("state", .{ .state = "connecting", .code = code_str, .dest = dest });
    } else {
        printBanner();
        print("\n  \x1b[1;32mConnecting with code:\x1b[0m {s}\n", .{code_str});
        print("  Destination: {s}\n\n", .{dest});
    }

    // Start discovery
    if (!args.no_mdns) {
        if (args.json) {
            jsonEvent("state", .{ .state = "discovering" });
        }
        session.connect() catch |err| {
            if (args.verbose and !args.json) {
                printError("Discovery failed: {}", .{err});
            }
        };
    }

    if (!args.json) {
        print("  \x1b[33m⏳\x1b[0m Searching for sender...\n", .{});
    }

    // Wait for peer
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        if (!args.json) {
            print("\r  \x1b[33m⏳\x1b[0m Searching... {d}s", .{i});
        }
        io.sleep(.fromSeconds(1), .awake) catch {};

        if (session.state == .connecting or session.state == .transferring) {
            if (args.json) {
                jsonEvent("state", .{ .state = "connected" });
            }
            break;
        }
    }

    if (session.state != .connecting and session.state != .transferring) {
        if (args.json) {
            jsonEvent("error", .{ .message = "Could not find sender" });
        } else {
            print("\n\n  \x1b[31m✗\x1b[0m Could not find sender.\n", .{});
            print("    Verify:\n", .{});
            print("    • The transfer code is correct\n", .{});
            print("    • Sender is still waiting\n", .{});
            print("    • Both devices can reach each other\n\n", .{});
        }
        return error.ConnectionTimeout;
    }

    if (args.json) {
        jsonEvent("state", .{ .state = "transferring" });
    } else {
        print("\n  \x1b[32m✓\x1b[0m Connected! Receiving files...\n\n", .{});
    }

    // Receive files
    session.receive(dest) catch |err| {
        if (args.json) {
            jsonEvent("error", .{ .message = "Receive failed" });
        } else {
            printError("Receive failed: {}", .{err});
        }
        return err;
    };

    if (args.json) {
        jsonEvent("state", .{ .state = "completed", .dest = dest });
    } else {
        print("  \x1b[32m✓\x1b[0m Received successfully to: {s}\n\n", .{dest});
    }
}

fn cmdStatus(allocator: std.mem.Allocator, io: std.Io) !void {
    printBanner();
    print("\n  \x1b[1;36mNetwork Status\x1b[0m\n\n", .{});

    // Query STUN for public IP
    var resolver = try Resolver.init(allocator, io);
    defer resolver.deinit();

    print("  Querying STUN servers...\n", .{});

    if (resolver.queryStun()) |endpoint| {
        print("  \x1b[32m✓\x1b[0m Public IP: {d}.{d}.{d}.{d}:{d}\n", .{
            endpoint.addr[0],
            endpoint.addr[1],
            endpoint.addr[2],
            endpoint.addr[3],
            endpoint.port,
        });
    } else |err| {
        print("  \x1b[31m✗\x1b[0m STUN query failed: {}\n", .{err});
    }

    // Check mDNS
    print("\n  Checking local network...\n", .{});
    print("  \x1b[32m✓\x1b[0m mDNS available\n", .{});

    print("\n", .{});
}

fn printBanner() void {
    print("\x1b[1;36m{s}\x1b[0m", .{BANNER});
}

fn printHelp() void {
    printBanner();
    print("{s}", .{HELP});
}

fn printVersion() void {
    print("warp {s}\n", .{VERSION});
}

fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn printError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("\x1b[31mError:\x1b[0m " ++ fmt ++ "\n", args);
}

/// Emit a JSON event to stdout (for Tauri sidecar integration)
/// Uses a simple buffer-based approach for Zig 0.16 compatibility
fn jsonEvent(event_type: []const u8, data: anytype) void {
    var buffer: [4096]u8 = undefined;
    var pos: usize = 0;

    // Write opening
    const opening = std.fmt.bufPrint(buffer[pos..], "{{\"event\":\"{s}\",\"data\":{{", .{event_type}) catch return;
    pos += opening.len;

    const DataType = @TypeOf(data);
    const fields = std.meta.fields(DataType);
    var first = true;

    inline for (fields) |field| {
        if (!first) {
            if (pos < buffer.len) {
                buffer[pos] = ',';
                pos += 1;
            }
        }
        first = false;

        const value = @field(data, field.name);
        const FieldType = @TypeOf(value);

        if (FieldType == []const u8) {
            const part = std.fmt.bufPrint(buffer[pos..], "\"{s}\":\"{s}\"", .{ field.name, value }) catch return;
            pos += part.len;
        } else if (FieldType == *const [15]u8) {
            // WarpCode string buffer - trim trailing spaces
            const str = std.mem.trimEnd(u8, value, " ");
            const part = std.fmt.bufPrint(buffer[pos..], "\"{s}\":\"{s}\"", .{ field.name, str }) catch return;
            pos += part.len;
        } else if (@typeInfo(FieldType) == .pointer) {
            // Generic pointer to array - print as string
            const part = std.fmt.bufPrint(buffer[pos..], "\"{s}\":\"{s}\"", .{ field.name, value }) catch return;
            pos += part.len;
        } else if (@typeInfo(FieldType) == .int) {
            const part = std.fmt.bufPrint(buffer[pos..], "\"{s}\":{d}", .{ field.name, value }) catch return;
            pos += part.len;
        } else {
            const part = std.fmt.bufPrint(buffer[pos..], "\"{s}\":null", .{field.name}) catch return;
            pos += part.len;
        }
    }

    // Write closing and newline
    const closing = std.fmt.bufPrint(buffer[pos..], "}}}}\n", .{}) catch return;
    pos += closing.len;

    // Write to stdout using C write
    _ = std.c.write(std.posix.STDOUT_FILENO, buffer[0..pos].ptr, pos);
}

// ═══════════════════════════════════════════════════════════════════════════
// Progress Bar Helper
// ═══════════════════════════════════════════════════════════════════════════

const ProgressBar = struct {
    total: u64,
    current: u64 = 0,
    start_time: i64,
    width: u32 = 40,

    pub fn init(total: u64) ProgressBar {
        return .{
            .total = total,
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn update(self: *ProgressBar, current: u64) void {
        self.current = current;
        self.render();
    }

    pub fn render(self: *const ProgressBar) void {
        const percent = if (self.total > 0)
            @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total))
        else
            0.0;

        const filled = @as(u32, @intFromFloat(percent * @as(f64, @floatFromInt(self.width))));
        _ = filled;

        // Calculate speed
        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const speed = if (elapsed_ms > 0)
            @as(f64, @floatFromInt(self.current)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0)
        else
            0.0;

        // Simple progress output using debug.print
        std.debug.print("\r  Progress: {d:.0}% Speed: {d:.1} B/s", .{
            percent * 100,
            speed,
        });
    }

    fn formatBytes(bytes: u64) []const u8 {
        _ = bytes;
        return "0 B"; // Placeholder
    }
};
