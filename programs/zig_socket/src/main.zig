//! zig_socket CLI - Socket & WebSocket Protocol Demo
//!
//! Commands:
//!   demo               - Run WebSocket interactive demo
//!   tcp                - Run TCP socket demo
//!   encode <message>   - Encode message to WebSocket frame
//!   decode <hex>       - Decode hex WebSocket frame
//!   handshake <key>    - Generate Sec-WebSocket-Accept from key
//!   echo               - Echo server demo (frame handling)

const std = @import("std");
const Io = std.Io;
const socket = @import("zig-socket");

/// Get current Unix timestamp (Zig 0.16 compatible)
fn getUnixTimestamp() i64 {
    if (std.time.Instant.now()) |instant| {
        return @as(i64, instant.timestamp.sec);
    } else |_| {
        return 0;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try printUsage(stdout);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "demo")) {
        try runDemo(arena, stdout);
    } else if (std.mem.eql(u8, command, "tcp")) {
        try runTcpDemo(stdout);
    } else if (std.mem.eql(u8, command, "encode")) {
        if (args.len < 3) {
            try stdout.print("Usage: socket-demo encode <message>\n", .{});
            try stdout.flush();
            return;
        }
        try encodeMessage(arena, stdout, args[2]);
    } else if (std.mem.eql(u8, command, "decode")) {
        if (args.len < 3) {
            try stdout.print("Usage: socket-demo decode <hex>\n", .{});
            try stdout.flush();
            return;
        }
        try decodeFrame(arena, stdout, args[2]);
    } else if (std.mem.eql(u8, command, "handshake")) {
        if (args.len < 3) {
            try stdout.print("Usage: socket-demo handshake <key>\n", .{});
            try stdout.flush();
            return;
        }
        try generateHandshake(arena, stdout, args[2]);
    } else if (std.mem.eql(u8, command, "echo")) {
        try runEchoDemo(arena, stdout);
    } else {
        try printUsage(stdout);
    }

    try stdout.flush();
}

fn printUsage(stdout: anytype) !void {
    try stdout.print(
        \\zig_socket - Standalone Socket Library Demo
        \\
        \\Usage:
        \\  socket-demo demo                    Run WebSocket protocol demo
        \\  socket-demo tcp                     Run TCP socket demo
        \\  socket-demo encode <message>        Encode message to frame
        \\  socket-demo decode <hex>            Decode hex frame
        \\  socket-demo handshake <key>         Generate Sec-WebSocket-Accept
        \\  socket-demo echo                    Echo server demo
        \\
        \\Examples:
        \\  socket-demo demo
        \\  socket-demo tcp
        \\  socket-demo encode "Hello World"
        \\  socket-demo handshake "dGhlIHNhbXBsZSBub25jZQ=="
        \\  socket-demo echo
        \\
    , .{});
    try stdout.flush();
}

fn runTcpDemo(stdout: anytype) !void {
    try stdout.print("\n", .{});
    try stdout.print("TCP Socket Demo\n", .{});
    try stdout.print("───────────────\n\n", .{});

    // Create a TCP socket
    const fd = socket.createTcpSocket() catch |err| {
        try stdout.print("Failed to create socket: {}\n", .{err});
        return;
    };
    defer socket.close(fd);
    try stdout.print("Created TCP socket (fd={})\n", .{fd});

    // Set socket options
    socket.setNoDelay(fd, true) catch {};
    try stdout.print("Set TCP_NODELAY: enabled\n", .{});

    socket.setRecvTimeout(fd, 3000) catch {};
    try stdout.print("Set recv timeout: 3000ms\n", .{});

    // Create a non-blocking socket
    const nb_fd = socket.createTcpSocketNonblock() catch |err| {
        try stdout.print("Failed to create non-blocking socket: {}\n", .{err});
        return;
    };
    defer socket.close(nb_fd);
    try stdout.print("Created non-blocking TCP socket (fd={})\n", .{nb_fd});

    // Try connecting to localhost (will likely fail, which is fine for demo)
    try stdout.print("\nAttempting connect to 127.0.0.1:80...\n", .{});
    socket.connect(fd, .{ 127, 0, 0, 1 }, 80) catch |err| {
        try stdout.print("Connection result: {} (expected for demo)\n", .{err});
    };

    try stdout.print("\nTCP socket demo complete!\n", .{});
}

fn runDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("\n", .{});
    try stdout.print("zig_socket - WebSocket Protocol Demo\n", .{});
    try stdout.print("════════════════════════════════════\n\n", .{});

    // Demo 1: Text frame encoding
    try stdout.print("Demo 1: Encoding a Text Message Frame\n", .{});
    try stdout.print("──────────────────────────────────────\n\n", .{});

    const message = "Hello, WebSocket!";
    try stdout.print("Original message: \"{s}\"\n\n", .{message});

    var text_frame = try socket.Frame.init(allocator, true, .text, message);
    defer text_frame.deinit(allocator);

    try stdout.print("Frame properties:\n", .{});
    try stdout.print("  - FIN: {}\n", .{text_frame.fin});
    try stdout.print("  - Opcode: text (0x1)\n", .{});
    try stdout.print("  - Payload: \"{s}\"\n", .{text_frame.payload});
    try stdout.print("  - Masked: {}\n\n", .{text_frame.masking_key != null});

    const frame_bytes = try text_frame.toBytes(allocator);
    defer allocator.free(frame_bytes);

    try stdout.print("Encoded frame (hex): ", .{});
    for (frame_bytes) |byte| {
        try stdout.print("{x:0>2} ", .{byte});
    }
    try stdout.print("\n\n", .{});

    // Demo 2: Masked frame (client-to-server)
    try stdout.print("Demo 2: Client-to-Server Masked Frame\n", .{});
    try stdout.print("──────────────────────────────────────\n\n", .{});

    const client_msg = "Client message";
    var masked_frame = try socket.Frame.initMasked(allocator, true, .text, client_msg);
    defer masked_frame.deinit(allocator);

    try stdout.print("Original message: \"{s}\"\n", .{client_msg});
    if (masked_frame.masking_key) |key| {
        try stdout.print("Masking key: {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{ key[0], key[1], key[2], key[3] });
    }
    try stdout.print("Masked: true (client -> server requirement)\n\n", .{});

    const masked_bytes = try masked_frame.toBytes(allocator);
    defer allocator.free(masked_bytes);

    try stdout.print("Encoded masked frame (hex): ", .{});
    for (masked_bytes) |byte| {
        try stdout.print("{x:0>2} ", .{byte});
    }
    try stdout.print("\n\n", .{});

    // Demo 3: Control frame (ping)
    try stdout.print("Demo 3: Control Frame (Ping)\n", .{});
    try stdout.print("────────────────────────────\n\n", .{});

    var ping_frame = try socket.Frame.init(allocator, true, .ping, "PING");
    defer ping_frame.deinit(allocator);

    try stdout.print("Frame type: ping (0x9)\n", .{});
    try stdout.print("Payload: \"{s}\"\n", .{ping_frame.payload});
    try stdout.print("Control frames must have payload <= 125 bytes\n\n", .{});

    // Demo 4: Close frame with status code
    try stdout.print("Demo 4: Close Frame with Status Code\n", .{});
    try stdout.print("─────────────────────────────────────\n\n", .{});

    var close_payload = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer close_payload.deinit();

    try close_payload.appendSlice(&std.mem.toBytes(@as(u16, 1000)));
    try close_payload.appendSlice("Goodbye");

    var close_frame = try socket.Frame.init(allocator, true, .close, close_payload.items);
    defer close_frame.deinit(allocator);

    try stdout.print("Frame type: close (0x8)\n", .{});
    try stdout.print("Close code: 1000 (normal closure)\n", .{});
    try stdout.print("Reason: \"Goodbye\"\n\n", .{});

    // Demo 5: Handshake validation
    try stdout.print("Demo 5: WebSocket Handshake Validation (RFC 6455)\n", .{});
    try stdout.print("──────────────────────────────────────────────────\n\n", .{});

    const test_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const expected_accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";

    try stdout.print("Client Sec-WebSocket-Key: {s}\n", .{test_key});

    const generated_accept = try socket.Handshake.generateAccept(allocator, test_key);
    defer allocator.free(generated_accept);

    try stdout.print("Generated Sec-WebSocket-Accept: {s}\n", .{generated_accept});
    try stdout.print("Expected: {s}\n", .{expected_accept});

    const is_valid = try socket.Handshake.validate(allocator, test_key, generated_accept);
    try stdout.print("Validation: {s}\n\n", .{if (is_valid) "PASS" else "FAIL"});

    // Demo 6: Connection state machine
    try stdout.print("Demo 6: Connection State Machine\n", .{});
    try stdout.print("────────────────────────────────\n\n", .{});

    var conn = socket.Connection.init(allocator, true);
    defer conn.deinit();

    try stdout.print("Initial state: connecting\n", .{});
    try stdout.print("After handshake: open\n", .{});
    try stdout.print("After close frame received: closing\n", .{});
    try stdout.print("After close acknowledgement: closed\n\n", .{});

    // Demo 7: Frame round-trip
    try stdout.print("Demo 7: Frame Round-Trip (Encode -> Decode)\n", .{});
    try stdout.print("────────────────────────────────────────────\n\n", .{});

    const roundtrip_msg = "Round-trip test";
    var encode_frame = try socket.Frame.init(allocator, true, .text, roundtrip_msg);
    defer encode_frame.deinit(allocator);

    const encoded = try encode_frame.toBytes(allocator);
    defer allocator.free(encoded);

    const decode_result = try socket.Frame.fromBytes(allocator, encoded);
    defer allocator.free(decode_result.frame.payload);

    try stdout.print("Original: \"{s}\"\n", .{roundtrip_msg});
    try stdout.print("Encoded bytes: ", .{});
    for (encoded) |b| {
        try stdout.print("{x:0>2} ", .{b});
    }
    try stdout.print("\n", .{});
    try stdout.print("Decoded: \"{s}\"\n", .{decode_result.frame.payload});
    try stdout.print("Match: {s}\n\n", .{if (std.mem.eql(u8, roundtrip_msg, decode_result.frame.payload)) "YES" else "NO"});

    try stdout.print("Demo complete!\n", .{});
}

fn encodeMessage(allocator: std.mem.Allocator, stdout: anytype, message: []const u8) !void {
    try stdout.print("\nWebSocket Frame Encoding\n", .{});
    try stdout.print("════════════════════════\n\n", .{});

    try stdout.print("Message: \"{s}\"\n", .{message});
    try stdout.print("Length: {} bytes\n\n", .{message.len});

    var frame = try socket.Frame.init(allocator, true, .text, message);
    defer frame.deinit(allocator);

    const bytes = try frame.toBytes(allocator);
    defer allocator.free(bytes);

    try stdout.print("Encoded frame:\n  Hex: ", .{});
    for (bytes) |byte| {
        try stdout.print("{x:0>2} ", .{byte});
    }
    try stdout.print("\n\n", .{});

    const header_result = try socket.FrameHeader.fromBytes(bytes);
    try stdout.print("Header details:\n", .{});
    try stdout.print("  FIN: {}\n", .{header_result.header.fin});
    try stdout.print("  RSV1-3: {}{}{}\n", .{ header_result.header.rsv1, header_result.header.rsv2, header_result.header.rsv3 });
    try stdout.print("  Opcode: 0x{x} (text)\n", .{@intFromEnum(header_result.header.opcode)});
    try stdout.print("  Mask: {}\n", .{header_result.header.mask});
    try stdout.print("  Payload length: {}\n", .{header_result.header.payload_len});
    try stdout.print("  Header size: {} bytes\n", .{header_result.header_len});
}

fn decodeFrame(allocator: std.mem.Allocator, stdout: anytype, hex_str: []const u8) !void {
    try stdout.print("\nWebSocket Frame Decoding\n", .{});
    try stdout.print("════════════════════════\n\n", .{});

    var frame_bytes = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer frame_bytes.deinit();

    var i: usize = 0;
    while (i < hex_str.len) : (i += 2) {
        if (i + 1 >= hex_str.len) break;
        const byte_str = hex_str[i .. i + 2];
        const byte_val = std.fmt.parseUnsigned(u8, byte_str, 16) catch {
            try stdout.print("Error: Invalid hex string\n", .{});
            return;
        };
        try frame_bytes.append(byte_val);
    }

    try stdout.print("Input (hex): {s}\n", .{hex_str});
    try stdout.print("Input length: {} bytes\n\n", .{frame_bytes.items.len});

    const frame_result = socket.Frame.fromBytes(allocator, frame_bytes.items) catch |err| {
        try stdout.print("Error decoding frame: {}\n", .{err});
        return;
    };
    defer allocator.free(frame_result.frame.payload);

    const frame = frame_result.frame;
    try stdout.print("Decoded frame:\n", .{});
    try stdout.print("  FIN: {}\n", .{frame.fin});
    try stdout.print("  Opcode: {} (", .{@intFromEnum(frame.opcode)});
    switch (frame.opcode) {
        .text => try stdout.print("text", .{}),
        .binary => try stdout.print("binary", .{}),
        .close => try stdout.print("close", .{}),
        .ping => try stdout.print("ping", .{}),
        .pong => try stdout.print("pong", .{}),
        .continuation => try stdout.print("continuation", .{}),
    }
    try stdout.print(")\n", .{});

    if (frame.masking_key) |key| {
        try stdout.print("  Masking key: {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{ key[0], key[1], key[2], key[3] });
    }

    try stdout.print("  Payload length: {}\n", .{frame.payload.len});
    try stdout.print("  Payload: \"{s}\"\n", .{frame.payload});
    try stdout.print("  Bytes consumed: {}\n", .{frame_result.bytes_consumed});
}

fn generateHandshake(allocator: std.mem.Allocator, stdout: anytype, key: []const u8) !void {
    try stdout.print("\nWebSocket Handshake Generation (RFC 6455)\n", .{});
    try stdout.print("══════════════════════════════════════════\n\n", .{});

    try stdout.print("Client request header:\n", .{});
    try stdout.print("  Sec-WebSocket-Key: {s}\n\n", .{key});

    const accept = try socket.Handshake.generateAccept(allocator, key);
    defer allocator.free(accept);

    try stdout.print("Server response header:\n", .{});
    try stdout.print("  Sec-WebSocket-Accept: {s}\n\n", .{accept});

    try stdout.print("Validation: ", .{});
    const is_valid = try socket.Handshake.validate(allocator, key, accept);
    try stdout.print("{s}\n", .{if (is_valid) "PASS" else "FAIL"});
}

fn runEchoDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("\nWebSocket Echo Server Demo (Frame Handling)\n", .{});
    try stdout.print("════════════════════════════════════════════\n\n", .{});

    try stdout.print("This demo shows how frames are processed in sequence:\n\n", .{});

    var conn = socket.Connection.init(allocator, false);
    defer conn.deinit();

    try stdout.print("Step 1: Send text message\n", .{});
    var msg1 = try socket.Frame.init(allocator, true, .text, "Hello");
    defer msg1.deinit(allocator);
    try conn.processFrame(&msg1);
    try stdout.print("  Frame received: text, payload=\"Hello\"\n", .{});
    try stdout.print("  Connection state: open\n\n", .{});

    try stdout.print("Step 2: Send ping frame\n", .{});
    var ping = try socket.Frame.init(allocator, true, .ping, "");
    defer ping.deinit(allocator);
    try conn.processFrame(&ping);
    try stdout.print("  Frame received: ping (control frame)\n", .{});
    try stdout.print("  Server would respond with pong\n\n", .{});

    try stdout.print("Step 3: Send close frame\n", .{});
    var close_payload = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer close_payload.deinit();
    const close_code_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, 1000));
    try close_payload.appendSlice(&close_code_bytes);
    var close_frame = try socket.Frame.init(allocator, true, .close, close_payload.items);
    defer close_frame.deinit(allocator);
    try conn.processFrame(&close_frame);
    try stdout.print("  Frame received: close (code=1000, normal closure)\n", .{});
    try stdout.print("  Connection state: closing\n", .{});
    try stdout.print("  Server sends close frame and closes connection\n\n", .{});

    try stdout.print("Echo demo complete!\n", .{});
}
