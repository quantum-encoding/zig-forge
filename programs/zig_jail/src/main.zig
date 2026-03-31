// main.zig - zig-jail launcher
// Purpose: CLI interface for seccomp-BPF sandboxed execution
//
// Usage: zig-jail --profile=minimal -- /bin/echo 'hello world'

const std = @import("std");
const linux = std.os.linux;
const profile_mod = @import("profile.zig");
const seccomp_mod = @import("seccomp.zig");
const namespace_mod = @import("namespace.zig");
const capabilities_mod = @import("capabilities.zig");

const VERSION = "2.0.0";

fn printUsage() void {
    std.debug.print(
        \\zig-jail v{s} - Kernel-Enforced Syscall Sandbox
        \\
        \\Usage:
        \\  zig-jail --profile=<name> [options] -- <command> [args...]
        \\
        \\Options:
        \\  --profile=<name>          Security profile to load (required)
        \\  --bind=<src>:<dst>[:ro]   Bind mount host path to sandbox path
        \\  --help                    Show this help message
        \\  --version                 Show version information
        \\
        \\Available Profiles:
        \\  minimal             Absolute minimum syscalls (testing)
        \\  python-safe         Secure Python execution
        \\  node-safe           Secure Node.js execution
        \\  shell-readonly      Read-only shell
        \\
        \\Examples:
        \\  zig-jail --profile=minimal -- /bin/echo 'hello world'
        \\  zig-jail --profile=python-safe -- python script.py
        \\  zig-jail --profile=python-safe --bind=/host/workspace:/sandbox/workspace -- python /sandbox/workspace/script.py
        \\  zig-jail --profile=python-safe --bind=/host/data:/sandbox/data:ro -- python /sandbox/script.py
        \\
        \\Profile Search Paths:
        \\  /etc/zig-jail/profiles/<name>.json
        \\  ./profiles/<name>.json
        \\
    , .{VERSION});
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse command line arguments using the new iterator pattern
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    // Parse options
    var profile_name: ?[]const u8 = null;
    var command_start_idx: ?usize = null;
    var bind_mounts = std.ArrayList(namespace_mod.BindMount).empty;
    defer {
        for (bind_mounts.items) |bind_mount| {
            allocator.free(bind_mount.source);
            allocator.free(bind_mount.target);
        }
        bind_mounts.deinit(allocator);
    }

    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("zig-jail v{s}\n", .{VERSION});
            return;
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            profile_name = arg[10..]; // Skip "--profile="
        } else if (std.mem.startsWith(u8, arg, "--bind=")) {
            const bind_spec = arg[7..]; // Skip "--bind="
            const bind_mount = try namespace_mod.parseBindMount(allocator, bind_spec);
            try bind_mounts.append(allocator, bind_mount);
        } else if (std.mem.eql(u8, arg, "--")) {
            command_start_idx = i + 1;
            break;
        }
    }

    // Validate arguments
    if (profile_name == null) {
        std.debug.print("[zig-jail] ⚠️  Error: --profile=<name> is required\n\n", .{});
        printUsage();
        std.process.exit(1);
    }

    if (command_start_idx == null or command_start_idx.? >= args.len) {
        std.debug.print("[zig-jail] ⚠️  Error: No command specified after '--'\n\n", .{});
        printUsage();
        std.process.exit(1);
    }

    const command_args = args[command_start_idx.?..];

    // Banner
    std.debug.print("\n[zig-jail] 🛡️  Zig Guardian Forge - Kernel-Enforced Sandbox v{s}\n", .{VERSION});
    std.debug.print("[zig-jail]   Profile: {s}\n", .{profile_name.?});
    std.debug.print("[zig-jail]   Command: ", .{});
    for (command_args) |cmd_arg| {
        std.debug.print("{s} ", .{cmd_arg});
    }
    std.debug.print("\n\n", .{});

    // Load profile
    var profile = try profile_mod.loadProfile(allocator, profile_name.?);
    defer profile.deinit();

    std.debug.print("[zig-jail]   Description: {s}\n", .{profile.description});
    std.debug.print("[zig-jail]   Version: {s}\n", .{profile.version});
    std.debug.print("[zig-jail]   Default action: {s}\n", .{profile.syscalls.default_action});
    std.debug.print("[zig-jail]   Allowed syscalls: {d}\n", .{profile.syscalls.allowed.len});
    std.debug.print("[zig-jail]   Blocked syscalls: {d}\n", .{profile.syscalls.blocked.len});

    if (profile.capabilities) |caps| {
        std.debug.print("[zig-jail]   Capabilities: drop_all={}, keep={d}\n", .{caps.drop_all, caps.keep.len});
    }

    if (bind_mounts.items.len > 0) {
        std.debug.print("[zig-jail]   Bind mounts: {d}\n", .{bind_mounts.items.len});
    }
    std.debug.print("\n", .{});

    // Validate profile
    try profile_mod.validateProfile(&profile);

    // Build seccomp filter
    const filter = try seccomp_mod.buildSeccompFilter(allocator, &profile);
    defer allocator.free(filter);

    // Setup namespace configuration
    var ns_config = namespace_mod.NamespaceConfig.init();
    ns_config.bind_mounts = bind_mounts.items;
    ns_config.enable_mount_ns = bind_mounts.items.len > 0; // Only create mount namespace if we have bind mounts

    // Validate bind mounts before creating namespaces
    for (bind_mounts.items) |*bind_mount| {
        try namespace_mod.validateBindMount(bind_mount);
    }

    // Create namespaces (must be done before fork)
    if (ns_config.enable_mount_ns) {
        try namespace_mod.createNamespaces(&ns_config);
    }

    // Fork: child process will be sandboxed
    const pid = std.os.linux.fork();

    if (pid < 0) {
        std.debug.print("[zig-jail] ⚠️  fork() failed\n", .{});
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child process: setup bind mounts, apply capabilities, install seccomp filter, and exec command

        // Perform bind mounts (must be done before seccomp, as mount() may not be allowed)
        if (ns_config.enable_mount_ns) {
            try namespace_mod.setupBindMounts(&ns_config);
        }

        // Apply capability restrictions
        // CRITICAL: Must be done AFTER bind mounts (which need privileges)
        //           and BEFORE seccomp filter (which might block capset/prctl syscalls)
        if (profile.capabilities) |*caps| {
            std.debug.print("[zig-jail] 🔐 Configuring process capabilities...\n", .{});
            try capabilities_mod.applyCapabilities(caps, allocator);
        }

        // Install seccomp filter
        try seccomp_mod.installSeccompFilter(filter);

        std.debug.print("[zig-jail] 🚀 Launching sandboxed process...\n\n", .{});
        std.debug.print("============================================================\n\n", .{});

        // Convert args to null-terminated C strings for execve
        // argv needs to be null-terminated array
        const argv = try allocator.alloc(?[*:0]const u8, command_args.len + 1);
        defer allocator.free(argv);

        for (command_args, 0..) |cmd_arg, i| {
            const c_str = try allocator.dupeZ(u8, cmd_arg);
            argv[i] = c_str.ptr;
        }
        argv[command_args.len] = null; // Null terminate the array

        // Get path (first arg)
        const path = try allocator.dupeZ(u8, command_args[0]);

        // execve - this replaces the current process
        // Use linux syscall directly since std.process.execve was removed
        const result = linux.execve(
            path.ptr,
            @ptrCast(argv.ptr),
            @ptrCast(std.c.environ),
        );
        // execve only returns on error
        std.debug.print("[zig-jail] ⚠️  execve failed: {d}\n", .{result});
        return error.ExecFailed;
    } else {
        // Parent process: wait for child
        var status: u32 = 0;
        _ = std.os.linux.wait4(@intCast(pid), &status, 0, null);

        std.debug.print("\n============================================================\n", .{});

        if (std.os.linux.W.IFEXITED(status)) {
            const exit_code = std.os.linux.W.EXITSTATUS(status);
            std.debug.print("\n[zig-jail] ✓ Process exited normally (code: {d})\n", .{exit_code});
            std.process.exit(@intCast(exit_code));
        } else if (std.os.linux.W.IFSIGNALED(status)) {
            const signal = std.os.linux.W.TERMSIG(status);
            std.debug.print("\n[zig-jail] 🛡️  Process terminated by signal {d}", .{@intFromEnum(signal)});
            if (signal == linux.SIG.SYS) {
                std.debug.print(" (SIGSYS - seccomp violation)\n", .{});
                std.debug.print("[zig-jail]   The process attempted a blocked syscall.\n", .{});
            } else {
                std.debug.print("\n", .{});
            }
            std.process.exit(128 + @as(u8, @intCast(@intFromEnum(signal))));
        }
    }
}
