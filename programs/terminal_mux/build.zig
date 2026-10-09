//! Terminal Multiplexer Build Configuration
//!
//! A modern tmux alternative with:
//! - PTY management (Linux /dev/ptmx + Darwin openpty)
//! - VT100/ANSI terminal emulation
//! - An in-process C ABI (libterminal_mux) for embedding into host apps
//!   (e.g. a Swift/SwiftUI front-end) — see include/terminal_mux.h
//!
//! Usage:
//!   zig build              - Build the C ABI static library + the zterm executable
//!   zig build lib          - Build the C ABI static library + header only
//!   zig build test         - Run all unit tests (Zig lib + C ABI)
//!   zig build run          - Run the standalone terminal multiplexer
//!   zig build bench        - Run the C ABI throughput/latency benchmark

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Everything below that LINKS against the system libc is pinned to LLVM +
    // LLD on ELF targets. Zig 0.16's self-hosted ELF linker (the Debug default
    // on x86_64) rejects the R_X86_64_PC64 relocations in the `.sframe` section
    // glibc >= 2.44 / binutils >= 2.47 put in crt1.o, so Debug builds and
    // `zig build test` die at link time on current rolling distros. LLD cannot
    // link Mach-O, so Apple targets keep Zig's defaults (null = unchanged).
    const elf_link = !target.result.os.tag.isDarwin();
    const use_llvm: ?bool = if (elf_link) true else null;
    const use_lld: ?bool = if (elf_link) true else null;

    // ==========================================================================
    // C ABI Static Library (libterminal_mux) — the embedding surface.
    // Root is src/capi.zig so the installed archive exports the zterm_* symbols.
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

    // `zig build lib` installs the archive and its header alone. Consumers'
    // builds (scripts/build-macos-lib.sh) use it so building the library does
    // not also replace zig-out/bin/zterm, the CLI on PATH.
    const lib_step = b.step("lib", "Build and install libterminal_mux.a and its header only");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

    // ==========================================================================
    // Benchmark (drives the C ABI like a host application would)
    // ==========================================================================
    const bench = b.addExecutable(.{
        .name = "zterm-bench",
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
    const bench_step = b.step("bench", "Run the C ABI throughput benchmark (a recorded run: scripts/bench-run.py)");
    bench_step.dependOn(&bench_cmd.step);

    // The view-protocol benchmark: a client of a running `zterm server`,
    // timing what a front end sees. scripts/bench-run.py starts the server.
    const viewbench = b.addExecutable(.{
        .name = "zterm-viewbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/viewbench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    viewbench.root_module.link_libc = true;
    b.installArtifact(viewbench);

    // ==========================================================================
    // zterm — THE executable: bare it is the visible multiplexer; `server`,
    // `attach` and `cli` are the headless pool and its `wezterm cli`-style
    // control. (It was once two binaries, one named `tmux`, which shadowed
    // the real tmux on PATH.)
    // ==========================================================================
    const zterm = b.addExecutable(.{
        .name = "zterm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zterm.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    zterm.root_module.link_libc = true;
    b.installArtifact(zterm);

    const zterm_run = b.addRunArtifact(zterm);
    zterm_run.step.dependOn(b.getInstallStep());
    if (b.args) |a| zterm_run.addArgs(a);
    const zterm_step = b.step("zterm", "Run zterm (e.g. `zig build zterm -- cli list`)");
    zterm_step.dependOn(&zterm_run.step);
    // `zig build run` is the multiplexer — the same binary, run bare.
    const run_step = b.step("run", "Run the multiplexer (zterm)");
    run_step.dependOn(&zterm_run.step);

    // ==========================================================================
    // End-to-end QA — tests/mux_qa.py drives the installed standalone binary
    // through a real PTY (host-scroll invariant, background-pane drain,
    // control socket, persistent detach). Wired here so it stops being a
    // "runs when someone remembers" harness.
    // ==========================================================================
    const qa_cmd = b.addSystemCommand(&.{ "python3", "tests/mux_qa.py" });
    qa_cmd.step.dependOn(b.getInstallStep());
    // zterm's headless server as a baton runner: control protocol + runner
    // contract against real PTYs and a stand-in agent.
    const zterm_qa_cmd = b.addSystemCommand(&.{ "python3", "tests/zterm_runner_qa.py" });
    zterm_qa_cmd.step.dependOn(b.getInstallStep());
    const qa_step = b.step("qa", "Run the end-to-end PTY QA harnesses (needs python3)");
    qa_step.dependOn(&qa_cmd.step);
    qa_step.dependOn(&zterm_qa_cmd.step);
    // The view protocol (docs/VIEW-PROTOCOL.md) and `zterm attach`, its
    // first client: frames, input, resize, history, exit, state-sync.
    const bench_compare_cmd = b.addSystemCommand(&.{ "python3", "tests/bench_compare_test.py" });
    qa_step.dependOn(&bench_compare_cmd.step);

    const view_qa_cmd = b.addSystemCommand(&.{ "python3", "tests/zterm_view_qa.py" });
    view_qa_cmd.step.dependOn(b.getInstallStep());
    qa_step.dependOn(&view_qa_cmd.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    lib_tests.root_module.link_libc = true;
    // The graphics recorded-stream anchor @embedFile's this committed fixture;
    // it lives under tests/ (outside the src/ package root), so expose it as a
    // named embed import rather than a relative @embedFile path.
    lib_tests.root_module.addAnonymousImport("graphics_fixture", .{
        .root_source_file = b.path("tests/fixtures/graphics_kitty_rgba.bin"),
    });
    // Real pty-captured claude composer session (typing into the input box) —
    // the stale-cell/mangled-echo replay anchor embeds it the same way.
    lib_tests.root_module.addAnonymousImport("composer_fixture", .{
        .root_source_file = b.path("tests/fixtures/claude_composer_typed.bin"),
    });
    lib_tests.root_module.addAnonymousImport("composer_resize_fixture", .{
        .root_source_file = b.path("tests/fixtures/claude_composer_resize.bin"),
    });
    lib_tests.root_module.addAnonymousImport("composer_submit_fixture", .{
        .root_source_file = b.path("tests/fixtures/claude_composer_submit.bin"),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const capi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    capi_tests.root_module.link_libc = true;
    const run_capi_tests = b.addRunArtifact(capi_tests);

    // zterm's protocol logic (runner-socket resolution, paste scrubbing,
    // settle/evidence, designations) plus ctl.zig's socket-path guard.
    const zterm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zterm.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    zterm_tests.root_module.link_libc = true;
    const run_zterm_tests = b.addRunArtifact(zterm_tests);

    // The benchmarks' own logic: statistics, fixed inputs, byte accounting.
    const bench_test_step = b.step("test-bench", "Unit-test the benchmark helpers");
    for ([_][]const u8{ "src/benchstat.zig", "src/bench.zig", "src/viewbench.zig" }) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_lld,
        });
        t.root_module.link_libc = true;
        bench_test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(bench_test_step);
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_capi_tests.step);
    test_step.dependOn(&run_zterm_tests.step);
}
