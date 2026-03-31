// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! trash_file tool implementation
//! Safely moves files to trash instead of permanent deletion

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const TrashFileArgs = struct {
    path: []const u8,
};

/// Execute trash_file tool - moves file to trash/recycle bin
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: TrashFileArgs,
    max_file_size: usize,
) !types.ToolOutput {
    _ = max_file_size;

    // Validate path is within sandbox
    const canonical_path = sandbox.validatePath(args.path) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
            else => "Invalid path",
        });
    };
    defer allocator.free(canonical_path);

    // Check file exists by trying to open it
    const path_z = try allocator.allocSentinel(u8, canonical_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, canonical_path);

    // Try to open the file to verify it exists and is readable
    const file = std.c.fopen(path_z.ptr, "rb");
    if (file == null) {
        return types.ToolOutput.error_result(allocator, "File does not exist - it may have already been deleted or moved to trash");
    }
    _ = std.c.fclose(file.?);

    // Check if it's a directory by trying to open as directory
    const dir = std.c.opendir(path_z.ptr);
    if (dir != null) {
        _ = std.c.closedir(dir.?);
        return types.ToolOutput.error_result(allocator, "Path is a directory, not a file");
    }

    // Move to trash based on platform
    const result = moveToTrash(allocator, canonical_path, path_z.ptr);

    if (result) |trash_path| {
        defer allocator.free(trash_path);
        const msg = try std.fmt.allocPrint(allocator, "Moved to trash: {s}", .{trash_path});
        return types.ToolOutput{
            .success = true,
            .content = msg,
            .allocator = allocator,
        };
    } else |err| {
        const msg = switch (err) {
            error.TrashNotSupported => "Trash not supported on this platform",
            error.TrashFailed => "Failed to move file to trash",
            error.OutOfMemory => "Out of memory",
        };
        return types.ToolOutput.error_result(allocator, msg);
    }
}

const TrashError = error{
    TrashNotSupported,
    TrashFailed,
    OutOfMemory,
};

/// Move file to trash - platform specific
fn moveToTrash(allocator: std.mem.Allocator, path: []const u8, path_z: [*:0]const u8) TrashError![]const u8 {
    if (comptime builtin.os.tag == .macos) {
        return moveToTrashMacOS(allocator, path, path_z);
    } else if (comptime builtin.os.tag == .linux) {
        return moveToTrashLinux(allocator, path);
    } else {
        return error.TrashNotSupported;
    }
}

/// macOS: Use 'trash' command if available, otherwise mv to ~/.Trash
fn moveToTrashMacOS(allocator: std.mem.Allocator, path: []const u8, path_z: [*:0]const u8) TrashError![]const u8 {
    // Try using the 'trash' command first (from Homebrew trash-cli)
    // This properly integrates with Finder's trash
    const trash_cmd = std.fmt.allocPrint(allocator, "trash \"{s}\" 2>/dev/null", .{path}) catch return error.OutOfMemory;
    defer allocator.free(trash_cmd);

    const trash_cmd_z = allocator.allocSentinel(u8, trash_cmd.len, 0) catch return error.OutOfMemory;
    defer allocator.free(trash_cmd_z);
    @memcpy(trash_cmd_z, trash_cmd);

    // Try trash command
    const pid = std.c.fork();
    if (pid < 0) {
        // Fork failed, fall back to manual move
        return moveToTrashManual(allocator, path, path_z, "/.Trash");
    }

    if (pid == 0) {
        // Child process
        const shell = "/bin/sh";
        const argv = [_:null]?[*:0]const u8{ shell, "-c", trash_cmd_z.ptr, null };
        _ = std.c.execve(shell, &argv, std.c.environ);
        std.c.exit(127);
    }

    // Parent: wait for child
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const exit_code = (status >> 8) & 0xFF;
    if (exit_code == 0) {
        // Success with trash command
        const result = std.fmt.allocPrint(allocator, "~/.Trash/{s}", .{std.fs.path.basename(path)}) catch return error.OutOfMemory;
        return result;
    }

    // Fall back to manual ~/.Trash move
    return moveToTrashManual(allocator, path, path_z, "/.Trash");
}

/// Linux: Use freedesktop.org trash spec (~/.local/share/Trash)
fn moveToTrashLinux(allocator: std.mem.Allocator, path: []const u8) TrashError![]const u8 {
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch return error.OutOfMemory;
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    return moveToTrashManual(allocator, path, path_z.ptr, "/.local/share/Trash/files");
}

/// Manual trash: move file to trash directory with timestamp to avoid conflicts
fn moveToTrashManual(allocator: std.mem.Allocator, path: []const u8, path_z: [*:0]const u8, trash_suffix: []const u8) TrashError![]const u8 {
    // Get home directory
    const home = std.c.getenv("HOME") orelse return error.TrashFailed;
    const home_str = std.mem.span(home);

    // Get timestamp for unique naming - Zig 0.16 compatible
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const timestamp = ts.sec;

    // Build trash path: ~/.Trash/filename.timestamp or ~/.local/share/Trash/files/filename.timestamp
    const basename = std.fs.path.basename(path);
    const trash_path = std.fmt.allocPrint(allocator, "{s}{s}/{s}.{d}", .{
        home_str,
        trash_suffix,
        basename,
        timestamp,
    }) catch return error.OutOfMemory;
    errdefer allocator.free(trash_path);

    // Ensure trash directory exists
    const trash_dir = std.fmt.allocPrint(allocator, "{s}{s}", .{ home_str, trash_suffix }) catch return error.OutOfMemory;
    defer allocator.free(trash_dir);

    const trash_dir_z = allocator.allocSentinel(u8, trash_dir.len, 0) catch return error.OutOfMemory;
    defer allocator.free(trash_dir_z);
    @memcpy(trash_dir_z, trash_dir);

    // Create trash directory if needed (mkdir -p equivalent)
    _ = std.c.mkdir(trash_dir_z.ptr, 0o755);

    // Move file using rename
    const trash_path_z = allocator.allocSentinel(u8, trash_path.len, 0) catch return error.OutOfMemory;
    defer allocator.free(trash_path_z);
    @memcpy(trash_path_z, trash_path);

    if (std.c.rename(path_z, trash_path_z.ptr) != 0) {
        // rename failed (possibly cross-device), try copy+delete
        if (!copyAndDelete(allocator, path_z, trash_path_z.ptr)) {
            return error.TrashFailed;
        }
    }

    return trash_path;
}

/// Copy file then delete original (for cross-device moves)
fn copyAndDelete(allocator: std.mem.Allocator, src: [*:0]const u8, dst: [*:0]const u8) bool {
    // Open source
    const src_file = std.c.fopen(src, "rb") orelse return false;
    defer _ = std.c.fclose(src_file);

    // Open destination
    const dst_file = std.c.fopen(dst, "wb") orelse return false;
    defer _ = std.c.fclose(dst_file);

    // Copy in chunks
    var buf: [8192]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, src_file);
        if (read_count == 0) break;

        const write_count = std.c.fwrite(&buf, 1, read_count, dst_file);
        if (write_count != read_count) {
            // Write failed, clean up
            _ = std.c.unlink(dst);
            return false;
        }
    }

    // Delete original
    _ = allocator; // unused but might need for error handling
    if (std.c.unlink(src) != 0) {
        return false;
    }

    return true;
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !TrashFileArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const path = obj.get("path") orelse return error.InvalidArguments;

    return TrashFileArgs{
        .path = try allocator.dupe(u8, path.string),
    };
}
