//! wardenctl - Guardian Shield V8.2 Control CLI
//!
//! Runtime configuration management for libwarden.so
//!
//! Commands:
//!   wardenctl add -p . --template dev       # Protect current directory with template
//!   wardenctl add --path /some/path [--no-delete] [--no-move] [--read-only]
//!   wardenctl remove --path /some/path      # Requires sudo
//!   wardenctl list                          # Show all protected paths
//!   wardenctl reload                        # Signal running processes to reload config
//!   wardenctl status                        # Show shield status
//!   wardenctl test /some/path <operation>   # Test if operation would be blocked
//!   wardenctl disable                       # Temporarily disable (create magic file)
//!   wardenctl enable                        # Re-enable (remove magic file)
//!   wardenctl uninstall                     # Uninstall Guardian Shield from system
//!   wardenctl emergency                     # Show emergency recovery procedures
//!
//! Templates:
//!   --template safe       = --no-delete --no-move
//!   --template dev        = --no-delete --no-move --no-truncate
//!   --template readonly   = --read-only
//!   --template production = --read-only (full immutability)
//!
//! Operations:
//!   delete, move, truncate, symlink, link, mkdir, write

const std = @import("std");
const fs = std.fs;
const Io = std.Io;
const json = std.json;

/// Get current working directory (Zig 0.16 compatible - std.process.getCwd removed)
fn getCwd(buf: []u8) ![]u8 {
    const result = std.os.linux.getcwd(buf.ptr, buf.len);
    if (result == 0) return error.Unexpected;
    // Check for error (high bit set means error code in lower bits)
    if (@as(isize, @bitCast(result)) < 0) return error.Unexpected;
    // Result is the length including null terminator
    return buf[0 .. result - 1];
}

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const VERSION = "8.2.0";
const CONFIG_PATH = "/etc/warden/warden-config.json";
const DEV_CONFIG_PATH = "/home/founder/zig_forge/config/warden-config.json";

// ============================================================
// Protection Templates
// ============================================================

const Template = enum {
    safe, // --no-delete --no-move
    dev, // --no-delete --no-move --no-truncate
    readonly, // --read-only
    production, // --read-only (maximum security)

    fn toFlags(self: Template) PermissionFlags {
        return switch (self) {
            .safe => PermissionFlags{
                .no_delete = true,
                .no_move = true,
            },
            .dev => PermissionFlags{
                .no_delete = true,
                .no_move = true,
                .no_truncate = true,
            },
            .readonly, .production => PermissionFlags{
                .read_only = true,
            },
        };
    }

    fn description(self: Template) []const u8 {
        return switch (self) {
            .safe => "Safe template: no-delete, no-move",
            .dev => "Development template: no-delete, no-move, no-truncate",
            .readonly => "Read-only template: full immutability",
            .production => "Production template: full immutability",
        };
    }
};

// ============================================================
// Command Line Parsing
// ============================================================

const Command = enum {
    add,
    remove,
    list,
    reload,
    status,
    @"test",
    disable,
    enable,
    uninstall,
    emergency,
    help,
    version,
};

const PermissionFlags = struct {
    no_delete: bool = false,
    no_move: bool = false,
    no_truncate: bool = false,
    no_write: bool = false, // Blocks open_write only
    no_symlink: bool = false,
    no_link: bool = false,
    no_mkdir: bool = false,
    read_only: bool = false, // Implies all of the above
};

const Args = struct {
    command: Command,
    path: ?[]const u8 = null,
    resolved_path: ?[]const u8 = null, // Absolute path after resolving "."
    operation: ?[]const u8 = null,
    flags: PermissionFlags = .{},
    template: ?Template = null,
    description: ?[]const u8 = null,
    config_file: []const u8 = DEV_CONFIG_PATH,
    verbose: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator, init: std.process.Init) !Args {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // Skip program name

    var result = Args{ .command = .help };

    // Parse command
    if (args.next()) |cmd| {
        result.command = std.meta.stringToEnum(Command, cmd) orelse .help;
    } else {
        return result;
    }

    // Parse remaining arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--path") or std.mem.eql(u8, arg, "-p")) {
            result.path = args.next();
        } else if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "-t")) {
            if (args.next()) |tmpl| {
                result.template = std.meta.stringToEnum(Template, tmpl);
            }
        } else if (std.mem.eql(u8, arg, "--no-delete")) {
            result.flags.no_delete = true;
        } else if (std.mem.eql(u8, arg, "--no-move")) {
            result.flags.no_move = true;
        } else if (std.mem.eql(u8, arg, "--no-truncate")) {
            result.flags.no_truncate = true;
        } else if (std.mem.eql(u8, arg, "--no-symlink")) {
            result.flags.no_symlink = true;
        } else if (std.mem.eql(u8, arg, "--no-link")) {
            result.flags.no_link = true;
        } else if (std.mem.eql(u8, arg, "--no-mkdir")) {
            result.flags.no_mkdir = true;
        } else if (std.mem.eql(u8, arg, "--no-write")) {
            result.flags.no_write = true;
        } else if (std.mem.eql(u8, arg, "--read-only") or std.mem.eql(u8, arg, "-r")) {
            result.flags.read_only = true;
        } else if (std.mem.eql(u8, arg, "--description") or std.mem.eql(u8, arg, "-d")) {
            result.description = args.next();
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            result.config_file = args.next() orelse DEV_CONFIG_PATH;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            result.verbose = true;
        } else if (result.path == null and !std.mem.startsWith(u8, arg, "-")) {
            // Positional argument - path or operation
            if (result.command == .@"test") {
                if (result.path == null) {
                    result.path = arg;
                } else {
                    result.operation = arg;
                }
            } else {
                result.path = arg;
            }
        }
    }

    // Resolve "." to absolute path
    if (result.path) |path| {
        if (std.mem.eql(u8, path, ".")) {
            // Get current working directory
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = getCwd(&cwd_buf) catch {
                std.debug.print("Error: Could not resolve current directory\n", .{});
                return result;
            };
            // Allocate and copy the resolved path
            const resolved = try allocator.dupe(u8, cwd);
            result.resolved_path = resolved;
        } else if (std.mem.startsWith(u8, path, "./")) {
            // Relative path - resolve to absolute by prepending cwd
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = getCwd(&cwd_buf) catch {
                // If can't resolve, use as-is
                result.resolved_path = path;
                return result;
            };
            // Construct full path: cwd + "/" + path[2..] (skip "./")
            const rel_part = path[2..];
            const resolved = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, rel_part }) catch {
                result.resolved_path = path;
                return result;
            };
            result.resolved_path = resolved;
        } else {
            result.resolved_path = path;
        }
    }

    // Apply template flags if specified
    if (result.template) |tmpl| {
        result.flags = tmpl.toFlags();
    }

    return result;
}

// ============================================================
// Configuration Management
// ============================================================

fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !json.Parsed(json.Value) {
    // Create null-terminated path
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd = c.open(@ptrCast(&path_buf), c.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    // Get file size using lseek
    const file_size_raw = c.lseek(fd, 0, c.SEEK_END);
    if (file_size_raw < 0) return error.SeekFailed;
    _ = c.lseek(fd, 0, c.SEEK_SET);
    const file_size: usize = @intCast(file_size_raw);

    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);

    // Read file using c
    var bytes_read: usize = 0;
    while (bytes_read < file_size) {
        const n_raw = c.read(fd, content[bytes_read..].ptr, content.len - bytes_read);
        if (n_raw <= 0) break;
        bytes_read += @intCast(n_raw);
    }

    return json.parseFromSlice(json.Value, allocator, content, .{});
}

fn saveConfig(allocator: std.mem.Allocator, path: []const u8, config: json.Value) !void {
    _ = allocator;

    // Create null-terminated path
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd = c.open(@ptrCast(&path_buf), c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    // Use the fmt API for stringification - write directly to file
    const formatted = json.fmt(config, .{ .whitespace = .indent_2 });

    // Use a fixed buffer for output
    var buffer: [65536]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "{any}", .{formatted}) catch {
        std.debug.print("Error: Config too large for buffer\n", .{});
        return error.BufferTooSmall;
    };

    const write_result = c.write(fd, output.ptr, output.len);
    if (write_result < 0) return error.WriteError;
}

fn flagsToOperations(flags: PermissionFlags) []const []const u8 {
    // Use a static buffer since we're returning a slice of compile-time strings
    const S = struct {
        var ops: [20][]const u8 = undefined;
    };
    var count: usize = 0;

    if (flags.read_only) {
        // Read-only implies all write operations blocked
        S.ops[count] = "unlink";
        count += 1;
        S.ops[count] = "unlinkat";
        count += 1;
        S.ops[count] = "rmdir";
        count += 1;
        S.ops[count] = "open_write";
        count += 1;
        S.ops[count] = "rename";
        count += 1;
        S.ops[count] = "truncate";
        count += 1;
        S.ops[count] = "symlink";
        count += 1;
        S.ops[count] = "symlink_target";
        count += 1;
        S.ops[count] = "link";
        count += 1;
        S.ops[count] = "mkdir";
        count += 1;
        return S.ops[0..count];
    }

    if (flags.no_delete) {
        S.ops[count] = "unlink";
        count += 1;
        S.ops[count] = "unlinkat";
        count += 1;
        S.ops[count] = "rmdir";
        count += 1;
    }

    if (flags.no_move) {
        S.ops[count] = "rename";
        count += 1;
    }

    if (flags.no_truncate) {
        S.ops[count] = "truncate";
        count += 1;
    }

    if (flags.no_write) {
        S.ops[count] = "open_write";
        count += 1;
    }

    if (flags.no_symlink) {
        S.ops[count] = "symlink";
        count += 1;
        S.ops[count] = "symlink_target";
        count += 1;
    }

    if (flags.no_link) {
        S.ops[count] = "link";
        count += 1;
    }

    if (flags.no_mkdir) {
        S.ops[count] = "mkdir";
        count += 1;
    }

    return S.ops[0..count];
}

// ============================================================
// Commands
// ============================================================

fn cmdAdd(allocator: std.mem.Allocator, args: Args) !void {
    // Use resolved path (handles "." → absolute path)
    const path = args.resolved_path orelse args.path orelse {
        std.debug.print("Error: --path required\n", .{});
        std.debug.print("Usage: wardenctl add -p /path/to/protect [--template dev]\n", .{});
        std.debug.print("       wardenctl add -p . --template safe\n", .{});
        return;
    };

    // Ensure path ends with / for directory protection
    var path_with_slash: [std.fs.max_path_bytes + 1]u8 = undefined;
    const final_path = if (!std.mem.endsWith(u8, path, "/")) blk: {
        const len = @min(path.len, std.fs.max_path_bytes);
        @memcpy(path_with_slash[0..len], path[0..len]);
        path_with_slash[len] = '/';
        break :blk path_with_slash[0 .. len + 1];
    } else path;

    // Show what we're doing
    if (args.template) |tmpl| {
        std.debug.print("Adding protected path: {s}\n", .{final_path});
        std.debug.print("Template: {s}\n", .{tmpl.description()});
    } else {
        std.debug.print("Adding protected path: {s}\n", .{final_path});
    }

    var parsed = loadConfig(allocator, args.config_file) catch |err| {
        std.debug.print("Error loading config: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    // Navigate to protection.protected_paths array
    const root = parsed.value.object;
    const protection = root.get("protection") orelse {
        std.debug.print("Error: Invalid config - missing 'protection' section\n", .{});
        return;
    };

    var protected_paths = protection.object.get("protected_paths") orelse {
        std.debug.print("Error: Invalid config - missing 'protected_paths' array\n", .{});
        return;
    };

    // Check if path already exists
    for (protected_paths.array.items) |item| {
        const existing_path = item.object.get("path") orelse continue;
        if (std.mem.eql(u8, existing_path.string, final_path)) {
            std.debug.print("Path already protected: {s}\n", .{final_path});
            return;
        }
    }

    // Build operations list
    const ops = flagsToOperations(args.flags);
    if (ops.len == 0) {
        std.debug.print("Warning: No operations specified. Use --template, --no-delete, --no-move, --read-only, etc.\n", .{});
        std.debug.print("Defaulting to --template safe (--no-delete --no-move)\n", .{});
    }

    // Generate description
    const desc = if (args.description) |d|
        d
    else if (args.template) |tmpl|
        tmpl.description()
    else
        "Added via wardenctl";

    // Create new entry
    var new_entry = json.ObjectMap.init(allocator);
    try new_entry.put("path", json.Value{ .string = final_path });
    try new_entry.put("description", json.Value{ .string = desc });

    var ops_array = json.Array.init(allocator);
    for (ops) |op| {
        try ops_array.append(json.Value{ .string = op });
    }
    // If no ops specified, use read-only defaults
    if (ops.len == 0) {
        const default_ops = [_][]const u8{ "unlink", "unlinkat", "rmdir", "open_write", "rename", "truncate", "symlink", "link", "mkdir" };
        for (default_ops) |op| {
            try ops_array.append(json.Value{ .string = op });
        }
    }
    try new_entry.put("block_operations", json.Value{ .array = ops_array });

    try protected_paths.array.append(json.Value{ .object = new_entry });

    // Save config
    try saveConfig(allocator, args.config_file, parsed.value);

    std.debug.print("✓ Added: {s}\n", .{path});
    std.debug.print("  Config: {s}\n", .{args.config_file});
    std.debug.print("  Note: Run 'wardenctl reload' to apply changes to running processes\n", .{});
}

fn cmdRemove(allocator: std.mem.Allocator, args: Args) !void {
    const path = args.path orelse {
        std.debug.print("Error: --path required\n", .{});
        return;
    };

    std.debug.print("Removing protected path: {s}\n", .{path});

    var parsed = loadConfig(allocator, args.config_file) catch |err| {
        std.debug.print("Error loading config: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const protection = root.get("protection") orelse return;
    var protected_paths = protection.object.get("protected_paths") orelse return;

    // Find and remove path
    var found = false;
    var i: usize = 0;
    while (i < protected_paths.array.items.len) {
        const item = protected_paths.array.items[i];
        const existing_path = item.object.get("path") orelse {
            i += 1;
            continue;
        };
        if (std.mem.eql(u8, existing_path.string, path)) {
            _ = protected_paths.array.orderedRemove(i);
            found = true;
            break;
        }
        i += 1;
    }

    if (!found) {
        std.debug.print("Path not found in config: {s}\n", .{path});
        return;
    }

    try saveConfig(allocator, args.config_file, parsed.value);
    std.debug.print("✓ Removed: {s}\n", .{path});
    std.debug.print("  Note: Run 'wardenctl reload' to apply changes to running processes\n", .{});
}

fn cmdList(allocator: std.mem.Allocator, args: Args) !void {
    var parsed = loadConfig(allocator, args.config_file) catch |err| {
        std.debug.print("Error loading config: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const global = root.get("global") orelse return;
    const enabled = global.object.get("enabled") orelse return;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Guardian Shield V8.0 - Protected Paths                  ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("Status: {s}\n", .{if (enabled.bool) "🛡️  ACTIVE" else "⚠️  DISABLED"});
    std.debug.print("Config: {s}\n\n", .{args.config_file});

    const protection = root.get("protection") orelse return;
    const protected_paths = protection.object.get("protected_paths") orelse return;

    std.debug.print("Protected Paths ({d}):\n", .{protected_paths.array.items.len});
    std.debug.print("─────────────────────────────────────────────────────────────\n", .{});

    for (protected_paths.array.items) |item| {
        const path = item.object.get("path") orelse continue;
        const desc = item.object.get("description") orelse json.Value{ .string = "" };
        const ops = item.object.get("block_operations") orelse continue;

        std.debug.print("\n  📁 {s}\n", .{path.string});
        std.debug.print("     {s}\n", .{desc.string});
        std.debug.print("     Blocked: ", .{});
        for (ops.array.items, 0..) |op, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{op.string});
        }
        std.debug.print("\n", .{});
    }

    const whitelisted_paths = protection.object.get("whitelisted_paths") orelse return;
    std.debug.print("\nWhitelisted Paths ({d}):\n", .{whitelisted_paths.array.items.len});
    std.debug.print("─────────────────────────────────────────────────────────────\n", .{});

    for (whitelisted_paths.array.items) |item| {
        const path = item.object.get("path") orelse continue;
        const desc = item.object.get("description") orelse json.Value{ .string = "" };
        std.debug.print("  ✓ {s} - {s}\n", .{ path.string, desc.string });
    }

    std.debug.print("\n", .{});
}

fn cmdReload(_: std.mem.Allocator, _: Args) !void {
    std.debug.print("Sending SIGHUP to processes with libwarden.so loaded...\n", .{});

    // Get io context for directory operations
    const io = std.Io.Threaded.global_single_threaded.io();

    // Find all processes using libwarden.so
    var dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch {
        std.debug.print("Error: Cannot access /proc\n", .{});
        return;
    };
    defer dir.close(io);

    var reload_count: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        // Skip non-numeric entries (not PIDs)
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        // Check if process has libwarden.so loaded
        var path_buf: [256]u8 = undefined;
        const maps_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/maps", .{pid}) catch continue;

        // Create null-terminated path for posix.open
        if (maps_path.len >= path_buf.len - 1) continue;
        path_buf[maps_path.len] = 0;

        const maps_fd = c.open(@ptrCast(&path_buf), c.O_RDONLY, @as(c_uint, 0));
        if (maps_fd < 0) continue;
        defer _ = c.close(maps_fd);

        var buf: [4096]u8 = undefined;
        const bytes_read_raw = c.read(maps_fd, &buf, buf.len);
        if (bytes_read_raw <= 0) continue;
        const content = buf[0..@intCast(bytes_read_raw)];

        if (std.mem.indexOf(u8, content, "libwarden.so") != null) {
            // Send SIGHUP
            _ = std.os.linux.kill(pid, std.os.linux.SIG.HUP);
            std.debug.print("  Signaled PID {d}\n", .{pid});
            reload_count += 1;
        }
    }

    if (reload_count == 0) {
        std.debug.print("No processes found with libwarden.so loaded.\n", .{});
        std.debug.print("Note: New processes will load the updated config automatically.\n", .{});
    } else {
        std.debug.print("✓ Sent SIGHUP to {d} process(es)\n", .{reload_count});
    }
}

fn cmdStatus(allocator: std.mem.Allocator, args: Args) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Guardian Shield V8.0 - Status                           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Check if libwarden.so exists
    const lib_paths = [_][]const u8{
        "/usr/lib/libwarden.so",
        "/home/founder/zig_forge/zig-out/lib/libwarden.so",
    };

    std.debug.print("Library Status:\n", .{});
    for (lib_paths) |lib_path| {
        // Use posix to check file existence and get size
        var path_buf_lib: [fs.max_path_bytes]u8 = undefined;
        if (lib_path.len >= path_buf_lib.len) continue;
        @memcpy(path_buf_lib[0..lib_path.len], lib_path);
        path_buf_lib[lib_path.len] = 0;

        const fd = c.open(@ptrCast(&path_buf_lib), c.O_RDONLY, @as(c_uint, 0));
        if (fd < 0) {
            std.debug.print("  ❌ {s} (not found)\n", .{lib_path});
            continue;
        }
        defer _ = c.close(fd);
        const size = c.lseek(fd, 0, c.SEEK_END);
        std.debug.print("  ✓ {s} ({d} bytes)\n", .{ lib_path, size });
    }

    // Check config files
    std.debug.print("\nConfiguration Status:\n", .{});
    const config_paths = [_][]const u8{
        CONFIG_PATH,
        DEV_CONFIG_PATH,
    };

    for (config_paths) |config_path| {
        var path_buf_cfg: [fs.max_path_bytes]u8 = undefined;
        if (config_path.len >= path_buf_cfg.len) continue;
        @memcpy(path_buf_cfg[0..config_path.len], config_path);
        path_buf_cfg[config_path.len] = 0;

        const fd = c.open(@ptrCast(&path_buf_cfg), c.O_RDONLY, @as(c_uint, 0));
        if (fd < 0) {
            std.debug.print("  ❌ {s} (not found)\n", .{config_path});
            continue;
        }
        defer _ = c.close(fd);
        const size = c.lseek(fd, 0, c.SEEK_END);
        std.debug.print("  ✓ {s} ({d} bytes)\n", .{ config_path, size });
    }

    // Count processes using libwarden
    std.debug.print("\nActive Processes:\n", .{});
    var process_count: u32 = 0;

    const io = Io.Threaded.global_single_threaded.io();
    var dir = Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch {
        std.debug.print("  ❌ Cannot access /proc\n", .{});
        return;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        var path_buf: [256]u8 = undefined;
        const maps_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/maps", .{pid}) catch continue;

        const maps_file = Io.Dir.openFileAbsolute(io, maps_path, .{}) catch continue;
        defer maps_file.close(io);

        var buf: [8192]u8 = undefined;
        const bytes_read = maps_file.readStreaming(io, &.{&buf}) catch continue;
        const content = buf[0..bytes_read];

        if (std.mem.indexOf(u8, content, "libwarden.so") != null) {
            process_count += 1;
            if (args.verbose) {
                // Get process name
                var comm_path_buf: [256]u8 = undefined;
                const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{pid}) catch continue;
                const comm_file = Io.Dir.openFileAbsolute(io, comm_path, .{}) catch continue;
                defer comm_file.close(io);

                var comm_buf: [256]u8 = undefined;
                const comm_len = comm_file.readStreaming(io, &.{&comm_buf}) catch continue;
                const comm = std.mem.trimEnd(u8, comm_buf[0..comm_len], "\n");
                std.debug.print("  PID {d}: {s}\n", .{ pid, comm });
            }
        }
    }

    std.debug.print("  🛡️  {d} process(es) protected by Guardian Shield\n", .{process_count});

    // Show config summary
    var parsed = loadConfig(allocator, args.config_file) catch {
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const protection = root.get("protection") orelse return;
    const protected_paths = protection.object.get("protected_paths") orelse return;
    const whitelisted_paths = protection.object.get("whitelisted_paths") orelse return;

    std.debug.print("\nConfiguration Summary:\n", .{});
    std.debug.print("  Protected paths:   {d}\n", .{protected_paths.array.items.len});
    std.debug.print("  Whitelisted paths: {d}\n", .{whitelisted_paths.array.items.len});
    std.debug.print("\n", .{});
}

fn cmdTest(allocator: std.mem.Allocator, args: Args) !void {
    const path = args.path orelse {
        std.debug.print("Error: Path required\n", .{});
        std.debug.print("Usage: wardenctl test /some/path [operation]\n", .{});
        return;
    };

    const operation = args.operation orelse "all";

    std.debug.print("\nTesting path: {s}\n", .{path});
    std.debug.print("Operation: {s}\n\n", .{operation});

    var parsed = loadConfig(allocator, args.config_file) catch |err| {
        std.debug.print("Error loading config: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const protection = root.get("protection") orelse return;
    const protected_paths = protection.object.get("protected_paths") orelse return;
    const whitelisted_paths = protection.object.get("whitelisted_paths") orelse return;

    // Check if whitelisted
    for (whitelisted_paths.array.items) |item| {
        const whitelist_path = item.object.get("path") orelse continue;
        if (std.mem.startsWith(u8, path, whitelist_path.string)) {
            std.debug.print("✓ Path is WHITELISTED (via {s})\n", .{whitelist_path.string});
            std.debug.print("  All operations ALLOWED\n", .{});
            return;
        }
    }

    // Check if protected
    for (protected_paths.array.items) |item| {
        const protected_path = item.object.get("path") orelse continue;
        if (std.mem.startsWith(u8, path, protected_path.string)) {
            const ops = item.object.get("block_operations") orelse continue;

            std.debug.print("🛡️  Path is PROTECTED (via {s})\n\n", .{protected_path.string});

            if (std.mem.eql(u8, operation, "all")) {
                std.debug.print("Blocked operations:\n", .{});
                for (ops.array.items) |op| {
                    std.debug.print("  ❌ {s}\n", .{op.string});
                }
            } else {
                // Check specific operation
                var blocked = false;
                for (ops.array.items) |op| {
                    if (std.mem.eql(u8, op.string, operation)) {
                        blocked = true;
                        break;
                    }
                }
                if (blocked) {
                    std.debug.print("❌ Operation '{s}' would be BLOCKED\n", .{operation});
                } else {
                    std.debug.print("✓ Operation '{s}' would be ALLOWED\n", .{operation});
                }
            }
            return;
        }
    }

    std.debug.print("✓ Path is NOT PROTECTED\n", .{});
    std.debug.print("  All operations ALLOWED\n", .{});
}

// ============================================================
// V8.2: Emergency Recovery Commands
// ============================================================

const MAGIC_FILE = "/tmp/.warden_emergency_disable";
const MAGIC_FILE_ROOT = "/var/run/warden_emergency_disable";
const LD_PRELOAD_PATH = "/etc/ld.so.preload";
const LIB_PATH = "/usr/local/lib/security/libwarden.so";
const BACKUP_DIR = "/usr/local/lib/security/backup";

fn cmdDisable(_: std.mem.Allocator, _: Args) !void {
    const io = Io.Threaded.global_single_threaded.io();
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Guardian Shield V8.2 - Temporary Disable                ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Create the magic file to disable protection
    const file = Io.Dir.cwd().createFile(io, MAGIC_FILE, .{}) catch |err| {
        std.debug.print("❌ Failed to create {s}: {any}\n", .{ MAGIC_FILE, err });
        std.debug.print("\nTry with sudo or use environment variable instead:\n", .{});
        std.debug.print("  WARDEN_DISABLE=1 <command>\n", .{});
        return;
    };
    file.close(io);

    std.debug.print("✓ Guardian Shield DISABLED\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("The magic file has been created:\n", .{});
    std.debug.print("  {s}\n", .{MAGIC_FILE});
    std.debug.print("\n", .{});
    std.debug.print("All processes will now bypass protection.\n", .{});
    std.debug.print("To re-enable: wardenctl enable\n", .{});
    std.debug.print("\n", .{});
}

fn cmdEnable(_: std.mem.Allocator, _: Args) !void {
    const io = Io.Threaded.global_single_threaded.io();
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Guardian Shield V8.2 - Re-enable                        ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Remove the magic file
    Io.Dir.cwd().deleteFile(io, MAGIC_FILE) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("✓ Guardian Shield is already ENABLED\n", .{});
            std.debug.print("  (magic file does not exist)\n", .{});
        } else {
            std.debug.print("❌ Failed to remove {s}: {any}\n", .{ MAGIC_FILE, err });
        }
        return;
    };

    std.debug.print("✓ Guardian Shield RE-ENABLED\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Protection is now active for all processes.\n", .{});
    std.debug.print("\n", .{});
}

fn cmdUninstall(_: std.mem.Allocator, _: Args) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Guardian Shield V8.2 - Uninstall                        ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("⚠️  This will completely remove Guardian Shield from your system.\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("To uninstall, run these commands as root:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  ┌─────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("  │ # Step 1: Remove from ld.so.preload (CRITICAL)          │\n", .{});
    std.debug.print("  │ sudo rm /etc/ld.so.preload                              │\n", .{});
    std.debug.print("  │ # -OR- edit it to remove the libwarden.so line          │\n", .{});
    std.debug.print("  │                                                         │\n", .{});
    std.debug.print("  │ # Step 2: Remove library files                          │\n", .{});
    std.debug.print("  │ sudo rm -rf /usr/local/lib/security/libwarden*          │\n", .{});
    std.debug.print("  │                                                         │\n", .{});
    std.debug.print("  │ # Step 3: Remove config (optional)                      │\n", .{});
    std.debug.print("  │ sudo rm -rf /etc/warden                                 │\n", .{});
    std.debug.print("  │                                                         │\n", .{});
    std.debug.print("  │ # Step 4: Remove wardenctl (optional)                   │\n", .{});
    std.debug.print("  │ sudo rm /usr/local/bin/wardenctl                        │\n", .{});
    std.debug.print("  └─────────────────────────────────────────────────────────┘\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("After removing /etc/ld.so.preload, new processes will no longer\n", .{});
    std.debug.print("load libwarden.so. Running processes are unaffected until restart.\n", .{});
    std.debug.print("\n", .{});
}

fn cmdEmergency(_: std.mem.Allocator, _: Args) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Guardian Shield V8.2 - EMERGENCY RECOVERY               ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("If you are LOCKED OUT and cannot run commands normally,\n", .{});
    std.debug.print("use one of these recovery methods:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("METHOD 1: Environment Variable (Easiest)\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Prefix any command with WARDEN_DISABLE=1:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    WARDEN_DISABLE=1 bash\n", .{});
    std.debug.print("    WARDEN_DISABLE=1 sudo rm /etc/ld.so.preload\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("METHOD 2: Magic Kill Switch File\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Create this file to disable ALL protection:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    touch /tmp/.warden_emergency_disable\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Or as root:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    touch /var/run/warden_emergency_disable\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("METHOD 3: Signal Handler (For Running Processes)\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Send SIGUSR2 to any process to disable its protection:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    kill -USR2 <pid>\n", .{});
    std.debug.print("    pkill -USR2 -f bash\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("METHOD 4: Kernel Boot Parameter\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Add to kernel cmdline at boot (GRUB):\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    warden.disable=1\n", .{});
    std.debug.print("    guardian.disable=1\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("METHOD 5: Restore Backup (Nuclear Option)\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Backups are stored in: /usr/local/lib/security/backup/\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  To restore a known-good version:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    WARDEN_DISABLE=1 sudo cp \\\n", .{});
    std.debug.print("      /usr/local/lib/security/backup/libwarden.so.YYYYMMDD_HHMMSS \\\n", .{});
    std.debug.print("      /usr/local/lib/security/libwarden.so\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("COMPLETE REMOVAL (Last Resort)\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  To completely remove Guardian Shield:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    WARDEN_DISABLE=1 sudo rm /etc/ld.so.preload\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Then open a new terminal - libwarden will no longer load.\n", .{});
    std.debug.print("\n", .{});
}

fn printHelp() void {
    std.debug.print(
        \\
        \\wardenctl - Guardian Shield V8.2 Control CLI
        \\
        \\Usage: wardenctl <command> [options]
        \\
        \\Commands:
        \\  add        Add a protected path
        \\  remove     Remove a protected path (requires sudo)
        \\  list       List all protected paths
        \\  reload     Signal processes to reload config
        \\  status     Show shield status
        \\  test       Test if a path/operation would be blocked
        \\  disable    Temporarily disable protection (create magic file)
        \\  enable     Re-enable protection (remove magic file)
        \\  uninstall  Show uninstall instructions
        \\  emergency  Show ALL emergency recovery methods
        \\  help       Show this help
        \\  version    Show version
        \\
        \\Options for 'add':
        \\  -p, --path <path>   Path to protect (use "." for current directory)
        \\  -t, --template <t>  Protection template (safe, dev, readonly, production)
        \\  -d, --description   Description for the path
        \\  --no-delete         Block unlink, unlinkat, rmdir
        \\  --no-move           Block rename
        \\  --no-truncate       Block truncate
        \\  --no-write          Block open for writing
        \\  --no-symlink        Block symlink creation
        \\  --no-link           Block hardlink creation
        \\  --no-mkdir          Block directory creation
        \\  -r, --read-only     Block all write/modify operations
        \\
        \\Templates:
        \\  safe        --no-delete --no-move (prevent accidental damage)
        \\  dev         --no-delete --no-move --no-truncate (development)
        \\  readonly    --read-only (full immutability)
        \\  production  --read-only (maximum security)
        \\
        \\General Options:
        \\  -c, --config <file>  Config file path
        \\  -v, --verbose        Verbose output
        \\
        \\Examples:
        \\  wardenctl add -p . --template dev        # Protect current directory
        \\  wardenctl add -p . --template safe       # Basic protection
        \\  wardenctl add -p /home/user/project -r   # Full read-only
        \\  wardenctl remove /home/user/project
        \\  wardenctl list
        \\  wardenctl test /etc/passwd delete
        \\  wardenctl reload
        \\  wardenctl disable                        # Quick disable
        \\  wardenctl emergency                      # See all recovery options
        \\
        \\Emergency Recovery (if locked out):
        \\  WARDEN_DISABLE=1 <command>               # Bypass for single command
        \\  touch /tmp/.warden_emergency_disable     # Disable for all processes
        \\  wardenctl emergency                      # Full recovery guide
        \\
    , .{});
}

// ============================================================
// Main
// ============================================================

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    const args = try parseArgs(allocator, init);

    switch (args.command) {
        .add => try cmdAdd(allocator, args),
        .remove => try cmdRemove(allocator, args),
        .list => try cmdList(allocator, args),
        .reload => try cmdReload(allocator, args),
        .status => try cmdStatus(allocator, args),
        .@"test" => try cmdTest(allocator, args),
        .disable => try cmdDisable(allocator, args),
        .enable => try cmdEnable(allocator, args),
        .uninstall => try cmdUninstall(allocator, args),
        .emergency => try cmdEmergency(allocator, args),
        .version => std.debug.print("wardenctl v{s}\n", .{VERSION}),
        .help => printHelp(),
    }
}
