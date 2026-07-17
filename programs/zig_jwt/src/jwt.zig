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

    /// Sign and create the JWT token string.
    ///
    /// Audit H-2: `Algorithm.none` is refused at the sign side. The
    /// verifier already rejects `.none`, but a library that can mint
    /// an unauthenticated `header.payload.` triple is a footgun —
    /// downstream callers can pass that token to a less-strict
    /// verifier (theirs, or a different library, or a misconfigured
    /// instance of ours) and bypass authentication. The fix is
    /// symmetric: this library does not produce `.none` tokens, full
    /// stop. Tests that exercise the `.none` enum value still
    /// compile, they just have to demonstrate the rejection.
    pub fn sign(self: *Self, algorithm: Algorithm, secret: []const u8) ![]u8 {
        if (algorithm == .none) return Error.InvalidAlgorithm;

        // Build header via std.json.Stringify. The values interpolated
        // here are both library-controlled (algorithm.name() returns
        // one of "HS256"/"HS384"/"HS512" after the .none rejection
        // above; "JWT" is a static literal), so the previous
        // allocPrint(\"{{\\\"alg\\\":\\\"{s}\\\"\")  pattern was
        // safe-by-construction — but it kept the file on the
        // JSON-IN-FMT scanner's hit list, and a trusted CI gate
        // that ignores warnings normalizes ignoring real ones.
        const header = try std.json.Stringify.valueAlloc(self.allocator, .{
            .alg = algorithm.name(),
            .typ = "JWT",
        }, .{});
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

    /// Build the JWT payload object via std.json.Stringify (streaming
    /// writer). The previous implementation hand-built the JSON with
    /// a mix of ArrayList.appendSlice for keys, a local
    /// `escapeJsonString` for string values, and allocPrint for the
    /// numeric `exp/nbf/iat` claims — every escape rule maintained
    /// by hand, every claim wrapped in `\"key\":\"...\"` literals.
    /// Routing the whole construction through Stringify gets us
    /// escape correctness from the standard library and drops the
    /// scanner's JSON-IN-FMT hits on this file to zero.
    ///
    /// Custom claims: legacy contract is `"key":val,...` (no
    /// surrounding braces — the caller passes "object body" text
    /// that the builder splices into the registered-claims object).
    /// We preserve that contract by wrapping the bytes in `{...}`,
    /// parsing them as a `std.json.Value` object, and emitting each
    /// field through Stringify on the outer object. That gets us:
    ///
    ///   1. Defense in depth — custom bytes are validated as JSON
    ///      before going on the wire; previously a caller could
    ///      stuff invalid JSON in and only find out at verify time.
    ///   2. Re-escape — even if a custom value contains a `"`, std.
    ///      json.Stringify owns the output escape, so the token
    ///      remains parseable.
    fn buildPayload(self: *Self) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

        try jw.beginObject();

        if (self.claims.iss) |v| {
            try jw.objectField("iss");
            try jw.write(v);
        }
        if (self.claims.sub) |v| {
            try jw.objectField("sub");
            try jw.write(v);
        }
        if (self.claims.aud) |v| {
            try jw.objectField("aud");
            try jw.write(v);
        }
        if (self.claims.exp) |v| {
            try jw.objectField("exp");
            try jw.write(v);
        }
        if (self.claims.nbf) |v| {
            try jw.objectField("nbf");
            try jw.write(v);
        }
        if (self.claims.iat) |v| {
            try jw.objectField("iat");
            try jw.write(v);
        }
        if (self.claims.jti) |v| {
            try jw.objectField("jti");
            try jw.write(v);
        }

        // Custom claims: parse the legacy `"key":val,...` body and
        // re-emit each field through Stringify. Malformed custom
        // JSON now errors loudly (Error.InvalidPayload) rather than
        // silently producing a malformed token.
        if (self.claims.custom) |custom| {
            if (custom.len > 0) {
                const wrapped = try self.allocator.alloc(u8, custom.len + 2);
                defer self.allocator.free(wrapped);
                wrapped[0] = '{';
                @memcpy(wrapped[1 .. 1 + custom.len], custom);
                wrapped[wrapped.len - 1] = '}';

                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, wrapped, .{}) catch return Error.InvalidPayload;
                defer parsed.deinit();
                if (parsed.value != .object) return Error.InvalidPayload;

                var it = parsed.value.object.iterator();
                while (it.next()) |entry| {
                    // Claim-smuggling guard: a custom key that collides
                    // with a registered claim already emitted above would
                    // produce a duplicate-key payload (e.g. two `sub`
                    // fields). Our own verifier fail-closes on duplicates
                    // (std.json `duplicate_field_behavior = .@"error"`),
                    // but the signed token is on the wire — a downstream
                    // last-wins verifier (Node jsonwebtoken, most Go/Python
                    // parsers) would read the attacker's value. Refuse to
                    // mint such a token rather than emit a duplicate key.
                    if (isRegisteredClaim(entry.key_ptr.*)) return Error.InvalidPayload;
                    try jw.objectField(entry.key_ptr.*);
                    try jw.write(entry.value_ptr.*);
                }
            }
        }

        try jw.endObject();
        return aw.toOwnedSlice();
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

        // Extract algorithm from header and validate it matches.
        // After H-3 the helper returns an `Algorithm` enum value
        // parsed via std.json, so the comparison is on the enum and
        // not on string content — there is no way for a hostile
        // header to pass an unsupported algorithm that happens to
        // string-equal one we recognise.
        const header_algorithm = (try extractAlgorithmFromHeader(self.allocator, header_json)) orelse
            return Error.InvalidAlgorithm;
        if (header_algorithm != algorithm) return Error.InvalidAlgorithm;

        // Verify signature. Audit H-1: the comparison runs on the
        // raw HMAC bytes through `std.crypto.timing_safe.eql`, not
        // the base64 strings through `std.mem.eql`. `std.mem.eql`
        // short-circuits on the first mismatched byte, leaking the
        // length of the matching prefix as a timing side channel —
        // the textbook MAC-forgery oracle. `timing_safe.eql` runs in
        // time proportional to the array length regardless of where
        // the mismatch is.
        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signing_input);

        if (!try verifyHmacSignature(self.allocator, algorithm, secret, signing_input, signature_b64)) {
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

/// Base64URL decode.
///
/// `errdefer` releases `result` if `Decoder.decode` rejects the
/// input (e.g. tampered signature characters that pass length
/// validation but fail charset validation). The previous
/// implementation allocated the buffer and then returned the
/// decoder error unconditionally, leaving the buffer leaked —
/// a slow drain that any caller decoding adversarial base64
/// could trigger.
pub fn base64UrlDecode(allocator: Allocator, encoded: []const u8) ![]u8 {
    const codecs = base64.url_safe_no_pad;
    const len = try codecs.Decoder.calcSizeForSlice(encoded);
    const result = try allocator.alloc(u8, len);
    errdefer allocator.free(result);
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

/// Constant-time HMAC signature verification.
///
/// Audit H-1: `std.crypto.timing_safe.eql` is the only constant-time
/// primitive in std and it requires fixed-length arrays. We decode
/// the caller-supplied base64 signature to raw bytes, refuse any
/// length other than the algorithm's `mac_length`, compute the
/// expected MAC into a fixed array, and compare both arrays in
/// constant time. No early exit, no byte-by-byte short circuit.
fn verifyHmacSignature(
    allocator: Allocator,
    algorithm: Algorithm,
    secret: []const u8,
    signing_input: []const u8,
    signature_b64: []const u8,
) !bool {
    // Length sanity check before decoding — refuses obviously-
    // malformed signatures cheaply, and bounds the work the
    // verifier does on hostile input.
    if (signature_b64.len > 256) return false;

    const provided = base64UrlDecode(allocator, signature_b64) catch return false;
    defer allocator.free(provided);

    // Use an explicit local to make the defer ordering obvious to
    // both the reader and the compiler: the switch result is bound
    // to `ok`, the function then exits the scope, and only then
    // does `defer allocator.free(provided)` fire.
    const ok = switch (algorithm) {
        .HS256 => verifyHmacFixed(std.crypto.auth.hmac.sha2.HmacSha256, secret, signing_input, provided),
        .HS384 => verifyHmacFixed(std.crypto.auth.hmac.sha2.HmacSha384, secret, signing_input, provided),
        .HS512 => verifyHmacFixed(std.crypto.auth.hmac.sha2.HmacSha512, secret, signing_input, provided),
        // .none is rejected at the top of Verifier.verify; reaching
        // here would be a contract violation. Treat as a failed
        // verification rather than a panic so a programming error
        // can never accept a token.
        .none => false,
    };
    return ok;
}

fn verifyHmacFixed(
    comptime Hmac: type,
    secret: []const u8,
    data: []const u8,
    provided: []const u8,
) bool {
    if (provided.len != Hmac.mac_length) return false;
    var expected: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&expected, data, secret);
    const provided_arr: *const [Hmac.mac_length]u8 = provided[0..Hmac.mac_length];
    return std.crypto.timing_safe.eql([Hmac.mac_length]u8, expected, provided_arr.*);
}

// Audit H-3: header + payload parsing goes through std.json.
//
// The previous implementation used `std.mem.indexOf` substring
// searches with hand-rolled key patterns (`"\"alg\":\""`,
// `"\"iss\":\""`, …). That's structurally unsound for two reasons:
//
//   1. A custom claim whose VALUE happens to contain the bytes
//      `"sub":"victim"` would forge a `sub` claim on parse. The
//      pattern `"\"sub\":\""` matches inside another string just
//      as well as it matches an actual JSON key.
//
//   2. Order-of-keys, whitespace, escape sequences, Unicode escapes,
//      and duplicate keys all defeat naive substring matching in
//      different ways — std.json handles all of them correctly per
//      RFC 8259.
//
// The structured-parse path below uses std.json with
// `ignore_unknown_fields = true` so custom claims survive (we still
// keep the full payload bytes in `claims.custom` for callers that
// want them). String values are duped into the Claims allocator
// before the parser's arena is freed.

/// The RFC 7519 registered-claim names the Builder emits itself.
/// A custom claim colliding with one of these would smuggle a second
/// copy of the key into the signed payload (see the guard in
/// `buildPayload`).
fn isRegisteredClaim(key: []const u8) bool {
    const registered = [_][]const u8{ "iss", "sub", "aud", "exp", "nbf", "iat", "jti" };
    for (registered) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

const HeaderJson = struct {
    alg: ?[]const u8 = null,
    typ: ?[]const u8 = null,
};

const PayloadJson = struct {
    iss: ?[]const u8 = null,
    sub: ?[]const u8 = null,
    aud: ?[]const u8 = null,
    exp: ?i64 = null,
    nbf: ?i64 = null,
    iat: ?i64 = null,
    jti: ?[]const u8 = null,
};

/// Parse JWT payload JSON into Claims using std.json.
fn parsePayload(allocator: Allocator, json: []const u8) !Claims {
    var claims = Claims.init(allocator);
    errdefer claims.deinit();

    const parsed = std.json.parseFromSlice(PayloadJson, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch {
        return Error.InvalidPayload;
    };
    defer parsed.deinit();

    if (parsed.value.iss) |s| claims.iss = try allocator.dupe(u8, s);
    if (parsed.value.sub) |s| claims.sub = try allocator.dupe(u8, s);
    if (parsed.value.aud) |s| claims.aud = try allocator.dupe(u8, s);
    if (parsed.value.jti) |s| claims.jti = try allocator.dupe(u8, s);
    claims.exp = parsed.value.exp;
    claims.nbf = parsed.value.nbf;
    claims.iat = parsed.value.iat;

    // Keep the original payload bytes so callers can read custom
    // claims (everything outside the registered set above) without
    // re-parsing. Storing the *original* bytes — not a serialized
    // version of the registered subset — preserves order, whitespace,
    // and any non-string custom values.
    claims.custom = try allocator.dupe(u8, json);

    return claims;
}

/// Parse a JWT header and return the algorithm enum it declares.
/// Returns null if the header is malformed JSON, missing `alg`, or
/// declares an unsupported algorithm name.
fn extractAlgorithmFromHeader(allocator: Allocator, json: []const u8) !?Algorithm {
    const parsed = std.json.parseFromSlice(HeaderJson, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const alg_str = parsed.value.alg orelse return null;
    return Algorithm.fromString(alg_str);
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

// ── Audit regression tests ──────────────────────────────────────

test "H-2: Builder.sign refuses Algorithm.none" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    // The library must NOT produce an unauthenticated `header.payload.`
    // triple even when the caller asks for it — sign-side rejection
    // closes the alg-none footgun symmetrically with the verify side.
    const result = builder.sign(.none, "ignored");
    try std.testing.expectError(Error.InvalidAlgorithm, result);
}

test "H-1: signature comparison runs in constant time on raw HMAC bytes" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    // Tamper the very FIRST byte of the signature. With a
    // short-circuiting `mem.eql`, this would still reject (and
    // would do so faster than a tamper at the last byte — that's
    // the original timing oracle). With `timing_safe.eql` it just
    // rejects. We can't observe wall-clock equivalence in a unit
    // test, but we can at least confirm that early-mismatched
    // signatures are still rejected (i.e. the new path is
    // functionally correct).
    var tampered = try allocator.alloc(u8, token.len);
    defer allocator.free(tampered);
    @memcpy(tampered, token);
    const last_dot = std.mem.lastIndexOfScalar(u8, tampered, '.').?;
    // Flip a bit in the first signature character.
    tampered[last_dot + 1] ^= 0x01;

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();
    try std.testing.expectError(
        Error.InvalidSignature,
        verifier.verify(tampered, .HS256, "secret-key"),
    );

    // Tamper the LAST byte of the signature too. With the old
    // short-circuit compare, this mismatch was found at a different
    // index — the timing oracle's distinguishing observable. We
    // assert correctness only here; the constant-time property is
    // a structural guarantee of `std.crypto.timing_safe.eql`.
    @memcpy(tampered, token);
    tampered[tampered.len - 1] ^= 0x01;
    try std.testing.expectError(
        Error.InvalidSignature,
        verifier.verify(tampered, .HS256, "secret-key"),
    );
}

test "H-1: signatures of the wrong length are rejected without decoding" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("user123");
    builder.setExpiration(getUnixTimestamp() + 3600);

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    // Replace the signature with one byte of base64 noise — too
    // short to be a real HMAC-SHA256 output (32 bytes raw = 43
    // base64 chars).
    const last_dot = std.mem.lastIndexOfScalar(u8, token, '.').?;
    const short = try std.fmt.allocPrint(allocator, "{s}.A", .{token[0..last_dot]});
    defer allocator.free(short);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();
    try std.testing.expectError(
        Error.InvalidSignature,
        verifier.verify(short, .HS256, "secret-key"),
    );
}

test "H-3: custom claim whose value embeds \"sub\":\"victim\" does not spoof sub" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    // The actual subject is "real". The custom claim carries a
    // string whose VALUE contains bytes that look like a `sub`
    // field — the old substring extractor would have found it.
    try builder.setSubject("real");
    builder.setExpiration(getUnixTimestamp() + 3600);

    // Inject a custom claim that, on substring-search, looks like
    // a `sub` field. The std.json parser must ignore it as
    // structural data — it's the value of `note`, not a separate
    // top-level key.
    try builder.setCustomClaims("\"note\":\"\\\"sub\\\":\\\"victim\\\"\"");

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();

    var claims = try verifier.verify(token, .HS256, "secret-key");
    defer claims.deinit();

    // The structurally-correct parse keeps `sub` as "real".
    try std.testing.expectEqualStrings("real", claims.sub.?);
}

test "H-3: malformed payload JSON is rejected (Error.InvalidPayload)" {
    const allocator = std.testing.allocator;

    // Hand-build a token whose payload is invalid JSON. We compute
    // the correct HMAC over it so that signature verification
    // wouldn't be what catches it — the parse step must.
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const malformed_payload = "{not json at all";

    const header_b64 = try base64UrlEncode(allocator, header);
    defer allocator.free(header_b64);
    const payload_b64 = try base64UrlEncode(allocator, malformed_payload);
    defer allocator.free(payload_b64);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);
    const sig = try signData(allocator, .HS256, "secret-key", signing_input);
    defer allocator.free(sig);
    const token = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, sig });
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();
    try std.testing.expectError(
        Error.InvalidPayload,
        verifier.verify(token, .HS256, "secret-key"),
    );
}

test "H-3: malformed header JSON is rejected (Error.InvalidAlgorithm)" {
    const allocator = std.testing.allocator;

    // The header isn't even JSON. With the old substring matcher,
    // a header missing the literal `"alg":"` would return null and
    // we'd return InvalidAlgorithm — same end-state. The point of
    // this test is to lock in the std.json path: malformed header
    // ⇒ parseFromSlice fails ⇒ extractAlgorithmFromHeader returns
    // null ⇒ verify returns InvalidAlgorithm. Same outcome, but
    // now driven by a real parser instead of a string search.
    const garbage_header = "not a header";
    const payload = "{\"sub\":\"x\"}";

    const header_b64 = try base64UrlEncode(allocator, garbage_header);
    defer allocator.free(header_b64);
    const payload_b64 = try base64UrlEncode(allocator, payload);
    defer allocator.free(payload_b64);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);
    const sig = try signData(allocator, .HS256, "secret-key", signing_input);
    defer allocator.free(sig);
    const token = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, sig });
    defer allocator.free(token);

    var verifier = Verifier.init(allocator);
    defer verifier.deinit();
    try std.testing.expectError(
        Error.InvalidAlgorithm,
        verifier.verify(token, .HS256, "secret-key"),
    );
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
