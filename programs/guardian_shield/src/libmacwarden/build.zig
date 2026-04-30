const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // DYLD Interposition Version (libmacwarden.dylib)
    // ==========================================================================
    // Use with: DYLD_INSERT_LIBRARIES=./libmacwarden.dylib <command>
    // Works without code signing but limited to non-hardened binaries

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "macwarden",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    // ==========================================================================
    // Endpoint Security Version (es-warden)
    // ==========================================================================
    // System-wide protection using Apple's Endpoint Security framework
    // Requires:
    //   - Apple Developer Program membership
    //   - com.apple.developer.endpoint-security.client entitlement
    //   - Code signing with entitlements
    //   - Run as root (sudo)
    //   - Full Disk Access permission

    // CTK core module (shared policy engine, event types, config)
    const ctk_core = b.createModule(.{
        .root_source_file = b.path("../../../cognitive_telemetry_kit/core/core.zig"),
    });

    const es_mod = b.createModule(.{
        .root_source_file = b.path("es_warden.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ctk", .module = ctk_core },
        },
    });

    // Link EndpointSecurity as a system library (it's in /usr/lib, not Frameworks)
    es_mod.linkSystemLibrary("EndpointSecurity", .{});
    es_mod.linkSystemLibrary("bsm", .{});

    const es_exe = b.addExecutable(.{
        .name = "es-warden",
        .root_module = es_mod,
    });

    b.installArtifact(es_exe);

    // ==========================================================================
    // Input Guardian macOS (HID-based anti-cheat)
    // ==========================================================================
    // Uses IOHIDManager for system-wide HID input monitoring.
    // Requires: DriverKit HID entitlement
    // Reuses the same Grimoire pattern engine as Linux (/dev/input)

    const input_mod = b.createModule(.{
        .root_source_file = b.path("../input_sovereignty/input-guardian.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link IOKit framework for IOHIDManager
    input_mod.linkFramework("IOKit", .{});
    input_mod.linkFramework("CoreFoundation", .{});

    const input_exe = b.addExecutable(.{
        .name = "input-guardian",
        .root_module = input_mod,
    });

    b.installArtifact(input_exe);

    // ==========================================================================
    // Sign step (optional - for signed builds)
    // ==========================================================================

    const sign_step = b.step("sign", "Sign es-warden with entitlements (requires Developer ID)");

    const sign_cmd = b.addSystemCommand(&.{
        "codesign",
        "--sign",
        "Developer ID Application", // Will use first matching identity
        "--entitlements",
        "es_warden.entitlements",
        "--options",
        "runtime", // Hardened runtime
        "--force",
        "zig-out/bin/es-warden",
    });
    sign_cmd.step.dependOn(b.getInstallStep());

    sign_step.dependOn(&sign_cmd.step);

    // ==========================================================================
    // Run step for es-warden
    // ==========================================================================

    const run_cmd = b.addRunArtifact(es_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run es-warden (requires sudo)");
    run_step.dependOn(&run_cmd.step);
}
