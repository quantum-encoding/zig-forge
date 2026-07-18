//! Terminal Multiplexer Build Configuration
//!
//! A modern tmux alternative with:
//! - PTY management (Linux /dev/ptmx + Darwin openpty)
//! - VT100/ANSI terminal emulation
//! - An in-process C ABI (libterminal_mux) for embedding into host apps
//!   (e.g. a Swift/SwiftUI front-end) — see include/terminal_mux.h
//!
//! Usage:
//!   zig build              - Build the C ABI static library + tmux executable
//!   zig build test         - Run all unit tests (Zig lib + C ABI)
//!   zig build run          - Run the standalone terminal multiplexer
//!   zig build bench        - Run the C ABI throughput/latency benchmark

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // C ABI Static Library (libterminal_mux) — the embedding surface.
    // Root is src/capi.zig so the installed archive exports the tmux_* symbols.
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "terminal_mux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.root_module.link_libc = true;
    // Pull in compiler-rt so the archive is self-contained when a non-Zig
    // linker (Xcode's ld) consumes it.
    lib.bundle_compiler_rt = true;
    lib.installHeader(b.path("include/terminal_mux.h"), "terminal_mux.h");
    b.installArtifact(lib);

    // ==========================================================================
    // Standalone Executable (single-process session)
    // ==========================================================================
    const exe = b.addExecutable(.{
        .name = "tmux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the terminal multiplexer");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Benchmark (drives the C ABI like a host application would)
    // ==========================================================================
    const bench = b.addExecutable(.{
        .name = "tmux-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            // A perf bench must ALWAYS be optimized — Debug (the default `optimize`) is bounds-checked +
            // unoptimized, ~6× slower, and misleads every comparison. Force ReleaseFast regardless of -Doptimize.
            .optimize = .ReleaseFast,
        }),
    });
    bench.root_module.link_libc = true;
    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run the C ABI throughput benchmark");
    bench_step.dependOn(&bench_cmd.step);

    // ==========================================================================
    // zterm — standalone mux server + CLI (the `wezterm cli` equivalent)
    // ==========================================================================
    const zterm = b.addExecutable(.{
        .name = "zterm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zterm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zterm.root_module.link_libc = true;
    b.installArtifact(zterm);

    const zterm_run = b.addRunArtifact(zterm);
    zterm_run.step.dependOn(b.getInstallStep());
    if (b.args) |a| zterm_run.addArgs(a);
    const zterm_step = b.step("zterm", "Run zterm (e.g. `zig build zterm -- cli list`)");
    zterm_step.dependOn(&zterm_run.step);

    // ==========================================================================
    // End-to-end QA — tests/mux_qa.py drives the installed standalone binary
    // through a real PTY (host-scroll invariant, background-pane drain,
    // control socket, persistent detach). Wired here so it stops being a
    // "runs when someone remembers" harness.
    // ==========================================================================
    const qa_cmd = b.addSystemCommand(&.{ "python3", "tests/mux_qa.py" });
    qa_cmd.step.dependOn(b.getInstallStep());
    const qa_step = b.step("qa", "Run the end-to-end PTY QA harness (needs python3)");
    qa_step.dependOn(&qa_cmd.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_tests.root_module.link_libc = true;
    // The graphics recorded-stream anchor @embedFile's this committed fixture;
    // it lives under tests/ (outside the src/ package root), so expose it as a
    // named embed import rather than a relative @embedFile path.
    lib_tests.root_module.addAnonymousImport("graphics_fixture", .{
        .root_source_file = b.path("tests/fixtures/graphics_kitty_rgba.bin"),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const capi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    capi_tests.root_module.link_libc = true;
    const run_capi_tests = b.addRunArtifact(capi_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_capi_tests.step);
}
