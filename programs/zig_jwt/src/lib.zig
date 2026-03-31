//! zig_jwt - JWT (JSON Web Token) Library
//!
//! A pure Zig implementation of JSON Web Tokens (RFC 7519)
//! with HMAC-SHA256/384/512 support.
//!
//! Features:
//! - HS256, HS384, HS512 algorithms
//! - Full claim validation (exp, nbf, iss, aud, sub)
//! - Clock skew tolerance
//! - Builder pattern for token creation
//! - Zero-copy where possible

pub const jwt = @import("jwt.zig");

pub const Algorithm = jwt.Algorithm;
pub const Claims = jwt.Claims;
pub const Builder = jwt.Builder;
pub const Verifier = jwt.Verifier;
pub const Error = jwt.Error;

pub const base64UrlEncode = jwt.base64UrlEncode;
pub const base64UrlDecode = jwt.base64UrlDecode;
pub const quickSign = jwt.quickSign;
pub const quickVerify = jwt.quickVerify;
pub const decode = jwt.decode;

test {
    _ = jwt;
}
