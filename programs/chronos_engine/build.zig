//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // chronos-ctl executable
    const chronos_mod = b.createModule(.{
        .root_source_file = b.path("chronos-ctl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{
        .name = "chronos-ctl",
        .root_module = chronos_mod,
    });

    b.installArtifact(exe);

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run chronos-ctl");
    run_step.dependOn(&run_cmd.step);

    // Create test step
    const chronos_test_mod = b.createModule(.{
        .root_source_file = b.path("chronos.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const chronos_tests = b.addTest(.{
        .root_module = chronos_test_mod,
    });

    const phi_test_mod = b.createModule(.{
        .root_source_file = b.path("phi_timestamp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const phi_tests = b.addTest(.{
        .root_module = phi_test_mod,
    });

    const cognitive_test_mod = b.createModule(.{
        .root_source_file = b.path("cognitive_states.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const cognitive_tests = b.addTest(.{
        .root_module = cognitive_test_mod,
    });

    // chronos-stamp-cognitive executable
    const stamp_cognitive_mod = b.createModule(.{
        .root_source_file = b.path("chronos-stamp-cognitive.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stamp_cognitive_mod.linkSystemLibrary("dbus-1", .{});
    const stamp_cognitive = b.addExecutable(.{
        .name = "chronos-stamp-cognitive",
        .root_module = stamp_cognitive_mod,
    });
    b.installArtifact(stamp_cognitive);

    // chronos-stamp-cognitive-direct executable (direct eBPF map access)
    const stamp_cognitive_direct_mod = b.createModule(.{
        .root_source_file = b.path("chronos-stamp-cognitive-direct.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stamp_cognitive_direct_mod.linkSystemLibrary("dbus-1", .{});
    stamp_cognitive_direct_mod.linkSystemLibrary("bpf", .{});
    const stamp_cognitive_direct = b.addExecutable(.{
        .name = "chronos-stamp-cognitive-direct",
        .root_module = stamp_cognitive_direct_mod,
    });
    b.installArtifact(stamp_cognitive_direct);

    // chronosd-cognitive executable (unified daemon)
    const chronosd_cognitive_mod = b.createModule(.{
        .root_source_file = b.path("chronosd-cognitive.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    chronosd_cognitive_mod.linkSystemLibrary("dbus-1", .{});
    const chronosd_cognitive = b.addExecutable(.{
        .name = "chronosd-cognitive",
        .root_module = chronosd_cognitive_mod,
    });
    b.installArtifact(chronosd_cognitive);

    // conductor-daemon executable
    const conductor_daemon_mod = b.createModule(.{
        .root_source_file = b.path("conductor-daemon.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    conductor_daemon_mod.linkSystemLibrary("dbus-1", .{});
    conductor_daemon_mod.linkSystemLibrary("bpf", .{});
    const conductor_daemon = b.addExecutable(.{
        .name = "conductor-daemon",
        .root_module = conductor_daemon_mod,
    });
    b.installArtifact(conductor_daemon);

    // cognitive-watcher executable (eBPF ring buffer consumer)
    const cognitive_watcher_mod = b.createModule(.{
        .root_source_file = b.path("cognitive-watcher.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cognitive_watcher_mod.linkSystemLibrary("dbus-1", .{});
    cognitive_watcher_mod.linkSystemLibrary("bpf", .{});
    cognitive_watcher_mod.linkSystemLibrary("sqlite3", .{});
    const cognitive_watcher = b.addExecutable(.{
        .name = "cognitive-watcher",
        .root_module = cognitive_watcher_mod,
    });
    b.installArtifact(cognitive_watcher);

    // cognitive-graph executable (SVG exporter)
    const cognitive_graph_mod = b.createModule(.{
        .root_source_file = b.path("cognitive-graph.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cognitive_graph_mod.linkSystemLibrary("dbus-1", .{});
    const cognitive_graph = b.addExecutable(.{
        .name = "cognitive-graph",
        .root_module = cognitive_graph_mod,
    });
    b.installArtifact(cognitive_graph);

    // eBPF program: cognitive-oracle.bpf.c → cognitive-oracle.bpf.o
    // Compile eBPF program with clang (requires clang, bpftool, linux headers)
    const compile_ebpf = b.addSystemCommand(&[_][]const u8{
        "clang",
        "-g",
        "-O2",
        "-target",
        "bpf",
        "-D__TARGET_ARCH_x86",
        "-I../../src/zig-sentinel/ebpf", // vmlinux.h location
        "-mllvm",
        "-bpf-stack-size=1024", // Increase BPF stack from 512 to 1024 bytes
        "-c",
        "cognitive-oracle.bpf.c",
        "-o",
        "cognitive-oracle.bpf.o",
    });

    // Create step for building eBPF
    const ebpf_step = b.step("ebpf", "Compile cognitive-oracle eBPF program");
    ebpf_step.dependOn(&compile_ebpf.step);

    // Add tests for conductor-daemon
    const conductor_test_mod = b.createModule(.{
        .root_source_file = b.path("conductor-daemon.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const conductor_tests = b.addTest(.{
        .root_module = conductor_test_mod,
    });

    const run_chronos_tests = b.addRunArtifact(chronos_tests);
    const run_phi_tests = b.addRunArtifact(phi_tests);
    const run_cognitive_tests = b.addRunArtifact(cognitive_tests);
    const run_conductor_tests = b.addRunArtifact(conductor_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_chronos_tests.step);
    test_step.dependOn(&run_phi_tests.step);
    test_step.dependOn(&run_cognitive_tests.step);
    test_step.dependOn(&run_conductor_tests.step);
}
