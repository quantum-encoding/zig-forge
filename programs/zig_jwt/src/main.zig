//! zig_jwt CLI - JWT Demo and Utility
//!
//! Commands:
//!   sign <subject> <secret>   - Create a JWT token
//!   verify <token> <secret>   - Verify and decode a JWT
//!   decode <token>            - Decode without verification (unsafe)

const std = @import("std");
const Io = std.Io;
const jwt = @import("jwt");

/// Get current Unix timestamp (Zig 0.16 compatible)
/// Uses libc clock_gettime for REALTIME clock
fn getUnixTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
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
    } else if (std.mem.eql(u8, command, "sign")) {
        if (args.len < 4) {
            try stdout.print("Usage: jwt-demo sign <subject> <secret> [--issuer <iss>] [--expires <seconds>]\n", .{});
            try stdout.flush();
            return;
        }
        try signToken(arena, stdout, args);
    } else if (std.mem.eql(u8, command, "verify")) {
        if (args.len < 4) {
            try stdout.print("Usage: jwt-demo verify <token> <secret>\n", .{});
            try stdout.flush();
            return;
        }
        try verifyToken(arena, stdout, args[2], args[3]);
    } else if (std.mem.eql(u8, command, "decode")) {
        if (args.len < 3) {
            try stdout.print("Usage: jwt-demo decode <token>\n", .{});
            try stdout.flush();
            return;
        }
        try decodeToken(arena, stdout, args[2]);
    } else {
        try printUsage(stdout);
    }

    try stdout.flush();
}

fn printUsage(stdout: anytype) !void {
    try stdout.print(
        \\zig_jwt - JWT Token Utility
        \\
        \\Usage:
        \\  jwt-demo demo                         Run interactive demo
        \\  jwt-demo sign <subject> <secret>      Create a JWT token
        \\  jwt-demo verify <token> <secret>      Verify and decode a JWT
        \\  jwt-demo decode <token>               Decode without verification
        \\
        \\Options for sign:
        \\  --issuer <iss>     Set issuer claim
        \\  --expires <sec>    Set expiration (default: 3600)
        \\  --audience <aud>   Set audience claim
        \\
        \\Examples:
        \\  jwt-demo sign user123 mysecret --issuer myapp --expires 7200
        \\  jwt-demo verify eyJhbGci... mysecret
        \\  jwt-demo decode eyJhbGci...
        \\
    , .{});
    try stdout.flush();
}

fn runDemo(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║              zig_jwt - JWT Token Demo                        ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Demo 1: Basic token creation and verification
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 1: Basic JWT Creation (HS256)                          │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    const secret = "my-super-secret-key-256";

    var builder = jwt.Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user-12345");
    try builder.setIssuer("zig-jwt-demo");
    try builder.setAudience("my-application");
    builder.setIssuedAt(getUnixTimestamp());
    builder.setExpiration(getUnixTimestamp() + 3600);
    try builder.setJwtId("unique-token-id-001");

    const token = try builder.sign(.HS256, secret);
    defer allocator.free(token);

    try stdout.print("Created JWT Token:\n", .{});
    try stdout.print("  {s}\n\n", .{token});

    // Show token structure
    const decoded = try jwt.decode(allocator, token);
    defer allocator.free(decoded.header);
    defer allocator.free(decoded.payload);
    defer allocator.free(decoded.signature);

    try stdout.print("Header:    {s}\n", .{decoded.header});
    try stdout.print("Payload:   {s}\n", .{decoded.payload});
    try stdout.print("Signature: {s}...\n\n", .{decoded.signature[0..@min(20, decoded.signature.len)]});

    // Demo 2: Token verification
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 2: JWT Verification                                    │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var verifier = jwt.Verifier.init(allocator);
    defer verifier.deinit();
    try verifier.setIssuer("zig-jwt-demo");

    var claims = try verifier.verify(token, .HS256, secret);
    defer claims.deinit();

    try stdout.print("✓ Token verified successfully!\n", .{});
    try stdout.print("  Subject:  {s}\n", .{claims.sub.?});
    try stdout.print("  Issuer:   {s}\n", .{claims.iss.?});
    try stdout.print("  Audience: {s}\n", .{claims.aud.?});
    try stdout.print("  JWT ID:   {s}\n", .{claims.jti.?});
    try stdout.print("  Expires:  {d} (in {d} seconds)\n\n", .{ claims.exp.?, claims.exp.? - getUnixTimestamp() });

    // Demo 3: Wrong key
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 3: Invalid Signature Detection                         │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var verifier2 = jwt.Verifier.init(allocator);
    defer verifier2.deinit();

    const wrong_result = verifier2.verify(token, .HS256, "wrong-secret");
    if (wrong_result) |_| {
        try stdout.print("✗ Unexpectedly verified with wrong key!\n\n", .{});
    } else |err| {
        try stdout.print("✓ Correctly rejected: {}\n\n", .{err});
    }

    // Demo 4: Expired token
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 4: Expiration Validation                               │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var exp_builder = jwt.Builder.init(allocator);
    defer exp_builder.deinit();

    try exp_builder.setSubject("expired-user");
    exp_builder.setExpiration(getUnixTimestamp() - 60); // Expired 1 minute ago

    const expired_token = try exp_builder.sign(.HS256, secret);
    defer allocator.free(expired_token);

    var exp_verifier = jwt.Verifier.init(allocator);
    defer exp_verifier.deinit();

    const exp_result = exp_verifier.verify(expired_token, .HS256, secret);
    if (exp_result) |_| {
        try stdout.print("✗ Unexpectedly accepted expired token!\n\n", .{});
    } else |err| {
        try stdout.print("✓ Correctly rejected expired token: {}\n\n", .{err});
    }

    // Demo 5: Different algorithms
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 5: Multiple Algorithms (HS256, HS384, HS512)           │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    const algorithms = [_]jwt.Algorithm{ .HS256, .HS384, .HS512 };

    for (algorithms) |alg| {
        const alg_token = try jwt.quickSign(allocator, "multi-alg-user", "demo", 3600, alg, "shared-secret");
        defer allocator.free(alg_token);

        var alg_claims = try jwt.quickVerify(allocator, alg_token, alg, "shared-secret");
        defer alg_claims.deinit();

        try stdout.print("  {s}: Token created and verified ✓\n", .{alg.name()});
    }

    try stdout.print("\n═══════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("All demos completed successfully!\n\n", .{});
}

fn signToken(allocator: std.mem.Allocator, stdout: anytype, args: []const []const u8) !void {
    const subject = args[2];
    const secret = args[3];

    var issuer: ?[]const u8 = null;
    var audience: ?[]const u8 = null;
    var expires: i64 = 3600;

    // Parse optional arguments
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--issuer") and i + 1 < args.len) {
            issuer = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--audience") and i + 1 < args.len) {
            audience = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--expires") and i + 1 < args.len) {
            expires = std.fmt.parseInt(i64, args[i + 1], 10) catch 3600;
            i += 1;
        }
    }

    var builder = jwt.Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject(subject);
    if (issuer) |iss| try builder.setIssuer(iss);
    if (audience) |aud| try builder.setAudience(aud);
    builder.setIssuedAt(getUnixTimestamp());
    builder.setExpiration(getUnixTimestamp() + expires);

    const token = try builder.sign(.HS256, secret);
    defer allocator.free(token);

    try stdout.print("{s}\n", .{token});
}

fn verifyToken(allocator: std.mem.Allocator, stdout: anytype, token: []const u8, secret: []const u8) !void {
    var verifier = jwt.Verifier.init(allocator);
    defer verifier.deinit();

    const claims = verifier.verify(token, .HS256, secret) catch |err| {
        try stdout.print("Verification failed: {}\n", .{err});
        return;
    };
    defer @constCast(&claims).deinit();

    try stdout.print("✓ Token verified!\n\n", .{});
    try stdout.print("Claims:\n", .{});
    if (claims.sub) |sub| try stdout.print("  sub: {s}\n", .{sub});
    if (claims.iss) |iss| try stdout.print("  iss: {s}\n", .{iss});
    if (claims.aud) |aud| try stdout.print("  aud: {s}\n", .{aud});
    if (claims.jti) |jti| try stdout.print("  jti: {s}\n", .{jti});
    if (claims.exp) |exp| try stdout.print("  exp: {d}\n", .{exp});
    if (claims.nbf) |nbf| try stdout.print("  nbf: {d}\n", .{nbf});
    if (claims.iat) |iat| try stdout.print("  iat: {d}\n", .{iat});
}

fn decodeToken(allocator: std.mem.Allocator, stdout: anytype, token: []const u8) !void {
    const decoded = jwt.decode(allocator, token) catch |err| {
        try stdout.print("Decode failed: {}\n", .{err});
        return;
    };
    defer allocator.free(decoded.header);
    defer allocator.free(decoded.payload);
    defer allocator.free(decoded.signature);

    try stdout.print("⚠ Decoded without verification (DO NOT TRUST)\n\n", .{});
    try stdout.print("Header:\n  {s}\n\n", .{decoded.header});
    try stdout.print("Payload:\n  {s}\n\n", .{decoded.payload});
    try stdout.print("Signature (base64):\n  {s}\n", .{decoded.signature});
}
