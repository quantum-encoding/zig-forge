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
│   ├── quantum_vault_ffi.zig    # Unified FFI module
│   ├── ml_kem_api.zig           # ML-KEM-768 implementation
│   ├── ml_dsa_v2.zig            # ML-DSA-65 implementation
│   ├── hybrid.zig               # Hybrid ML-KEM + X25519
│   └── rng.zig                  # Cross-platform secure RNG
├── include/
│   └── quantum_vault.h          # Generated C header
├── quantum-vault-sys/           # Rust FFI bindings crate
│   ├── src/
│   │   ├── lib.rs               # Main module + re-exports
│   │   ├── bindings.rs          # Raw FFI bindings
│   │   ├── error.rs             # Error types
│   │   ├── mlkem.rs             # ML-KEM safe wrappers
│   │   ├── mldsa.rs             # ML-DSA safe wrappers
│   │   ├── hybrid.rs            # Hybrid safe wrappers
│   │   └── secure.rs            # SecureBytes (zeroize on drop)
│   └── lib/                     # Pre-built libraries
├── tools/
│   └── gen_header.zig           # C header generator
└── docs/
    └── README.md                # This file
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

After `zig build install cross`:

```
zig-out/lib/
├── libquantum_vault.a              # Native static library
├── libquantum_vault_shared.dylib   # Native shared library (macOS)
├── libquantum_vault_macos-arm64.a
├── libquantum_vault_macos-x86_64.a
├── libquantum_vault_linux-x86_64.a
├── quantum_vault_windows-x86_64.lib
├── libquantum_vault_ios-arm64.a
├── libquantum_vault_android-arm64.a
└── libquantum_vault_android-arm32.a
```

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

// Hybrid (ML-KEM + X25519) for defense-in-depth
fn hybrid_example() -> Result<(), quantum_vault_sys::QvError> {
    let kp = HybridKeyPair::generate()?;
    let encaps = kp.ek.encaps()?;
    let shared_secret = kp.dk.decaps(&encaps.ciphertext)?;
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

### RNG Security
The library uses platform-specific cryptographic RNG:
- **macOS/iOS**: `arc4random_buf`
- **Linux/Android**: `getrandom` syscall
- **Windows**: `BCryptGenRandom`

All sources are cryptographically secure and automatically seeded.

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

// Hybrid encapsulation
QvError qv_hybrid_encaps(const QvHybridEncapsKey* ek, QvHybridEncapsResult* result);

// Hybrid decapsulation
QvError qv_hybrid_decaps(const QvHybridDecapsKey* dk, const QvHybridCiphertext* ct,
                         uint8_t shared_secret[32]);
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
