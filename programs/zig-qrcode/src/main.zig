//! ZigQR CLI - QR Code Generator
//!
//! Usage:
//!   zigqr encode "data" -o output.png
//!   zigqr encode "data" --svg -o output.svg
//!   zigqr encode "data" --ec H --size 8 -o output.png
//!   zigqr version

const std = @import("std");
const qrcode = @import("qrcode.zig");
const png_encoder = @import("png.zig");

const alloc = std.heap.page_allocator;

pub fn main(init: std.process.Init.Minimal) void {
    var iter = std.process.Args.Iterator.init(init.args);
    _ = iter.next(); // skip program name

    const command = iter.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "version")) {
        writeStdout("zigqr 1.0.0\n");
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (!std.mem.eql(u8, command, "encode")) {
        writeStderr("Unknown command. Use 'zigqr help' for usage.\n");
        return;
    }

    // Parse encode arguments
    var data: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var use_svg = false;
    var ec_level: qrcode.ErrorCorrectionLevel = .M;
    var module_size: u8 = 4;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = iter.next();
        } else if (std.mem.eql(u8, arg, "--svg")) {
            use_svg = true;
        } else if (std.mem.eql(u8, arg, "--png")) {
            use_svg = false;
        } else if (std.mem.eql(u8, arg, "--ec")) {
            if (iter.next()) |level| {
                if (std.mem.eql(u8, level, "L")) ec_level = .L
                else if (std.mem.eql(u8, level, "M")) ec_level = .M
                else if (std.mem.eql(u8, level, "Q")) ec_level = .Q
                else if (std.mem.eql(u8, level, "H")) ec_level = .H;
            }
        } else if (std.mem.eql(u8, arg, "--size")) {
            if (iter.next()) |size_str| {
                module_size = std.fmt.parseInt(u8, size_str, 10) catch 4;
            }
        } else if (data == null) {
            data = arg;
        }
    }

    const input = data orelse {
        writeStderr("Error: no data provided. Usage: zigqr encode \"data\" -o output.png\n");
        return;
    };

    // Auto-detect format from file extension
    if (output_path) |path| {
        if (std.mem.endsWith(u8, path, ".svg")) use_svg = true;
    }

    if (use_svg) {
        var svg = qrcode.encodeAndRenderSvg(alloc, input, .{
            .ec_level = ec_level,
        }, .{
            .module_size = module_size,
        }) catch |err| {
            printError("SVG generation failed", err);
            return;
        };
        defer svg.deinit(alloc);
        writeOutput(output_path, svg.data);
    } else {
        var img = qrcode.encodeAndRender(alloc, input, module_size, .{
            .ec_level = ec_level,
        }) catch |err| {
            printError("QR encode failed", err);
            return;
        };
        defer img.deinit(alloc);

        const png_bytes = png_encoder.encodePng(alloc, img.pixels, img.width, img.height) catch |err| {
            printError("PNG encode failed", err);
            return;
        };
        defer alloc.free(png_bytes);
        writeOutput(output_path, png_bytes);
    }
}

fn printError(prefix: []const u8, err: anyerror) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: {s}: {s}\n", .{ prefix, @errorName(err) }) catch "Error\n";
    writeStderr(msg);
}

fn writeStdout(msg: []const u8) void {
    const f = std.c.fopen("/dev/stdout", "w") orelse return;
    _ = std.c.fwrite(msg.ptr, 1, msg.len, f);
    _ = std.c.fclose(f);
}

fn writeStderr(msg: []const u8) void {
    const f = std.c.fopen("/dev/stderr", "w") orelse return;
    _ = std.c.fwrite(msg.ptr, 1, msg.len, f);
    _ = std.c.fclose(f);
}

fn writeOutput(output_path: ?[]const u8, bytes: []const u8) void {
    if (output_path) |path| {
        const path_buf = alloc.alloc(u8, path.len + 1) catch return;
        defer alloc.free(path_buf);
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const file = std.c.fopen(@ptrCast(path_buf.ptr), "wb") orelse {
            writeStderr("Error: cannot open output file\n");
            return;
        };
        _ = std.c.fwrite(bytes.ptr, 1, bytes.len, file);
        _ = std.c.fclose(file);

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Written {d} bytes to {s}\n", .{ bytes.len, path }) catch "Done\n";
        writeStdout(msg);
    } else {
        // Write binary to stdout
        const f = std.c.fopen("/dev/stdout", "wb") orelse return;
        _ = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
        _ = std.c.fclose(f);
    }
}

fn printUsage() void {
    writeStdout(
        \\ZigQR - QR Code Generator v1.0.0
        \\
        \\Usage:
        \\  zigqr encode <data> [options]
        \\  zigqr version
        \\  zigqr help
        \\
        \\Options:
        \\  -o, --output <path>   Output file (default: stdout)
        \\  --svg                 Output SVG format
        \\  --png                 Output PNG format (default)
        \\  --ec <L|M|Q|H>       Error correction level (default: M)
        \\  --size <n>            Module size in pixels (default: 4)
        \\
        \\Examples:
        \\  zigqr encode "https://example.com" -o qr.png
        \\  zigqr encode "Hello World" --svg -o qr.svg
        \\  zigqr encode "data" --ec H --size 8 -o qr.png
        \\
    );
}
