//! ═══════════════════════════════════════════════════════════════════════════
//! WASM CLI - WebAssembly Runtime Command Line Interface
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Usage:
//!   wasm run <file.wasm> [args...]    Run a WASM module
//!   wasm info <file.wasm>             Show module information
//!   wasm validate <file.wasm>         Validate a WASM module
//!   wasm version                      Show version
//!   wasm help                         Show help

const std = @import("std");
const wasm_runtime = @import("wasm_runtime");

const Module = wasm_runtime.Module;
const Instance = wasm_runtime.Instance;
const Value = wasm_runtime.Value;

const VERSION = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse args using new iterator pattern
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "run")) {
        try runCommand(allocator, args);
    } else if (std.mem.eql(u8, cmd, "info")) {
        try infoCommand(allocator, args);
    } else if (std.mem.eql(u8, cmd, "validate")) {
        try validateCommand(allocator, args);
    } else if (std.mem.eql(u8, cmd, "version")) {
        print("wasm {s}\n", .{VERSION});
    } else if (std.mem.eql(u8, cmd, "help")) {
        printUsage();
    } else {
        printErr("Unknown command: {s}\n", .{cmd});
        printUsage();
    }
}

fn printUsage() void {
    print(
        \\WASM Runtime - WebAssembly Interpreter
        \\
        \\Usage:
        \\  wasm run <file.wasm> [args...]    Run a WASM module
        \\  wasm info <file.wasm>             Show module information
        \\  wasm validate <file.wasm>         Validate a WASM module
        \\  wasm version                      Show version
        \\  wasm help                         Show help
        \\
        \\Examples:
        \\  wasm run hello.wasm
        \\  wasm run app.wasm --arg1 --arg2
        \\  wasm info module.wasm
        \\
    , .{});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        printErr("Error: missing WASM file path\n", .{});
        return;
    }

    const path = args[2];
    const wasm_args = if (args.len > 3) args[3..] else &[_][]const u8{};

    // Read WASM file
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
        printErr("Error: cannot read file '{s}': {}\n", .{ path, err });
        return;
    };
    defer allocator.free(data);

    // Parse module
    var module = wasm_runtime.parse(allocator, data) catch |err| {
        printErr("Error: failed to parse WASM module: {}\n", .{err});
        return;
    };
    defer module.deinit();

    print("Loaded module: {s}\n", .{path});
    print("  Types: {d}\n", .{module.types.len});
    print("  Functions: {d} ({d} imported)\n", .{
        module.funcCount(),
        module.import_func_count,
    });
    print("  Exports: {d}\n", .{module.exports.len});

    // Check if it has a _start or main export
    const entry_name: []const u8 = if (module.findExport("_start")) |_|
        "_start"
    else if (module.findExport("main")) |_|
        "main"
    else {
        printErr("Error: no _start or main function exported\n", .{});
        return;
    };

    // Create WASI instance
    var wasi_instance = wasm_runtime.instantiateWasi(allocator, &module, .{
        .args = wasm_args,
    }) catch |err| {
        printErr("Error: failed to instantiate module: {}\n", .{err});
        return;
    };
    defer wasi_instance.deinit();

    // Set up import resolver (must be done after instance is at final location)
    wasi_instance.setupImports();

    print("Running {s}...\n", .{entry_name});

    // Run
    const exit_code = wasi_instance.run() catch |err| {
        printErr("Error: execution failed: {}\n", .{err});
        return;
    };

    if (exit_code != 0) {
        printErr("Process exited with code: {d}\n", .{exit_code});
    }
}

fn infoCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        printErr("Error: missing WASM file path\n", .{});
        return;
    }

    const path = args[2];

    // Read WASM file
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
        printErr("Error: cannot read file '{s}': {}\n", .{ path, err });
        return;
    };
    defer allocator.free(data);

    // Parse module
    var module = wasm_runtime.parse(allocator, data) catch |err| {
        printErr("Error: failed to parse WASM module: {}\n", .{err});
        return;
    };
    defer module.deinit();

    // Print info
    print("Module: {s}\n", .{path});
    print("Size: {d} bytes\n\n", .{data.len});

    // Type section
    print("Types ({d}):\n", .{module.types.len});
    for (module.types, 0..) |ft, i| {
        print("  [{d}] (", .{i});
        for (ft.params, 0..) |p, j| {
            if (j > 0) print(", ", .{});
            print("{s}", .{@tagName(p)});
        }
        print(") -> (", .{});
        for (ft.results, 0..) |r, j| {
            if (j > 0) print(", ", .{});
            print("{s}", .{@tagName(r)});
        }
        print(")\n", .{});
    }

    // Import section
    if (module.imports.len > 0) {
        print("\nImports ({d}):\n", .{module.imports.len});
        for (module.imports) |imp| {
            print("  {s}.{s}: ", .{ imp.module, imp.name });
            switch (imp.desc) {
                .func => |type_idx| print("func[{d}]\n", .{type_idx}),
                .table => print("table\n", .{}),
                .mem => print("memory\n", .{}),
                .global => print("global\n", .{}),
            }
        }
    }

    // Functions
    print("\nFunctions ({d} total, {d} imported):\n", .{
        module.funcCount(),
        module.import_func_count,
    });
    for (module.func_types, 0..) |type_idx, i| {
        const func_idx = module.import_func_count + @as(u32, @intCast(i));
        print("  [{d}] type[{d}]\n", .{ func_idx, type_idx });
    }

    // Memory section
    if (module.memories.len > 0) {
        print("\nMemories ({d}):\n", .{module.memories.len});
        for (module.memories, 0..) |mem, i| {
            print("  [{d}] min={d} pages", .{ i, mem.limits.min });
            if (mem.limits.max) |max| {
                print(", max={d} pages", .{max});
            }
            print(" ({d} KiB initial)\n", .{mem.limits.min * 64});
        }
    }

    // Exports
    print("\nExports ({d}):\n", .{module.exports.len});
    for (module.exports) |exp| {
        print("  {s}: {s}[{d}]\n", .{
            exp.name,
            @tagName(exp.desc.kind),
            exp.desc.idx,
        });
    }

    // Start function
    if (module.start) |start| {
        print("\nStart function: {d}\n", .{start});
    }

    // Custom sections
    if (module.custom_sections.len > 0) {
        print("\nCustom sections ({d}):\n", .{module.custom_sections.len});
        for (module.custom_sections) |cs| {
            print("  {s} ({d} bytes)\n", .{ cs.name, cs.data.len });
        }
    }
}

fn validateCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        printErr("Error: missing WASM file path\n", .{});
        return;
    }

    const path = args[2];

    // Read WASM file
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
        printErr("Error: cannot read file '{s}': {}\n", .{ path, err });
        return;
    };
    defer allocator.free(data);

    // Parse module (validation happens during parsing)
    var module = wasm_runtime.parse(allocator, data) catch |err| {
        printErr("INVALID: {}\n", .{err});
        return;
    };
    defer module.deinit();

    print("VALID: {s}\n", .{path});
}

fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
