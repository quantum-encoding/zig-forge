// profile.zig - Security profile parser for zig-jail
// Purpose: Load and parse JSON security profiles from /etc/zig-jail/profiles/

const std = @import("std");

// ============================================================
// Profile Structures (mirrors JSON schema)
// ============================================================

pub const SyscallConfig = struct {
    default_action: []const u8, // "kill", "errno", "allow"
    errno_value: ?u32 = null,
    allowed: [][]const u8,
    blocked: [][]const u8,

    // FEATURE: Conditional Syscall Rules (Planned for V2)
    //
    // The profile JSON schema supports conditional rules (e.g., "allow open() only for
    // read-only access"), but this feature is explicitly deferred to a future release.
    //
    // V1 implements simple allow/block lists. Conditional logic requires:
    // - Syscall argument inspection in seccomp-bpf filters
    // - More complex BPF bytecode generation
    // - Enhanced error reporting for rule violations
    //
    // To implement: See issue #XXX in the project tracker.
    // This comment serves as documentation for why conditional rules in profiles
    // are parsed but not enforced by the V1 seccomp engine.
};

pub const CapabilityConfig = struct {
    drop_all: bool,
    keep: [][]const u8, // Array of capability names like ["CAP_NET_RAW", "CAP_NET_ADMIN"]

    pub fn deinit(self: *CapabilityConfig, allocator: std.mem.Allocator) void {
        for (self.keep) |cap_name| {
            allocator.free(cap_name);
        }
        allocator.free(self.keep);
    }
};

pub const Profile = struct {
    profile_name: []const u8,
    description: []const u8,
    version: []const u8,
    syscalls: SyscallConfig,
    capabilities: ?CapabilityConfig = null, // Optional capability configuration

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Profile) void {
        // Free all allocated memory
        self.allocator.free(self.profile_name);
        self.allocator.free(self.description);
        self.allocator.free(self.version);

        for (self.syscalls.allowed) |syscall| {
            self.allocator.free(syscall);
        }
        self.allocator.free(self.syscalls.allowed);

        for (self.syscalls.blocked) |syscall| {
            self.allocator.free(syscall);
        }
        self.allocator.free(self.syscalls.blocked);

        if (self.capabilities) |*caps| {
            caps.deinit(self.allocator);
        }
    }
};

// ============================================================
// Profile Loading
// ============================================================

const PROFILE_SEARCH_PATHS = [_][]const u8{
    "/etc/zig-jail/profiles",
    "./profiles",
};

/// Load a profile by name (e.g., "minimal", "python-safe")
pub fn loadProfile(allocator: std.mem.Allocator, profile_name: []const u8) !Profile {
    // Try each search path
    for (PROFILE_SEARCH_PATHS) |base_path| {
        const profile_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ base_path, profile_name }
        );
        defer allocator.free(profile_path);

        if (loadProfileFromPath(allocator, profile_path)) |profile| {
            std.debug.print("[zig-jail] ✓ Loaded profile: {s}\n", .{profile_path});
            return profile;
        } else |_| {
            continue;
        }
    }

    std.debug.print("[zig-jail] ⚠️  Profile '{s}' not found in search paths\n", .{profile_name});
    return error.ProfileNotFound;
}

fn loadProfileFromPath(allocator: std.mem.Allocator, path: []const u8) !Profile {
    // Read file using readFileAlloc (Zig 0.16.1859)
    const io = std.Io.Threaded.global_single_threaded.io();
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(content);

    // Parse JSON
    return try parseProfile(allocator, content);
}

fn parseProfile(allocator: std.mem.Allocator, json_content: []const u8) !Profile {
    // Parse JSON into std.json.Value
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Extract top-level fields
    const profile_name = try allocator.dupe(u8, root.get("profile_name").?.string);
    const description = try allocator.dupe(u8, root.get("description").?.string);
    const version = try allocator.dupe(u8, root.get("version").?.string);

    // Parse syscalls section
    const syscalls_obj = root.get("syscalls").?.object;
    const default_action = try allocator.dupe(u8, syscalls_obj.get("default_action").?.string);

    // Parse allowed syscalls
    const allowed_array = syscalls_obj.get("allowed").?.array;
    var allowed = try allocator.alloc([]const u8, allowed_array.items.len);
    for (allowed_array.items, 0..) |item, i| {
        allowed[i] = try allocator.dupe(u8, item.string);
    }

    // Parse blocked syscalls
    const blocked_array = syscalls_obj.get("blocked").?.array;
    var blocked = try allocator.alloc([]const u8, blocked_array.items.len);
    for (blocked_array.items, 0..) |item, i| {
        blocked[i] = try allocator.dupe(u8, item.string);
    }

    // Get optional errno_value
    const errno_value = if (syscalls_obj.get("errno_value")) |val|
        @as(u32, @intCast(val.integer))
    else
        null;

    // Parse optional capabilities section
    var capabilities: ?CapabilityConfig = null;
    if (root.get("capabilities")) |caps_value| {
        const caps_obj = caps_value.object;

        const drop_all = caps_obj.get("drop_all").?.bool;

        // Parse keep array
        const keep_array = caps_obj.get("keep").?.array;
        var keep = try allocator.alloc([]const u8, keep_array.items.len);
        for (keep_array.items, 0..) |item, i| {
            keep[i] = try allocator.dupe(u8, item.string);
        }

        capabilities = CapabilityConfig{
            .drop_all = drop_all,
            .keep = keep,
        };
    }

    return Profile{
        .profile_name = profile_name,
        .description = description,
        .version = version,
        .syscalls = SyscallConfig{
            .default_action = default_action,
            .errno_value = errno_value,
            .allowed = allowed,
            .blocked = blocked,
        },
        .capabilities = capabilities,
        .allocator = allocator,
    };
}

/// Validate that a profile is well-formed
pub fn validateProfile(profile: *const Profile) !void {
    // Check default action is valid
    const valid_actions = [_][]const u8{ "kill", "errno", "allow" };
    var action_valid = false;
    for (valid_actions) |action| {
        if (std.mem.eql(u8, profile.syscalls.default_action, action)) {
            action_valid = true;
            break;
        }
    }
    if (!action_valid) {
        std.debug.print("[zig-jail] ⚠️  Invalid default_action: {s}\n", .{profile.syscalls.default_action});
        return error.InvalidProfile;
    }

    // If default_action is "errno", errno_value must be set
    if (std.mem.eql(u8, profile.syscalls.default_action, "errno")) {
        if (profile.syscalls.errno_value == null) {
            std.debug.print("[zig-jail] ⚠️  default_action is 'errno' but errno_value not set\n", .{});
            return error.InvalidProfile;
        }
    }

    std.debug.print("[zig-jail] ✓ Profile validation passed\n", .{});
}

// =============================================================================
// Tests
// =============================================================================

test "profile: Validate profile with kill action" {
    var profile = Profile{
        .profile_name = "test",
        .description = "Test profile",
        .version = "1.0",
        .syscalls = .{
            .default_action = "kill",
            .allowed = &[_][]const u8{},
            .blocked = &[_][]const u8{},
        },
        .allocator = std.testing.allocator,
    };

    try validateProfile(&profile);
}

test "profile: Validate profile with errno action" {
    var profile = Profile{
        .profile_name = "test",
        .description = "Test profile",
        .version = "1.0",
        .syscalls = .{
            .default_action = "errno",
            .errno_value = 13,
            .allowed = &[_][]const u8{},
            .blocked = &[_][]const u8{},
        },
        .allocator = std.testing.allocator,
    };

    try validateProfile(&profile);
}

test "profile: Validate profile with allow action" {
    var profile = Profile{
        .profile_name = "test",
        .description = "Test profile",
        .version = "1.0",
        .syscalls = .{
            .default_action = "allow",
            .allowed = &[_][]const u8{},
            .blocked = &[_][]const u8{},
        },
        .allocator = std.testing.allocator,
    };

    try validateProfile(&profile);
}

test "profile: Reject invalid default action" {
    var profile = Profile{
        .profile_name = "test",
        .description = "Test profile",
        .version = "1.0",
        .syscalls = .{
            .default_action = "invalid_action",
            .allowed = &[_][]const u8{},
            .blocked = &[_][]const u8{},
        },
        .allocator = std.testing.allocator,
    };

    try std.testing.expectError(error.InvalidProfile, validateProfile(&profile));
}

test "profile: Reject errno action without errno_value" {
    var profile = Profile{
        .profile_name = "test",
        .description = "Test profile",
        .version = "1.0",
        .syscalls = .{
            .default_action = "errno",
            .errno_value = null,
            .allowed = &[_][]const u8{},
            .blocked = &[_][]const u8{},
        },
        .allocator = std.testing.allocator,
    };

    try std.testing.expectError(error.InvalidProfile, validateProfile(&profile));
}

test "profile: SyscallConfig structure" {
    const config = SyscallConfig{
        .default_action = "kill",
        .allowed = &[_][]const u8{ "read", "write" },
        .blocked = &[_][]const u8{ "execve" },
    };

    try std.testing.expectEqualSlices(u8, "kill", config.default_action);
    try std.testing.expectEqual(@as(usize, 2), config.allowed.len);
    try std.testing.expectEqual(@as(usize, 1), config.blocked.len);
}

test "profile: CapabilityConfig structure" {
    const allocator = std.testing.allocator;
    const cap_names = try allocator.alloc([]const u8, 2);
    cap_names[0] = "CAP_SYS_ADMIN";
    cap_names[1] = "CAP_NET_RAW";

    var caps = CapabilityConfig{
        .drop_all = true,
        .keep = cap_names,
    };

    try std.testing.expectEqual(true, caps.drop_all);
    try std.testing.expectEqual(@as(usize, 2), caps.keep.len);

    caps.deinit(allocator);
}
