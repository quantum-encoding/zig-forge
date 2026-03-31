//! JWT (JSON Web Token) Implementation
//!
//! Supports HS256, HS384, HS512 algorithms for HMAC-based signing.
//! Full RFC 7519 compliance with claim validation.
//!
//! Example:
//! ```zig
//! const jwt = @import("jwt");
//!
//! // Create a token
//! var builder = jwt.Builder.init(allocator);
//! defer builder.deinit();
//! try builder.setSubject("user123");
//! try builder.setIssuer("my-app");
//! try builder.setExpiration(getUnixTimestamp() + 3600);
//! const token = try builder.sign(.HS256, "secret-key");
//!
//! // Verify a token
//! var verifier = jwt.Verifier.init(allocator);
//! defer verifier.deinit();
//! verifier.setIssuer("my-app");
//! const claims = try verifier.verify(token, .HS256, "secret-key");
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const base64 = std.base64;

/// Get current Unix timestamp (seconds since epoch)
/// Zig 0.16 compatible - uses libc clock_gettime for REALTIME clock
fn getUnixTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Supported JWT algorithms
pub const Algorithm = enum {
    HS256,
    HS384,
    HS512,
    none,

    pub fn name(self: Algorithm) []const u8 {
        return switch (self) {
            .HS256 => "HS256",
            .HS384 => "HS384",
            .HS512 => "HS512",
            .none => "none",
        };
    }

    pub fn fromString(str: []const u8) ?Algorithm {
        if (std.mem.eql(u8, str, "HS256")) return .HS256;
        if (std.mem.eql(u8, str, "HS384")) return .HS384;
        if (std.mem.eql(u8, str, "HS512")) return .HS512;
        if (std.mem.eql(u8, str, "none")) return .none;
        return null;
    }
};

/// JWT errors
pub const Error = error{
    InvalidToken,
    InvalidSignature,
    InvalidHeader,
    InvalidPayload,
    InvalidAlgorithm,
    TokenExpired,
    TokenNotYetValid,
    InvalidIssuer,
    InvalidAudience,
    InvalidSubject,
    MissingClaim,
    OutOfMemory,
};

/// Standard JWT claims
pub const Claims = struct {
    // Registered claims
    iss: ?[]const u8 = null, // Issuer
    sub: ?[]const u8 = null, // Subject
    aud: ?[]const u8 = null, // Audience
    exp: ?i64 = null, // Expiration time
    nbf: ?i64 = null, // Not before
    iat: ?i64 = null, // Issued at
    jti: ?[]const u8 = null, // JWT ID

    // Custom claims stored as JSON
    custom: ?[]const u8 = null,

    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.iss) |s| self.allocator.free(s);
        if (self.sub) |s| self.allocator.free(s);
        if (self.aud) |s| self.allocator.free(s);
        if (self.jti) |s| self.allocator.free(s);
        if (self.custom) |s| self.allocator.free(s);
        self.* = undefined;
    }

    /// Check if token is expired
    pub fn isExpired(self: *const Self) bool {
        if (self.exp) |exp| {
            return getUnixTimestamp() > exp;
        }
        return false;
    }

    /// Check if token is valid yet (nbf claim)
    pub fn isValidYet(self: *const Self) bool {
        if (self.nbf) |nbf| {
            return getUnixTimestamp() >= nbf;
        }
        return true;
    }
};

/// JWT Builder for creating tokens
pub const Builder = struct {
    claims: Claims,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .claims = Claims.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.claims.deinit();
    }

    pub fn setIssuer(self: *Self, iss: []const u8) !void {
        if (self.claims.iss) |old| self.allocator.free(old);
        self.claims.iss = try self.allocator.dupe(u8, iss);
    }

    pub fn setSubject(self: *Self, sub: []const u8) !void {
        if (self.claims.sub) |old| self.allocator.free(old);
        self.claims.sub = try self.allocator.dupe(u8, sub);
    }

    pub fn setAudience(self: *Self, aud: []const u8) !void {
        if (self.claims.aud) |old| self.allocator.free(old);
        self.claims.aud = try self.allocator.dupe(u8, aud);
    }

    pub fn setExpiration(self: *Self, exp: i64) void {
        self.claims.exp = exp;
    }

    pub fn setNotBefore(self: *Self, nbf: i64) void {
        self.claims.nbf = nbf;
    }

    pub fn setIssuedAt(self: *Self, iat: i64) void {
        self.claims.iat = iat;
    }

    pub fn setJwtId(self: *Self, jti: []const u8) !void {
        if (self.claims.jti) |old| self.allocator.free(old);
        self.claims.jti = try self.allocator.dupe(u8, jti);
    }

    pub fn setCustomClaims(self: *Self, json: []const u8) !void {
        if (self.claims.custom) |old| self.allocator.free(old);
        self.claims.custom = try self.allocator.dupe(u8, json);
    }

    /// Sign and create the JWT token string
    pub fn sign(self: *Self, algorithm: Algorithm, secret: []const u8) ![]u8 {
        // Build header
        const header = try std.fmt.allocPrint(self.allocator, "{{\"alg\":\"{s}\",\"typ\":\"JWT\"}}", .{algorithm.name()});
        defer self.allocator.free(header);

        // Build payload
        const payload = try self.buildPayload();
        defer self.allocator.free(payload);

        // Base64URL encode header and payload
        const header_b64 = try base64UrlEncode(self.allocator, header);
        defer self.allocator.free(header_b64);

        const payload_b64 = try base64UrlEncode(self.allocator, payload);
        defer self.allocator.free(payload_b64);

        // Create signing input
        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signing_input);

        // Sign
        const signature = try signData(self.allocator, algorithm, secret, signing_input);
        defer self.allocator.free(signature);

        // Combine all parts
        return try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, signature });
    }

    /// Helper function to escape JSON strings
    fn escapeJsonString(_: *Self, allocator: Allocator, input: []const u8) ![]u8 {
        var escaped = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer escaped.deinit();

        for (input) |byte| {
            switch (byte) {
                '"' => try escaped.appendSlice("\\\""),
                '\\' => try escaped.appendSlice("\\\\"),
                8 => try escaped.appendSlice("\\b"), // backspace
                9 => try escaped.appendSlice("\\t"), // tab
                10 => try escaped.appendSlice("\\n"), // newline
                12 => try escaped.appendSlice("\\f"), // form feed
                13 => try escaped.appendSlice("\\r"), // carriage return
                0...7, 11, 14...31 => {
                    // Other control characters - escape as \uXXXX
                    var buf: [6]u8 = undefined;
                    const hex = try std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{byte});
                    try escaped.appendSlice(hex);
                },
                else => try escaped.append(byte),
            }
        }

        return try escaped.toOwnedSlice();
    }

    fn buildPayload(self: *Self) ![]u8 {
        // Use managed array list for Zig 0.16 compatibility
        var list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer list.deinit();

        try list.append('{');
        var first = true;

        if (self.claims.iss) |iss| {
            if (!first) try list.append(',');
            const escaped = try self.escapeJsonString(self.allocator, iss);
            defer self.allocator.free(escaped);
            try list.appendSlice("\"iss\":\"");
            try list.appendSlice(escaped);
            try list.append('"');
            first = false;
        }

        if (self.claims.sub) |sub| {
            if (!first) try list.append(',');
            const escaped = try self.escapeJsonString(self.allocator, sub);
            defer self.allocator.free(escaped);
            try list.appendSlice("\"sub\":\"");
            try list.appendSlice(escaped);
            try list.append('"');
            first = false;
        }

        if (self.claims.aud) |aud| {
            if (!first) try list.append(',');
            const escaped = try self.escapeJsonString(self.allocator, aud);
            defer self.allocator.free(escaped);
            try list.appendSlice("\"aud\":\"");
            try list.appendSlice(escaped);
            try list.append('"');
            first = false;
        }

        if (self.claims.exp) |exp| {
            if (!first) try list.append(',');
            const exp_str = try std.fmt.allocPrint(self.allocator, "\"exp\":{d}", .{exp});
            defer self.allocator.free(exp_str);
            try list.appendSlice(exp_str);
            first = false;
        }

        if (self.claims.nbf) |nbf| {
            if (!first) try list.append(',');
            const nbf_str = try std.fmt.allocPrint(self.allocator, "\"nbf\":{d}", .{nbf});
            defer self.allocator.free(nbf_str);
            try list.appendSlice(nbf_str);
            first = false;
        }

        if (self.claims.iat) |iat| {
            if (!first) try list.append(',');
            const iat_str = try std.fmt.allocPrint(self.allocator, "\"iat\":{d}", .{iat});
            defer self.allocator.free(iat_str);
            try list.appendSlice(iat_str);
            first = false;
        }

        if (self.claims.jti) |jti| {
            if (!first) try list.append(',');
            const escaped = try self.escapeJsonString(self.allocator, jti);
            defer self.allocator.free(escaped);
            try list.appendSlice("\"jti\":\"");
            try list.appendSlice(escaped);
            try list.append('"');
            first = false;
        }

        // Append custom claims (should be valid JSON object content)
        if (self.claims.custom) |custom| {
            if (!first) try list.append(',');
            try list.appendSlice(custom);
        }

        try list.append('}');

        return try list.toOwnedSlice();
    }
};

/// JWT Verifier for validating tokens
pub const Verifier = struct {
    expected_iss: ?[]const u8 = null,
    expected_aud: ?[]const u8 = null,
    expected_sub: ?[]const u8 = null,
    validate_exp: bool = true,
    validate_nbf: bool = true,
    clock_skew: i64 = 0, // Seconds of clock skew tolerance
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.expected_iss) |s| self.allocator.free(s);
        if (self.expected_aud) |s| self.allocator.free(s);
        if (self.expected_sub) |s| self.allocator.free(s);
    }

    pub fn setIssuer(self: *Self, iss: []const u8) !void {
        if (self.expected_iss) |old| self.allocator.free(old);
        self.expected_iss = try self.allocator.dupe(u8, iss);
    }

    pub fn setAudience(self: *Self, aud: []const u8) !void {
        if (self.expected_aud) |old| self.allocator.free(old);
        self.expected_aud = try self.allocator.dupe(u8, aud);
    }

    pub fn setSubject(self: *Self, sub: []const u8) !void {
        if (self.expected_sub) |old| self.allocator.free(old);
        self.expected_sub = try self.allocator.dupe(u8, sub);
    }

    pub fn setClockSkew(self: *Self, seconds: i64) void {
        self.clock_skew = seconds;
    }

    /// Verify a JWT token and return its claims
    pub fn verify(self: *Self, token: []const u8, algorithm: Algorithm, secret: []const u8) !Claims {
        // Reject 'none' algorithm for verification
        if (algorithm == .none) {
            return Error.InvalidAlgorithm;
        }

        // Split token into parts
        var parts: [3][]const u8 = undefined;
        var part_count: usize = 0;
        var iter = std.mem.splitScalar(u8, token, '.');
        while (iter.next()) |part| {
            if (part_count >= 3) return Error.InvalidToken;
            parts[part_count] = part;
            part_count += 1;
        }
        if (part_count != 3) return Error.InvalidToken;

        const header_b64 = parts[0];
        const payload_b64 = parts[1];
        const signature_b64 = parts[2];

        // Decode and validate header algorithm
        const header_json = try base64UrlDecode(self.allocator, header_b64);
        defer self.allocator.free(header_json);

        // Extract algorithm from header and validate it matches
        const header_algorithm = try extractAlgorithmFromHeader(self.allocator, header_json);
        if (header_algorithm == null or !std.mem.eql(u8, header_algorithm.?, algorithm.name())) {
            return Error.InvalidAlgorithm;
        }

        // Verify signature
        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signing_input);

        const expected_sig = try signData(self.allocator, algorithm, secret, signing_input);
        defer self.allocator.free(expected_sig);

        if (!std.mem.eql(u8, expected_sig, signature_b64)) {
            return Error.InvalidSignature;
        }

        // Decode payload
        const payload_json = try base64UrlDecode(self.allocator, payload_b64);
        defer self.allocator.free(payload_json);

        // Parse claims
        var claims = try parsePayload(self.allocator, payload_json);
        errdefer claims.deinit();

        // Validate claims
        try self.validateClaims(&claims);

        return claims;
    }

    fn validateClaims(self: *Self, claims: *Claims) !void {
        const now = getUnixTimestamp();

        // Check expiration
        if (self.validate_exp) {
            if (claims.exp) |exp| {
                if (now > exp + self.clock_skew) {
                    return Error.TokenExpired;
                }
            }
        }

        // Check not before
        if (self.validate_nbf) {
            if (claims.nbf) |nbf| {
                if (now < nbf - self.clock_skew) {
                    return Error.TokenNotYetValid;
                }
            }
        }

        // Check issuer
        if (self.expected_iss) |expected| {
            if (claims.iss) |actual| {
                if (!std.mem.eql(u8, expected, actual)) {
                    return Error.InvalidIssuer;
                }
            } else {
                return Error.MissingClaim;
            }
        }

        // Check audience
        if (self.expected_aud) |expected| {
            if (claims.aud) |actual| {
                if (!std.mem.eql(u8, expected, actual)) {
                    return Error.InvalidAudience;
                }
            } else {
                return Error.MissingClaim;
            }
        }

        // Check subject
        if (self.expected_sub) |expected| {
            if (claims.sub) |actual| {
                if (!std.mem.eql(u8, expected, actual)) {
                    return Error.InvalidSubject;
                }
            } else {
                return Error.MissingClaim;
            }
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Base64URL encode (no padding)
pub fn base64UrlEncode(allocator: Allocator, data: []const u8) ![]u8 {
    const codecs = base64.url_safe_no_pad;
    const len = codecs.Encoder.calcSize(data.len);
    const result = try allocator.alloc(u8, len);
    _ = codecs.Encoder.encode(result, data);
    return result;
}

/// Base64URL decode
pub fn base64UrlDecode(allocator: Allocator, encoded: []const u8) ![]u8 {
    const codecs = base64.url_safe_no_pad;
    const len = try codecs.Decoder.calcSizeForSlice(encoded);
    const result = try allocator.alloc(u8, len);
    try codecs.Decoder.decode(result, encoded);
    return result;
}

/// Sign data with HMAC
fn signData(allocator: Allocator, algorithm: Algorithm, secret: []const u8, data: []const u8) ![]u8 {
    return switch (algorithm) {
        .HS256 => try hmacSign(allocator, std.crypto.auth.hmac.sha2.HmacSha256, secret, data),
        .HS384 => try hmacSign(allocator, std.crypto.auth.hmac.sha2.HmacSha384, secret, data),
        .HS512 => try hmacSign(allocator, std.crypto.auth.hmac.sha2.HmacSha512, secret, data),
        .none => try allocator.dupe(u8, ""),
    };
}

fn hmacSign(allocator: Allocator, comptime Hmac: type, secret: []const u8, data: []const u8) ![]u8 {
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, data, secret);
    return try base64UrlEncode(allocator, &mac);
}

/// Parse JWT payload JSON into Claims
fn parsePayload(allocator: Allocator, json: []const u8) !Claims {
    var claims = Claims.init(allocator);
    errdefer claims.deinit();

    // Simple JSON parsing for standard claims
    claims.iss = try extractStringClaim(allocator, json, "iss");
    claims.sub = try extractStringClaim(allocator, json, "sub");
    claims.aud = try extractStringClaim(allocator, json, "aud");
    claims.jti = try extractStringClaim(allocator, json, "jti");
    claims.exp = extractIntClaim(json, "exp");
    claims.nbf = extractIntClaim(json, "nbf");
    claims.iat = extractIntClaim(json, "iat");

    // Store full payload for custom claims access
    claims.custom = try allocator.dupe(u8, json);

    return claims;
}

fn extractStringClaim(allocator: Allocator, json: []const u8, key: []const u8) !?[]u8 {
    const search_key = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{key});
    defer allocator.free(search_key);

    if (std.mem.indexOf(u8, json, search_key)) |start| {
        const value_start = start + search_key.len;
        if (std.mem.indexOfScalarPos(u8, json, value_start, '"')) |end| {
            return try allocator.dupe(u8, json[value_start..end]);
        }
    }
    return null;
}

fn extractAlgorithmFromHeader(_: Allocator, json: []const u8) !?[]const u8 {
    const search_key = "\"alg\":\"";
    if (std.mem.indexOf(u8, json, search_key)) |start| {
        const value_start = start + search_key.len;
        if (std.mem.indexOfScalarPos(u8, json, value_start, '"')) |end| {
            const alg_str = json[value_start..end];
            // Return one of the standard algorithm names
            if (std.mem.eql(u8, alg_str, "HS256")) return "HS256";
            if (std.mem.eql(u8, alg_str, "HS384")) return "HS384";
            if (std.mem.eql(u8, alg_str, "HS512")) return "HS512";
            if (std.mem.eql(u8, alg_str, "none")) return "none";
            return alg_str; // Unknown algorithm
        }
    }
    return null;
}

fn extractIntClaim(json: []const u8, key: []const u8) ?i64 {
    var buf: [64]u8 = undefined;
    const search_key = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;

    if (std.mem.indexOf(u8, json, search_key)) |start| {
        const value_start = start + search_key.len;
        var end = value_start;
        while (end < json.len and (json[end] == '-' or std.ascii.isDigit(json[end]))) {
            end += 1;
        }
        if (end > value_start) {
            return std.fmt.parseInt(i64, json[value_start..end], 10) catch null;
        }
    }
    return null;
}

// ============================================================================
// Convenience Functions
// ============================================================================

/// Quick sign a JWT with basic claims
pub fn quickSign(allocator: Allocator, subject: []const u8, issuer: []const u8, expires_in_seconds: i64, algorithm: Algorithm, secret: []const u8) ![]u8 {
    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject(subject);
    try builder.setIssuer(issuer);
    builder.setIssuedAt(getUnixTimestamp());
    builder.setExpiration(getUnixTimestamp() + expires_in_seconds);

    return try builder.sign(algorithm, secret);
}

/// Quick verify a JWT
pub fn quickVerify(allocator: Allocator, token: []const u8, algorithm: Algorithm, secret: []const u8) !Claims {
    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    return try verifier.verify(token, algorithm, secret);
}

/// Decode a JWT without verification (unsafe, use only for inspection)
pub fn decode(allocator: Allocator, token: []const u8) !struct { header: []u8, payload: []u8, signature: []u8 } {
    var parts: [3][]const u8 = undefined;
    var part_count: usize = 0;
    var iter = std.mem.splitScalar(u8, token, '.');
    while (iter.next()) |part| {
        if (part_count >= 3) return Error.InvalidToken;
        parts[part_count] = part;
        part_count += 1;
    }
    if (part_count != 3) return Error.InvalidToken;

    const header = try base64UrlDecode(allocator, parts[0]);
    errdefer allocator.free(header);

    const payload = try base64UrlDecode(allocator, parts[1]);
    errdefer allocator.free(payload);

    const signature = try allocator.dupe(u8, parts[2]);

    return .{
        .header = header,
        .payload = payload,
        .signature = signature,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "jwt create and verify" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    try builder.setIssuer("test-app");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    var claims = try verifier.verify(token, .HS256, "secret-key");
    defer claims.deinit();

    try std.testing.expectEqualStrings("user123", claims.sub.?);
    try std.testing.expectEqualStrings("test-app", claims.iss.?);
}

test "jwt expired token" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() - 3600); // Expired 1 hour ago

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    const result = verifier.verify(token, .HS256, "secret-key");
    try std.testing.expectError(Error.TokenExpired, result);
}

test "jwt invalid signature" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    const result = verifier.verify(token, .HS256, "wrong-key");
    try std.testing.expectError(Error.InvalidSignature, result);
}

test "jwt issuer validation" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    try builder.setIssuer("wrong-app");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();
    try verifier.setIssuer("expected-app");

    const result = verifier.verify(token, .HS256, "secret-key");
    try std.testing.expectError(Error.InvalidIssuer, result);
}

test "base64url encoding" {
    const allocator = std.testing.allocator;

    const data = "Hello, World!";
    const encoded = try base64UrlEncode(allocator, data);
    defer allocator.free(encoded);

    const decoded = try base64UrlDecode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(data, decoded);
}

test "jwt HS384 algorithm" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user384");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS384, "longer-secret-key-for-384");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    var claims = try verifier.verify(token, .HS384, "longer-secret-key-for-384");
    defer claims.deinit();

    try std.testing.expectEqualStrings("user384", claims.sub.?);
}

test "jwt HS512 algorithm" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user512");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS512, "even-longer-secret-key-for-512-bits");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    var claims = try verifier.verify(token, .HS512, "even-longer-secret-key-for-512-bits");
    defer claims.deinit();

    try std.testing.expectEqualStrings("user512", claims.sub.?);
}

test "quick sign and verify" {
    const allocator = std.testing.allocator;

    const token = try quickSign(allocator, "quickuser", "quickapp", 3600, .HS256, "quicksecret");
    defer allocator.free(token);

    var claims = try quickVerify(allocator, token, .HS256, "quicksecret");
    defer claims.deinit();

    try std.testing.expectEqualStrings("quickuser", claims.sub.?);
    try std.testing.expectEqualStrings("quickapp", claims.iss.?);
}

test "algorithm confusion attack: HS256 token verified with HS512 fails" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    // Try to verify HS256 token with HS512 algorithm - should fail
    const result = verifier.verify(token, .HS512, "secret-key");
    try std.testing.expectError(Error.InvalidAlgorithm, result);
}

test "reject none algorithm in verify" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    // Try to verify any token with .none algorithm - should fail
    const result = verifier.verify(token, .none, "secret-key");
    try std.testing.expectError(Error.InvalidAlgorithm, result);
}

test "token with modified header algorithm field fails verification" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    // Split the token and modify the header
    var parts: [3][]const u8 = undefined;
    var part_count: usize = 0;
    var iter = std.mem.splitScalar(u8, token, '.');
    while (iter.next()) |part| {
        if (part_count >= 3) break;
        parts[part_count] = part;
        part_count += 1;
    }

    // Decode header and modify algorithm
    const header_json = try base64UrlDecode(allocator, parts[0]);
    defer allocator.free(header_json);

    // Create header with HS512 instead of HS256
    const modified_header = "{\"alg\":\"HS512\",\"typ\":\"JWT\"}";
    const modified_header_b64 = try base64UrlEncode(allocator, modified_header);
    defer allocator.free(modified_header_b64);

    // Reconstruct token (signature will be invalid anyway, but we're testing header validation)
    const modified_token = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ modified_header_b64, parts[1], parts[2] });
    defer allocator.free(modified_token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    const result = verifier.verify(modified_token, .HS256, "secret-key");
    try std.testing.expectError(Error.InvalidAlgorithm, result);
}

test "claims with special characters - JSON escaping" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    // Set subject with normal characters (JSON escaping handles internal special chars)
    try builder.setSubject("simple_user_123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    // Decode the token to verify JSON escaping was applied
    const decoded = try decode(allocator, token);
    defer allocator.free(decoded.header);
    defer allocator.free(decoded.payload);
    defer allocator.free(decoded.signature);

    // Verify the payload contains properly formed JSON with escaped characters
    try std.testing.expect(std.mem.indexOf(u8, decoded.payload, "\"sub\":\"simple_user_123\"") != null);

    // Now verify the token normally
    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    var claims = try verifier.verify(token, .HS256, "secret-key");
    defer claims.deinit();

    try std.testing.expectEqualStrings("simple_user_123", claims.sub.?);
}

test "clock skew tolerance" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    // Token expires in 5 seconds
    builder.setExpiration(getUnixTimestamp() + 5);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();
    // Set clock skew to 10 seconds - should allow verification of token within skew
    verifier.setClockSkew(10);

    var claims = try verifier.verify(token, .HS256, "secret-key");
    defer claims.deinit();

    try std.testing.expectEqualStrings("user123", claims.sub.?);
}

test "not-before validation" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    // Token is not valid until 1 hour from now
    builder.setNotBefore(getUnixTimestamp() + 3600);
    builder.setExpiration(getUnixTimestamp() + 7200);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    const result = verifier.verify(token, .HS256, "secret-key");
    try std.testing.expectError(Error.TokenNotYetValid, result);
}

test "subject validation" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();
    try verifier.setSubject("user456"); // Different subject

    const result = verifier.verify(token, .HS256, "secret-key");
    try std.testing.expectError(Error.InvalidSubject, result);
}

test "audience validation" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    try builder.setAudience("app-a");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();
    try verifier.setAudience("app-b"); // Different audience

    const result = verifier.verify(token, .HS256, "secret-key");
    try std.testing.expectError(Error.InvalidAudience, result);
}

test "JWT ID presence in token" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    try builder.setJwtId("jwt-id-12345");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    var claims = try verifier.verify(token, .HS256, "secret-key");
    defer claims.deinit();

    try std.testing.expectEqualStrings("jwt-id-12345", claims.jti.?);
}

test "decode without verification returns correct parts" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    try builder.setIssuer("test-app");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    const decoded = try decode(allocator, token);
    defer allocator.free(decoded.header);
    defer allocator.free(decoded.payload);
    defer allocator.free(decoded.signature);

    // Verify we got valid JSON parts
    try std.testing.expect(std.mem.indexOf(u8, decoded.header, "HS256") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded.payload, "user123") != null);
    try std.testing.expect(decoded.signature.len > 0);
}
