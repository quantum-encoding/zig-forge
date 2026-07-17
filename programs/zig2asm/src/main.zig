//! zig2asm.zig — Emit assembly / LLVM IR from a Zig source file
//!
//! Usage:
//!   zig run zig2asm.zig -- input.zig [--emit asm|llvm-ir|obj] [-O Debug|ReleaseFast|...] [--target triple]
//!
//! Requires Zig to be installed and available in PATH.

const std = @import("std");
const builtin = @import("builtin");

const Emit = enum { assembly, llvm_ir, obj };
const OptLevel = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

const Options = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    emit: Emit = .assembly,
    target: ?[]const u8 = null,
    opt: OptLevel = .Debug,
    verbose: bool = false,
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Parse args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var opts = Options{};
    var i: usize = 1; // Skip program name

    while (i < args.len) : (i += 1) {
        const a = args[i];

        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--emit")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --emit requires a value (asm|llvm-ir|obj)\n", .{});
                return error.InvalidArguments;
            }
            opts.emit = parseEmit(args[i]) orelse {
                std.debug.print("error: invalid --emit; expected asm|llvm-ir|obj\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --output requires a path\n", .{});
                return error.InvalidArguments;
            }
            opts.output_path = args[i];
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --target requires a value\n", .{});
                return error.InvalidArguments;
            }
            // Try to expand shortcut, otherwise use as-is
            opts.target = expandTargetShortcut(args[i]) orelse args[i];
        } else if (std.mem.eql(u8, a, "-O")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: -O requires a value\n", .{});
                return error.InvalidArguments;
            }
            opts.opt = parseOpt(args[i]) orelse {
                std.debug.print("error: invalid -O; expected Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n", .{});
                return error.InvalidArguments;
            };
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("error: unknown flag: {s}\n", .{a});
            return error.InvalidArguments;
        } else {
            // Positional input file
            if (opts.input_path != null) {
                std.debug.print("error: multiple input files provided\n", .{});
                return error.InvalidArguments;
            }
            opts.input_path = a;
        }
    }

    if (opts.help) {
        printHelp();
        return;
    }

    if (opts.input_path == null) {
        std.debug.print("error: missing input .zig file\n\n", .{});
        printHelp();
        return error.InvalidArguments;
    }

    // Resolve the output path (also reported to the user after a successful build).
    const output_path = try resolveOutputPath(allocator, opts);
    defer if (opts.output_path == null) allocator.free(output_path);

    // Build the exact argv handed to the child `zig` compiler.
    // All entries are allocated in `argv_arena`, freed in one shot below.
    var argv_arena = std.heap.ArenaAllocator.init(allocator);
    defer argv_arena.deinit();
    const argv = try buildArgv(argv_arena.allocator(), opts);

    if (opts.verbose) {
        std.debug.print("exec:", .{});
        for (argv) |c| std.debug.print(" {s}", .{c});
        std.debug.print("\n", .{});
    }

    // Run zig
    var child = try std.process.spawn(io, .{
        .argv = argv,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("zig build-obj failed with exit code {d}\n", .{code});
                return error.CompileFailed;
            }
        },
        else => {
            std.debug.print("zig build-obj terminated abnormally\n", .{});
            return error.CompileFailed;
        },
    }

    std.debug.print("✓ Generated: {s}\n", .{output_path});
}

/// File extension produced for a given emit mode.
fn outputExt(emit: Emit) []const u8 {
    return switch (emit) {
        .assembly => ".s",
        .llvm_ir => ".ll",
        .obj => ".o",
    };
}

/// Resolve the output file path: the explicit `-o` value if given, otherwise
/// `<input stem><ext>` in the CWD. The returned slice is owned by the caller
/// only when `opts.output_path == null` (the derived case allocates).
fn resolveOutputPath(allocator: std.mem.Allocator, opts: Options) ![]const u8 {
    if (opts.output_path) |p| return p;
    const input_path = opts.input_path orelse return error.MissingInput;
    const basename = std.fs.path.stem(input_path);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ basename, outputExt(opts.emit) });
}

/// Build the exact argv handed to the child `zig` compiler. Pure over `opts`
/// (no I/O, no spawning) so the zig-CLI flag contract can be pinned by tests.
/// Every returned entry is allocated in `allocator` — pass an arena and free it
/// in one shot, or free each element individually.
fn buildArgv(allocator: std.mem.Allocator, opts: Options) ![]const []const u8 {
    const input_path = opts.input_path orelse return error.MissingInput;

    var cmd: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer cmd.deinit(allocator);

    try cmd.append(allocator, try allocator.dupe(u8, "zig"));
    try cmd.append(allocator, try allocator.dupe(u8, "build-obj"));
    try cmd.append(allocator, try allocator.dupe(u8, input_path));

    // Target
    if (opts.target) |t| {
        try cmd.append(allocator, try allocator.dupe(u8, "-target"));
        try cmd.append(allocator, try allocator.dupe(u8, t));
    }

    // Optimization
    try cmd.append(allocator, try allocator.dupe(u8, "-O"));
    try cmd.append(allocator, try allocator.dupe(u8, optToString(opts.opt)));

    // Emit flag (output path embedded in the flag value).
    const output_path = try resolveOutputPath(allocator, opts);
    const emit_arg = switch (opts.emit) {
        .assembly => try std.fmt.allocPrint(allocator, "-femit-asm={s}", .{output_path}),
        .llvm_ir => try std.fmt.allocPrint(allocator, "-femit-llvm-ir={s}", .{output_path}),
        .obj => try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{output_path}),
    };
    try cmd.append(allocator, emit_arg);

    // Don't emit default bin for asm/llvm-ir
    if (opts.emit != .obj) {
        try cmd.append(allocator, try allocator.dupe(u8, "-fno-emit-bin"));
    }

    return cmd.toOwnedSlice(allocator);
}

fn parseEmit(s: []const u8) ?Emit {
    if (std.mem.eql(u8, s, "asm") or std.mem.eql(u8, s, "assembly")) return .assembly;
    if (std.mem.eql(u8, s, "llvm-ir") or std.mem.eql(u8, s, "llvm")) return .llvm_ir;
    if (std.mem.eql(u8, s, "obj") or std.mem.eql(u8, s, "object")) return .obj;
    return null;
}

fn parseOpt(s: []const u8) ?OptLevel {
    if (std.mem.eql(u8, s, "Debug")) return .Debug;
    if (std.mem.eql(u8, s, "ReleaseSafe")) return .ReleaseSafe;
    if (std.mem.eql(u8, s, "ReleaseFast")) return .ReleaseFast;
    if (std.mem.eql(u8, s, "ReleaseSmall")) return .ReleaseSmall;
    return null;
}

fn optToString(o: OptLevel) []const u8 {
    return switch (o) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

fn printHelp() void {
    std.debug.print(
        \\zig2asm — emit assembly / LLVM IR / object file from Zig source
        \\
        \\USAGE:
        \\  zig run zig2asm.zig -- [options] <input.zig>
        \\
        \\OPTIONS:
        \\  --emit <asm|llvm-ir|obj>   Output format (default: asm)
        \\  -o, --output <path>        Write output to <path>
        \\  --target <triple>          Target triple (e.g. x86_64-linux-gnu).
        \\                              Omit to build for the native host.
        \\  -O <level>                 Debug|ReleaseSafe|ReleaseFast|ReleaseSmall
        \\  -v, --verbose              Print executed zig command
        \\  -h, --help                 Show this help
        \\
        \\TARGET SHORTCUTS:
        \\  arm64, aarch64             aarch64 on the host OS (macos/linux)
        \\  x86, x64, x86_64           x86_64 on the host OS (macos/linux)
        \\  macos-arm64                aarch64-macos-none
        \\  macos-x64                  x86_64-macos-none
        \\  linux-arm64                aarch64-linux-gnu
        \\  linux-x64                  x86_64-linux-gnu
        \\  wasm                       wasm32-freestanding-none
        \\  arm                        arm-linux-gnueabihf
        \\  riscv                      riscv64-linux-gnu
        \\
        \\EXAMPLES:
        \\  zig run zig2asm.zig -- hello.zig --emit asm -O ReleaseFast
        \\  zig run zig2asm.zig -- hello.zig --emit llvm-ir -o hello.ll
        \\  zig run zig2asm.zig -- hello.zig --emit obj --target arm64
        \\
    , .{});
}

/// Full triple for a 64-bit arch on the *host* OS, so that on macOS
/// `--target arm64` inspects macOS codegen rather than Linux codegen.
fn hostTriple64(arch: []const u8) []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => if (std.mem.eql(u8, arch, "aarch64")) "aarch64-macos-none" else "x86_64-macos-none",
        else => if (std.mem.eql(u8, arch, "aarch64")) "aarch64-linux-gnu" else "x86_64-linux-gnu",
    };
}

fn expandTargetShortcut(shortcut: []const u8) ?[]const u8 {
    // Host-relative shortcuts: resolve against the OS zig2asm is running on.
    if (std.mem.eql(u8, shortcut, "arm64") or std.mem.eql(u8, shortcut, "aarch64"))
        return hostTriple64("aarch64");
    if (std.mem.eql(u8, shortcut, "x86") or std.mem.eql(u8, shortcut, "x64") or std.mem.eql(u8, shortcut, "x86_64"))
        return hostTriple64("x86_64");

    // Explicit OS+arch shortcuts (host-independent).
    if (std.mem.eql(u8, shortcut, "macos-arm64")) return "aarch64-macos-none";
    if (std.mem.eql(u8, shortcut, "macos-x64")) return "x86_64-macos-none";
    if (std.mem.eql(u8, shortcut, "linux-arm64")) return "aarch64-linux-gnu";
    if (std.mem.eql(u8, shortcut, "linux-x64")) return "x86_64-linux-gnu";

    // Host-independent shortcuts.
    if (std.mem.eql(u8, shortcut, "wasm")) return "wasm32-freestanding-none";
    if (std.mem.eql(u8, shortcut, "arm")) return "arm-linux-gnueabihf";
    if (std.mem.eql(u8, shortcut, "riscv")) return "riscv64-linux-gnu";
    return null;
}

// Test Suite

test "parseEmit: valid 'asm' shorthand" {
    const result = parseEmit("asm");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .assembly);
}

test "parseEmit: valid 'assembly' full name" {
    const result = parseEmit("assembly");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .assembly);
}

test "parseEmit: valid 'llvm-ir' shorthand" {
    const result = parseEmit("llvm-ir");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .llvm_ir);
}

test "parseEmit: valid 'llvm' shorthand" {
    const result = parseEmit("llvm");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .llvm_ir);
}

test "parseEmit: valid 'obj' shorthand" {
    const result = parseEmit("obj");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .obj);
}

test "parseEmit: valid 'object' full name" {
    const result = parseEmit("object");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .obj);
}

test "parseEmit: invalid value returns null" {
    const result = parseEmit("invalid");
    try std.testing.expect(result == null);
}

test "parseOpt: valid 'Debug'" {
    const result = parseOpt("Debug");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .Debug);
}

test "parseOpt: valid 'ReleaseSafe'" {
    const result = parseOpt("ReleaseSafe");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .ReleaseSafe);
}

test "parseOpt: valid 'ReleaseFast'" {
    const result = parseOpt("ReleaseFast");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .ReleaseFast);
}

test "parseOpt: valid 'ReleaseSmall'" {
    const result = parseOpt("ReleaseSmall");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .ReleaseSmall);
}

test "parseOpt: invalid value returns null" {
    const result = parseOpt("InvalidLevel");
    try std.testing.expect(result == null);
}

test "optToString: Debug" {
    const result = optToString(.Debug);
    try std.testing.expect(std.mem.eql(u8, result, "Debug"));
}

test "optToString: ReleaseSafe" {
    const result = optToString(.ReleaseSafe);
    try std.testing.expect(std.mem.eql(u8, result, "ReleaseSafe"));
}

test "optToString: ReleaseFast" {
    const result = optToString(.ReleaseFast);
    try std.testing.expect(std.mem.eql(u8, result, "ReleaseFast"));
}

test "optToString: ReleaseSmall" {
    const result = optToString(.ReleaseSmall);
    try std.testing.expect(std.mem.eql(u8, result, "ReleaseSmall"));
}

test "optToString roundtrip: all levels" {
    inline for ([_]OptLevel{ .Debug, .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |level| {
        const str = optToString(level);
        const parsed = parseOpt(str);
        try std.testing.expect(parsed != null);
        try std.testing.expect(parsed.? == level);
    }
}

test "expandTargetShortcut: arm64 resolves to host OS" {
    const result = expandTargetShortcut("arm64");
    try std.testing.expect(result != null);
    const expected = if (builtin.target.os.tag == .macos) "aarch64-macos-none" else "aarch64-linux-gnu";
    try std.testing.expectEqualStrings(expected, result.?);
}

test "expandTargetShortcut: aarch64 alias resolves to host OS" {
    const result = expandTargetShortcut("aarch64");
    try std.testing.expect(result != null);
    const expected = if (builtin.target.os.tag == .macos) "aarch64-macos-none" else "aarch64-linux-gnu";
    try std.testing.expectEqualStrings(expected, result.?);
}

test "expandTargetShortcut: x86 resolves to host OS" {
    const result = expandTargetShortcut("x86");
    try std.testing.expect(result != null);
    const expected = if (builtin.target.os.tag == .macos) "x86_64-macos-none" else "x86_64-linux-gnu";
    try std.testing.expectEqualStrings(expected, result.?);
}

test "expandTargetShortcut: x64 and x86_64 aliases resolve to host OS" {
    const expected = if (builtin.target.os.tag == .macos) "x86_64-macos-none" else "x86_64-linux-gnu";
    try std.testing.expectEqualStrings(expected, expandTargetShortcut("x64").?);
    try std.testing.expectEqualStrings(expected, expandTargetShortcut("x86_64").?);
}

test "expandTargetShortcut: explicit os-arch shortcuts are host-independent" {
    try std.testing.expectEqualStrings("aarch64-macos-none", expandTargetShortcut("macos-arm64").?);
    try std.testing.expectEqualStrings("x86_64-macos-none", expandTargetShortcut("macos-x64").?);
    try std.testing.expectEqualStrings("aarch64-linux-gnu", expandTargetShortcut("linux-arm64").?);
    try std.testing.expectEqualStrings("x86_64-linux-gnu", expandTargetShortcut("linux-x64").?);
}

test "expandTargetShortcut: wasm to wasm32-freestanding-none" {
    const result = expandTargetShortcut("wasm");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "wasm32-freestanding-none"));
}

test "expandTargetShortcut: arm to arm-linux-gnueabihf" {
    const result = expandTargetShortcut("arm");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "arm-linux-gnueabihf"));
}

test "expandTargetShortcut: riscv to riscv64-linux-gnu" {
    const result = expandTargetShortcut("riscv");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "riscv64-linux-gnu"));
}

test "expandTargetShortcut: unknown returns null" {
    const result = expandTargetShortcut("unknown-arch");
    try std.testing.expect(result == null);
}

test "expandTargetShortcut: full triple passes through as null" {
    const result = expandTargetShortcut("x86_64-linux-musl");
    try std.testing.expect(result == null);
}

// buildArgv: pin the exact zig CLI flag contract for every emit mode.

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expectEqualStrings(e, a);
}

test "buildArgv: emit assembly, defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), .{ .input_path = "hello.zig", .emit = .assembly });
    try expectArgv(&.{ "zig", "build-obj", "hello.zig", "-O", "Debug", "-femit-asm=hello.s", "-fno-emit-bin" }, argv);
}

test "buildArgv: emit llvm-ir, defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), .{ .input_path = "hello.zig", .emit = .llvm_ir });
    try expectArgv(&.{ "zig", "build-obj", "hello.zig", "-O", "Debug", "-femit-llvm-ir=hello.ll", "-fno-emit-bin" }, argv);
}

test "buildArgv: emit obj omits -fno-emit-bin and uses -femit-bin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), .{ .input_path = "hello.zig", .emit = .obj });
    try expectArgv(&.{ "zig", "build-obj", "hello.zig", "-O", "Debug", "-femit-bin=hello.o" }, argv);
}

test "buildArgv: -target is inserted before -O when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), .{
        .input_path = "hello.zig",
        .emit = .assembly,
        .target = "aarch64-macos-none",
    });
    try expectArgv(&.{ "zig", "build-obj", "hello.zig", "-target", "aarch64-macos-none", "-O", "Debug", "-femit-asm=hello.s", "-fno-emit-bin" }, argv);
}

test "buildArgv: explicit -o output path overrides derived stem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), .{
        .input_path = "src/foo.zig",
        .output_path = "out/custom.s",
        .emit = .assembly,
    });
    try expectArgv(&.{ "zig", "build-obj", "src/foo.zig", "-O", "Debug", "-femit-asm=out/custom.s", "-fno-emit-bin" }, argv);
}

test "buildArgv: opt level flows into -O and stem strips directory + extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), .{
        .input_path = "path/to/mod.zig",
        .emit = .obj,
        .opt = .ReleaseFast,
    });
    try expectArgv(&.{ "zig", "build-obj", "path/to/mod.zig", "-O", "ReleaseFast", "-femit-bin=mod.o" }, argv);
}

test "buildArgv: missing input path errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingInput, buildArgv(arena.allocator(), .{ .emit = .assembly }));
}
