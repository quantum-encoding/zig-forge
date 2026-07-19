# gcp_auth

Pure-Zig Google Cloud OAuth2 authentication library: it acquires and refreshes the bearer token that every Google Cloud REST API expects in its `Authorization: Bearer <token>` header.

## What it does

`gcp_auth` obtains OAuth2 access tokens for GCP services through four strategies, exposed as the `TokenProvider` union and individual provider structs:

- **Service Account** (`ServiceAccountProvider`) — builds a signed JWT assertion (RS256, pure-Zig RSA-SHA256 via `std.crypto.ff`, zero libc) and exchanges it at Google's token endpoint.
- **Application Default Credentials** (`ADCProvider`) — exchanges a stored refresh token for an access token.
- **Metadata Server** (`MetadataProvider`) — reads the instance service-account token from the GCE/Cloud Run metadata server.
- **Static Token** (`StaticProvider`) — a caller-supplied token for testing or manual injection.

`autoDetect` picks a provider from the environment, and `apiGet` / `apiPost` / `apiPostStreaming` / `apiPut` / `apiPatch` / `apiDelete` are thin helpers that attach the bearer header and issue the request. HTTP is performed through the in-tree `http_sentinel` client.

## Security notes

- The token endpoint host is validated against an exact-match allowlist (`oauth2.googleapis.com`, `accounts.google.com`) to prevent SSRF via an attacker-controlled `token_uri` in service-account JSON — see `isAllowedTokenUri`.
- The RSA private-key operation uses the constant-time (`cmov`) modular-exponentiation path; the source enforces at comptime that `std.options.side_channels_mitigations` is not `.none`.
- Every produced signature is self-verified (`sig^e mod n == EM`) before release — the Boneh–DeMillo–Lipton ("Bellcore") fault-attack countermeasure. A bit-flip during the private-key modexp becomes `error.SignatureVerificationFailed` instead of a key-leaking faulty signature; signing fails closed.
- JWT claims are emitted with `std.json.Stringify` (no hand-rolled escaper), so no claim value can break out of its JSON string.
- `sign()`'s correctness is anchored to an external OpenSSL-generated golden signature (`src/tests.zig`), not merely self-consistency roundtrips.
- Access-token buffers are zeroed on `deinit`; RSA private-key DER is zeroed on `deinit`.

## Build

Requires Zig 0.16.0.

```sh
/usr/local/zig/zig build        # build the `gcp-auth` module
/usr/local/zig/zig build test   # run the test suite
```

The library is consumed as the `gcp-auth` module (`b.addModule` in `build.zig`) and depends on the in-tree `http_sentinel` module.
