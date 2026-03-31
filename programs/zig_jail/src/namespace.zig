// namespace.zig - Mount namespace and bind-mount support for zig-jail
// Purpose: Isolate filesystem access using Linux mount namespaces
//
// The Doctrine of Proxied Sovereignty:
//   The agent operates through trusted emissaries (bind mounts),
//   never touching the hostile world directly.

const std = @import("std");
const linux = std.os.linux;

// Linux namespace constants (from linux/sched.h)
pub const CLONE_NEWNS: u32 = 0x00020000;    // New mount namespace
pub const CLONE_NEWPID: u32 = 0x20000000;   // New PID namespace (optional)
pub const CLONE_NEWNET: u32 = 0x40000000;   // New network namespace (optional)
pub const CLONE_NEWUTS: u32 = 0x04000000;   // New UTS namespace (optional)
pub const CLONE_NEWIPC: u32 = 0x08000000;   // New IPC namespace (optional)

// Mount flags (from linux/mount.h)
pub const MS_BIND: u32 = 4096;              // Bind mount
pub const MS_REC: u32 = 16384;              // Recursive bind mount
pub const MS_RDONLY: u32 = 1;               // Read-only mount
pub const MS_NOSUID: u32 = 2;               // No setuid/setgid
pub const MS_NODEV: u32 = 4;                // No device files
pub const MS_NOEXEC: u32 = 8;               // No executables
pub const MS_REMOUNT: u32 = 32;             // Remount existing mount

// ============================================================
// Bind Mount Configuration
// ============================================================

pub const BindMount = struct {
    source: []const u8,      // Host path (e.g., /home/user/workspace)
    target: []const u8,      // Sandbox path (e.g., /sandbox/workspace)
    readonly: bool,          // Mount as read-only
    recursive: bool,         // Recursive bind mount
};

pub const NamespaceConfig = struct {
    enable_mount_ns: bool,   // Create new mount namespace
    enable_pid_ns: bool,     // Create new PID namespace (optional)
    enable_net_ns: bool,     // Create new network namespace (optional)
    bind_mounts: []BindMount,

    /// Default configuration - mount namespace only
    pub fn init() NamespaceConfig {
        return .{
            .enable_mount_ns = true,
            .enable_pid_ns = false,
            .enable_net_ns = false,
            .bind_mounts = &[_]BindMount{},
        };
    }
};

// ============================================================
// Namespace Creation
// ============================================================

/// Create new namespaces using unshare(2)
/// Must be called BEFORE fork() to affect child process
pub fn createNamespaces(config: *const NamespaceConfig) !void {
    var flags: u32 = 0;

    if (config.enable_mount_ns) {
        flags |= CLONE_NEWNS;
        std.debug.print("[namespace] Creating mount namespace\n", .{});
    }

    if (config.enable_pid_ns) {
        flags |= CLONE_NEWPID;
        std.debug.print("[namespace] Creating PID namespace\n", .{});
    }

    if (config.enable_net_ns) {
        flags |= CLONE_NEWNET;
        std.debug.print("[namespace] Creating network namespace\n", .{});
    }

    if (flags == 0) {
        return; // No namespaces requested
    }

    // Call unshare(2) to create new namespaces
    const result = linux.unshare(flags);
    if (result != 0) {
        std.debug.print("[namespace] ⚠️  unshare() failed with error: {d}\n", .{result});
        return error.UnshareFailed;
    }

    std.debug.print("[namespace] ✓ Namespaces created\n", .{});
}

// ============================================================
// Bind Mount Operations
// ============================================================

/// Perform all bind mounts specified in configuration
/// Must be called AFTER createNamespaces() and BEFORE execve()
pub fn setupBindMounts(config: *const NamespaceConfig) !void {
    if (config.bind_mounts.len == 0) {
        return; // No bind mounts requested
    }

    std.debug.print("[namespace] Setting up {d} bind mount(s)\n", .{config.bind_mounts.len});

    for (config.bind_mounts, 0..) |bind_mount, i| {
        try performBindMount(&bind_mount, i + 1);
    }

    std.debug.print("[namespace] ✓ All bind mounts complete\n", .{});
}

/// Perform a single bind mount operation
fn performBindMount(bind_mount: *const BindMount, index: usize) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("[namespace] [{d}] Bind mount: {s} → {s}", .{index, bind_mount.source, bind_mount.target});

    if (bind_mount.readonly) {
        std.debug.print(" (read-only)\n", .{});
    } else {
        std.debug.print(" (read-write)\n", .{});
    }

    // Step 1: Ensure source path exists
    std.Io.Dir.cwd().access(io, bind_mount.source, .{}) catch |err| {
        std.debug.print("[namespace]     ⚠️  Source path does not exist: {s}\n", .{bind_mount.source});
        return err;
    };

    // Step 2: Create target directory if it doesn't exist
    std.Io.Dir.cwd().createDirPath(io, bind_mount.target) catch |err| {
        std.debug.print("[namespace]     ⚠️  Failed to create target directory: {s}\n", .{bind_mount.target});
        return err;
    };

    // Step 3: Perform bind mount using mount(2)
    var mount_flags: u32 = MS_BIND;
    if (bind_mount.recursive) {
        mount_flags |= MS_REC;
    }

    // Convert paths to null-terminated C strings
    const source_z = try std.posix.toPosixPath(bind_mount.source);
    const target_z = try std.posix.toPosixPath(bind_mount.target);

    // mount(source, target, NULL, MS_BIND, NULL)
    const result = linux.mount(
        &source_z,
        &target_z,
        null,
        mount_flags,
        0,
    );

    if (result != 0) {
        std.debug.print("[namespace]     ⚠️  mount() failed with result: {d}\n", .{result});
        return error.MountFailed;
    }

    std.debug.print("[namespace]     ✓ Bind mount successful\n", .{});

    // Step 4: If read-only, remount with MS_RDONLY
    if (bind_mount.readonly) {
        const remount_flags = MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV;

        const remount_result = linux.mount(
            &source_z,
            &target_z,
            null,
            remount_flags,
            0,
        );

        if (remount_result != 0) {
            std.debug.print("[namespace]     ⚠️  remount(readonly) failed with result: {d}\n", .{remount_result});
            return error.RemountFailed;
        }

        std.debug.print("[namespace]     ✓ Remounted as read-only\n", .{});
    }
}

// ============================================================
// Helper Functions
// ============================================================

/// Parse a bind mount specification from CLI format
/// Format: "/host/path:/sandbox/path" or "/host/path:/sandbox/path:ro"
pub fn parseBindMount(allocator: std.mem.Allocator, spec: []const u8) !BindMount {
    var iter = std.mem.splitScalar(u8, spec, ':');

    const source = iter.next() orelse return error.InvalidBindMount;
    const target = iter.next() orelse return error.InvalidBindMount;
    const mode = iter.next();

    const readonly = if (mode) |m| std.mem.eql(u8, m, "ro") else false;

    return BindMount{
        .source = try allocator.dupe(u8, source),
        .target = try allocator.dupe(u8, target),
        .readonly = readonly,
        .recursive = true, // Default to recursive
    };
}

/// Validate a bind mount specification
pub fn validateBindMount(bind_mount: *const BindMount) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Ensure source is an absolute path
    if (!std.fs.path.isAbsolute(bind_mount.source)) {
        std.debug.print("[namespace] ⚠️  Source must be absolute path: {s}\n", .{bind_mount.source});
        return error.InvalidBindMount;
    }

    // Ensure target is an absolute path
    if (!std.fs.path.isAbsolute(bind_mount.target)) {
        std.debug.print("[namespace] ⚠️  Target must be absolute path: {s}\n", .{bind_mount.target});
        return error.InvalidBindMount;
    }

    // Warn if source doesn't exist (will fail at mount time)
    std.Io.Dir.cwd().access(io, bind_mount.source, .{}) catch {
        std.debug.print("[namespace] ⚠️  Warning: Source path may not exist: {s}\n", .{bind_mount.source});
    };
}

// =============================================================================
// Tests
// =============================================================================

test "namespace: Parse bind mount with absolute paths" {
    const allocator = std.testing.allocator;
    const spec = "/host/path:/container/path";

    const mount = try parseBindMount(allocator, spec);
    defer {
        allocator.free(mount.source);
        allocator.free(mount.target);
    }

    try std.testing.expectEqualSlices(u8, "/host/path", mount.source);
    try std.testing.expectEqualSlices(u8, "/container/path", mount.target);
    try std.testing.expectEqual(false, mount.readonly);
}

test "namespace: Parse bind mount with read-only flag" {
    const allocator = std.testing.allocator;
    const spec = "/host/path:/container/path:ro";

    const mount = try parseBindMount(allocator, spec);
    defer {
        allocator.free(mount.source);
        allocator.free(mount.target);
    }

    try std.testing.expectEqualSlices(u8, "/host/path", mount.source);
    try std.testing.expectEqualSlices(u8, "/container/path", mount.target);
    try std.testing.expectEqual(true, mount.readonly);
}

test "namespace: Bind mount missing target" {
    const allocator = std.testing.allocator;
    const spec = "/host/path";

    try std.testing.expectError(error.InvalidBindMount, parseBindMount(allocator, spec));
}

test "namespace: BindMount structure" {
    const bind = BindMount{
        .source = "/host",
        .target = "/container",
        .readonly = true,
        .recursive = true,
    };

    try std.testing.expectEqualSlices(u8, "/host", bind.source);
    try std.testing.expectEqualSlices(u8, "/container", bind.target);
    try std.testing.expectEqual(true, bind.readonly);
    try std.testing.expectEqual(true, bind.recursive);
}

test "namespace: NamespaceConfig initialization" {
    const config = NamespaceConfig.init();

    try std.testing.expectEqual(true, config.enable_mount_ns);
    try std.testing.expectEqual(false, config.enable_pid_ns);
    try std.testing.expectEqual(false, config.enable_net_ns);
    try std.testing.expectEqual(@as(usize, 0), config.bind_mounts.len);
}

test "namespace: Validate absolute path requirement for source" {
    const bind = BindMount{
        .source = "relative/path",
        .target = "/container",
        .readonly = false,
        .recursive = true,
    };

    try std.testing.expectError(error.InvalidBindMount, validateBindMount(&bind));
}

test "namespace: Validate absolute path requirement for target" {
    const bind = BindMount{
        .source = "/host",
        .target = "relative/path",
        .readonly = false,
        .recursive = true,
    };

    try std.testing.expectError(error.InvalidBindMount, validateBindMount(&bind));
}

test "namespace: Mount flags constants" {
    try std.testing.expectEqual(@as(u32, 4096), MS_BIND);
    try std.testing.expectEqual(@as(u32, 16384), MS_REC);
    try std.testing.expectEqual(@as(u32, 1), MS_RDONLY);
}

test "namespace: Clone constants for namespaces" {
    try std.testing.expectEqual(@as(u32, 0x00020000), CLONE_NEWNS);
    try std.testing.expectEqual(@as(u32, 0x20000000), CLONE_NEWPID);
    try std.testing.expectEqual(@as(u32, 0x40000000), CLONE_NEWNET);
}
