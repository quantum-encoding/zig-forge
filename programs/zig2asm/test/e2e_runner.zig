//! End-to-end smoke test for zig2asm.
//!
//! Unlike the inline unit tests (which pin the argv `buildArgv` produces), this
//! runner exercises the real spawn/wait/exit-code path against the actual `zig`
//! compiler — the tool's true external anchor is the live `zig build-obj` CLI
//! contract (`-femit-asm=`, `-femit-llvm-ir=`, `-fno-emit-bin`), and only an
//! end-to-end run confirms those flags still produce output.
//!
//! Invoked by the `test-e2e` build step with three arguments:
//!   argv[1] = path to the built zig2asm executable
//!   argv[2] = path to the fixture .zig source
//!   argv[3] = a writable output directory
//!
//! Exits 0 on success; prints a diagnostic and exits 1 on any failure.

const std = @import("std");
const Dir = std.Io.Dir;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("e2e: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Run zig2asm once and require a clean (exit-0) termination.
fn runZig2asm(io: std.Io, argv: []const []const u8) void {
    var child = std.process.spawn(io, .{ .argv = argv }) catch |err|
        fail("failed to spawn zig2asm: {s}", .{@errorName(err)});
    const term = child.wait(io) catch |err|
        fail("failed to wait on zig2asm: {s}", .{@errorName(err)});
    switch (term) {
        .exited => |code| if (code != 0) fail("zig2asm exited with code {d}", .{code}),
        else => fail("zig2asm terminated abnormally", .{}),
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    if (args.len < 4) fail("usage: e2e_runner <zig2asm> <fixture.zig> <outdir>", .{});
    const exe = args[1];
    const fixture = args[2];
    const outdir = args[3];

    const asm_out = try std.fs.path.join(allocator, &.{ outdir, "hello.s" });
    defer allocator.free(asm_out);
    const ll_out = try std.fs.path.join(allocator, &.{ outdir, "hello.ll" });
    defer allocator.free(ll_out);

    // 1. Emit assembly, then assert the .s file exists and is non-empty.
    runZig2asm(io, &.{ exe, fixture, "--emit", "asm", "-o", asm_out });
    const asm_bytes = Dir.cwd().readFileAlloc(io, asm_out, allocator, .limited(256 * 1024 * 1024)) catch |err|
        fail("could not read emitted assembly {s}: {s}", .{ asm_out, @errorName(err) });
    defer allocator.free(asm_bytes);
    if (asm_bytes.len == 0) fail("emitted assembly {s} is empty", .{asm_out});

    // 2. Emit LLVM IR, then assert the .ll file exists, is non-empty, and
    //    contains a `define` (proof real IR for the exported fn was emitted).
    runZig2asm(io, &.{ exe, fixture, "--emit", "llvm-ir", "-o", ll_out });
    const ll_bytes = Dir.cwd().readFileAlloc(io, ll_out, allocator, .limited(256 * 1024 * 1024)) catch |err|
        fail("could not read emitted LLVM IR {s}: {s}", .{ ll_out, @errorName(err) });
    defer allocator.free(ll_bytes);
    if (ll_bytes.len == 0) fail("emitted LLVM IR {s} is empty", .{ll_out});
    if (std.mem.indexOf(u8, ll_bytes, "define") == null)
        fail("emitted LLVM IR {s} contains no `define` — no function body emitted", .{ll_out});

    std.debug.print("e2e: OK — asm {d} bytes, llvm-ir {d} bytes\n", .{ asm_bytes.len, ll_bytes.len });
}
