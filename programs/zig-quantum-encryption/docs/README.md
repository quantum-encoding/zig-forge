# Quantum Vault - Post-Quantum Cryptography Library

A Zig implementation of post-quantum cryptographic algorithms for the Quantum Vault crypto wallet, with Rust FFI bindings for Tauri integration.

## Algorithms Implemented

| Algorithm | Standard | Security Level | Use Case |
|-----------|----------|----------------|----------|
| **ML-KEM-768** | FIPS 203 | 192-bit (AES-192) | Key Encapsulation |
| **ML-DSA-65** | FIPS 204 | 192-bit (AES-192) | Digital Signatures |
| **Hybrid** | ML-KEM + X25519 | Defense-in-depth | Key Encapsulation |

## Key Sizes

| Component | ML-KEM-768 | ML-DSA-65 | Hybrid |
|-----------|------------|-----------|--------|
| Public Key | 1184 bytes | 1952 bytes | 1216 bytes |
| Private Key | 2400 bytes | 4032 bytes | 2432 bytes |
| Ciphertext | 1088 bytes | - | 1120 bytes |
| Signature | - | 3309 bytes | - |
| Shared Secret | 32 bytes | - | 32 bytes |

## Project Structure

```
zig-quantum-encryption/
├── src/
│   ├── quantum_vault_ffi.zig      # Unified C ABI (the only `export fn` surface) + C header text
│   ├── ml_kem.zig                 # ML-KEM polynomial arithmetic, NTT, K-PKE
│   ├── ml_kem_api.zig             # ML-KEM-768 KeyGen / Encaps / Decaps (FIPS 203)
│   ├── ml_dsa.zig                 # ML-DSA-65 KeyGen / Sign / Verify (FIPS 204)
│   ├── hybrid.zig                 # Hybrid ML-KEM-768 + X25519, combiners v1 and v2
│   ├── rng.zig                    # Cross-platform secure RNG
│   ├── ml_kem_tier1_anchors.zig   # NIST ACVP KATs, ML-KEM-768
│   ├── ml_dsa_tier1_anchors.zig   # NIST ACVP KATs, ML-DSA-65
│   └── nist_vectors.zig           # Second ACVP decaps vector + size assertions
├── include/
│   └── quantum_vault.h            # Generated C header (`zig build gen-header`)
├── quantum-vault-sys/             # Rust FFI bindings crate
│   ├── build.rs                   # Finds the static lib; refuses one whose qv_version() is stale
│   ├── include/quantum_vault.h    # Copy of the generated header
│   ├── src/
│   │   ├── lib.rs                 # Main module + re-exports
│   │   ├── bindings.rs            # Raw FFI bindings
│   │   ├── error.rs               # Error types
│   │   ├── mlkem.rs               # ML-KEM safe wrappers
│   │   ├── mldsa.rs               # ML-DSA safe wrappers
│   │   ├── hybrid.rs              # Hybrid safe wrappers (v1 + v2) and KATs
│   │   └── secure.rs              # SecureBytes (zeroize on drop)
│   └── lib/                       # Local drop-in for prebuilt libs — gitignored, not in the repo
├── tools/
│   ├── gen_header.zig             # C header generator
│   ├── hybrid_vectors.zig         # Prints the hybrid KATs (`zig build hybrid-vectors`)
│   └── secrets.zig                # Encrypted secrets CLI built from the same tree
├── worker/                        # Cloudflare Worker + WASM glue
└── docs/
    ├── README.md                  # This file
    ├── HYBRID-V2.md               # Hybrid wire format, both combiners, test vectors
    ├── CLAIMS-AUDIT.md            # Every README claim checked against the code
    └── TAURI_INTEGRATION.md       # Application integration sample
```

## Building

### Prerequisites
- Zig 0.16+
- Rust 1.70+ (for Rust bindings)

### Build Commands

```bash
# Build native libraries
zig build

# Build for all platforms
zig build cross

# Generate C header
zig build gen-header

# Run tests
zig build test

# Run benchmarks
zig build bench
```

### Output Libraries

After `zig build` (native) and `zig build cross`:

```
zig-out/lib/
├── libquantum_crypto.a               # Native static library (unified C ABI)
├── libquantum_crypto_shared.dylib    # Native shared library (.so / .dll elsewhere)
├── libquantum-crypto-pqc.a           # Legacy ML-KEM-only static library
├── libquantum_crypto_macos-arm64.a   # ReleaseSafe
├── libquantum_crypto_macos-x86_64.a  # ReleaseSafe
├── libquantum_crypto_linux-x86_64.a  # ReleaseSafe
├── quantum_crypto_windows-x86_64.lib # ReleaseSafe
├── libquantum_crypto_ios-arm64.a     # ReleaseFast + strip (iOS dyld constraint)
├── libquantum_crypto_android-arm64.a # ReleaseSafe, PIC
└── libquantum_crypto_android-arm32.a # ReleaseSafe, PIC
```

`quantum-vault-sys/build.rs` links, in order of preference: a lib in
`quantum-vault-sys/lib/` (named either `quantum_vault_<target>` or
`quantum_crypto_<target>`), then `../zig-out/lib/` from a local `zig build` /
`zig build cross`. `quantum-vault-sys/lib/` is **gitignored** — a fresh clone
has no prebuilt libraries and must run `zig build` first. Whatever archive is
picked, `build.rs` scans it for the `qv_version()` string declared in
`src/quantum_vault_ffi.zig` (`VERSION_STRING`) and fails the build if it is
missing, so a library built from older source cannot be linked by mistake.

Archives destined for Xcode must be repacked with the repo-root
`scripts/repack-for-xcode.sh` (Zig 0.16 writes 2-byte-aligned Mach-O archive
members; Apple's ld-prime requires 8).

## Rust Integration

### Adding to Cargo.toml

```toml
[dependencies]
quantum-vault-sys = { path = "path/to/quantum-vault-sys" }
```

### Basic Usage

```rust
use quantum_vault_sys::{MlKemKeyPair, MlDsaKeyPair, HybridKeyPair};

// ML-KEM-768 Key Encapsulation
fn ml_kem_example() -> Result<(), quantum_vault_sys::QvError> {
    // Alice generates a key pair
    let alice_kp = MlKemKeyPair::generate()?;

    // Bob encapsulates a shared secret using Alice's public key
    let encaps_result = alice_kp.ek.encaps()?;

    // Bob sends the ciphertext to Alice
    let ciphertext = encaps_result.ciphertext;

    // Alice decapsulates to recover the shared secret
    let alice_ss = alice_kp.dk.decaps(&ciphertext)?;

    // Both now have the same 32-byte shared secret
    assert_eq!(encaps_result.shared_secret.as_bytes(), alice_ss.as_bytes());
    Ok(())
}

// ML-DSA-65 Digital Signatures
fn ml_dsa_example() -> Result<(), quantum_vault_sys::QvError> {
    // Generate signing key pair
    let kp = MlDsaKeyPair::generate()?;

    // Sign a message
    let message = b"Transaction: Send 100 QV to Alice";
    let signature = kp.sk.sign(message)?;

    // Verify the signature
    kp.pk.verify(message, &signature)?;
    Ok(())
}

// Hybrid (ML-KEM + X25519) for defense-in-depth — v2 combiner for new data
fn hybrid_example() -> Result<(), quantum_vault_sys::QvError> {
    let kp = HybridKeyPair::generate()?;
    let encaps = kp.ek.encaps_v2()?;
    let shared_secret = kp.dk.decaps_v2(&encaps.ciphertext)?;
    assert_eq!(encaps.shared_secret.as_bytes(), shared_secret.as_bytes());

    // Data written with the original combiner opens with the v1 pair:
    // kp.ek.encaps() / kp.dk.decaps(&ct). Same keys, same ciphertext layout,
    // different shared secret — the caller must know which version wrote it.
    Ok(())
}
```

## Tauri Integration

### Tauri Command Example

```rust
use quantum_vault_sys::{MlKemKeyPair, MlDsaKeyPair};
use tauri::State;
use std::sync::Mutex;

struct WalletState {
    mlkem_keypair: Option<MlKemKeyPair>,
    mldsa_keypair: Option<MlDsaKeyPair>,
}

#[tauri::command]
fn generate_keys(state: State<Mutex<WalletState>>) -> Result<String, String> {
    let mut wallet = state.lock().map_err(|e| e.to_string())?;

    // Generate post-quantum key pairs
    wallet.mlkem_keypair = Some(MlKemKeyPair::generate().map_err(|e| e.to_string())?);
    wallet.mldsa_keypair = Some(MlDsaKeyPair::generate().map_err(|e| e.to_string())?);

    // Return public keys for display
    Ok(format!(
        "ML-KEM public key: {} bytes, ML-DSA public key: {} bytes",
        wallet.mlkem_keypair.as_ref().unwrap().ek.as_bytes().len(),
        wallet.mldsa_keypair.as_ref().unwrap().pk.as_bytes().len()
    ))
}

#[tauri::command]
fn sign_transaction(
    state: State<Mutex<WalletState>>,
    transaction: String,
) -> Result<Vec<u8>, String> {
    let wallet = state.lock().map_err(|e| e.to_string())?;
    let kp = wallet.mldsa_keypair.as_ref().ok_or("No key pair")?;

    let signature = kp.sk.sign(transaction.as_bytes())
        .map_err(|e| e.to_string())?;

    Ok(signature.as_bytes().to_vec())
}
```

## Security Considerations

### Memory Safety
- All private keys are automatically zeroed when dropped
- Use `SecureBytes<N>` for handling sensitive data
- The library uses constant-time operations to prevent timing attacks

### Hybrid Mode
The hybrid scheme combines ML-KEM-768 (post-quantum) with X25519 (classical):
- If ML-KEM is broken, X25519 still provides security
- If X25519 is broken (by quantum computers), ML-KEM still provides security
- **Recommendation**: Use hybrid mode for maximum security during the transition period

Two shared-secret combiners exist over the same key and ciphertext layout:

- **v2** (`encaps_v2` / `decaps_v2`, `qv_hybrid_*_v2`) —
  `HKDF-SHA3-256(salt = "", IKM = ss_M ‖ ss_X ‖ ct_X ‖ pk_X, info = "HYBRID-ML-KEM-768-X25519-v2", L = 32)`,
  binding both X25519 public keys as X-Wing does. **Use this for new data.**
- **v1** (`encaps` / `decaps`, `qv_hybrid_*`) —
  `SHA3-256("HYBRID-ML-KEM-768-X25519-v1" ‖ ss_M ‖ ss_X)`. Kept so existing
  data still decapsulates.

The ciphertext carries no version marker; record the version in whatever
envelope wraps the ciphertext. Exact definitions, the trade-off, and test
vectors: [`HYBRID-V2.md`](HYBRID-V2.md).

### RNG Security
The library uses platform-specific cryptographic RNG:
- **macOS/iOS**: `arc4random_buf`
- **Linux/Android**: `getrandom` syscall
- **Windows**: `BCryptGenRandom`
- **WASM**: no in-module source; the host must supply randomness via the
  imported hook (`crypto.getRandomValues` in `worker/quantum-vault.js`)

All native sources are cryptographically secure and automatically seeded. An
RNG failure is reported as `QV_RNG_FAILURE`, never papered over.

## C API Reference

### ML-KEM-768

```c
// Generate key pair
QvError qv_mlkem768_keygen(QvMlKemKeyPair* keypair);

// Encapsulate shared secret
QvError qv_mlkem768_encaps(const QvMlKemEncapsKey* ek, QvMlKemEncapsResult* result);

// Decapsulate to recover shared secret
QvError qv_mlkem768_decaps(const QvMlKemDecapsKey* dk, const QvMlKemCiphertext* ct,
                           uint8_t shared_secret[32]);
```

### ML-DSA-65

```c
// Generate key pair (seed can be NULL for random)
QvError qv_mldsa65_keygen(QvMlDsaKeyPair* keypair, const uint8_t seed[32]);

// Sign message
QvError qv_mldsa65_sign(const QvMlDsaSecretKey* sk, const uint8_t* message,
                        size_t message_len, QvMlDsaSignature* signature, bool randomized);

// Verify signature
QvError qv_mldsa65_verify(const QvMlDsaPublicKey* pk, const uint8_t* message,
                          size_t message_len, const QvMlDsaSignature* signature);
```

### Hybrid

```c
// Generate hybrid key pair
QvError qv_hybrid_keygen(QvHybridKeyPair* keypair);

// Hybrid encapsulation / decapsulation, v2 combiner (use for new data)
QvError qv_hybrid_encaps_v2(const QvHybridEncapsKey* ek, QvHybridEncapsResult* result);
QvError qv_hybrid_decaps_v2(const QvHybridDecapsKey* dk, const QvHybridCiphertext* ct,
                            uint8_t shared_secret[32]);

// Hybrid encapsulation / decapsulation, v1 combiner (existing data)
QvError qv_hybrid_encaps(const QvHybridEncapsKey* ek, QvHybridEncapsResult* result);
QvError qv_hybrid_decaps(const QvHybridDecapsKey* dk, const QvHybridCiphertext* ct,
                         uint8_t shared_secret[32]);

// Bare v2 combiner, for cross-implementation known-answer tests
void qv_hybrid_combine_v2(const uint8_t ss_m[32], const uint8_t ss_x[32],
                          const uint8_t ct_x[32], const uint8_t pk_x[32], uint8_t out[32]);

// Library version, e.g. "quantum-vault-pqc-1.1.0"
const char* qv_version(void);
```

## Error Codes

| Code | Name | Description |
|------|------|-------------|
| 0 | `QV_SUCCESS` | Operation successful |
| -1 | `QV_INVALID_PARAMETER` | Invalid input parameter |
| -2 | `QV_RNG_FAILURE` | Random number generation failed |
| -3 | `QV_MEMORY_ERROR` | Memory allocation failed |
| -10 to -15 | `QV_MLKEM_*` | ML-KEM specific errors |
| -20 to -25 | `QV_MLDSA_*` | ML-DSA specific errors |
| -30 to -33 | `QV_HYBRID_*` | Hybrid specific errors |

## License

MIT OR Apache-2.0
