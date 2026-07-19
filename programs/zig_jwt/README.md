# zig_jwt

A pure-Zig JSON Web Token (JWT, RFC 7519) library with HMAC signing and verification: HS256, HS384, and HS512.

## What it does

- **Sign** JWTs with HMAC-SHA-256/384/512 (`Builder` / `quickSign`).
- **Verify** JWTs, including signature check and registered-claim validation for `exp`, `nbf`, `iss`, `aud`, and `sub`, with configurable clock-skew tolerance (`Verifier` / `quickVerify`). The `aud` claim is accepted in both RFC 7519 §4.1.3 forms — a single string or an array of strings — and the audience check passes if the expected value matches any member. For deterministic testing (or a trusted external time source), `Verifier.now_fn` overrides the wall clock used for `exp`/`nbf`.
- **Decode** a token's header and claims without verifying the signature (`decode`) — for inspection only; never trust unverified claims.
- Base64url encode/decode helpers (`base64UrlEncode` / `base64UrlDecode`).

Signature comparison during verification is constant-time.

Scope: this library implements only the HMAC family (HS256/HS384/HS512). It does not implement the asymmetric algorithms (RS*, PS*, ES*, EdDSA). The `none` algorithm exists as an enum variant but must never be accepted for verification of untrusted tokens.

## Library usage

```zig
const jwt = @import("jwt");

// Create a token
var builder = jwt.Builder.init(allocator);
defer builder.deinit();
try builder.setSubject("user123");
try builder.setIssuer("my-app");
try builder.setExpiration(exp_unix_seconds);
const token = try builder.sign(.HS256, "secret-key");

// Verify a token
var verifier = jwt.Verifier.init(allocator);
defer verifier.deinit();
verifier.setIssuer("my-app");
const claims = try verifier.verify(token, .HS256, "secret-key");
```

## Build

Requires Zig 0.16.

```sh
zig build            # build the static library + jwt-demo + jwt-bench
zig build test       # run unit tests + externally-anchored tier-1 vectors
```

The library is exposed as the `jwt` module via `b.addModule` and as a static library artifact, so it can be consumed as a dependency by other in-tree projects.

## CLI (jwt-demo)

A small demo/utility executable built alongside the library:

```
jwt-demo demo                         Run interactive demo
jwt-demo sign <subject> <secret>      Create a JWT token
jwt-demo verify <token> <secret>      Verify and decode a JWT
jwt-demo decode <token>               Decode without verification

Options for sign:
  --issuer <iss>     Set issuer claim
  --expires <sec>    Set expiration (default: 3600)
  --audience <aud>   Set audience claim

Options for verify:
  --alg <name>       Algorithm: HS256 (default), HS384, HS512
```

## Tests

`zig build test` runs the unit tests plus `src/tier1_anchors.zig`, which checks against externally-anchored vectors (RFC 7515 A.1 and cross-implementation goldens) rather than roundtrip-only tests.
