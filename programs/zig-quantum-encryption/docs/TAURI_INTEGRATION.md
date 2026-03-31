# Tauri Integration Guide

Quick guide for integrating Quantum Vault into a Rust/Tauri/Svelte crypto wallet.

## Step 1: Add Dependency

In your Tauri app's `src-tauri/Cargo.toml`:

```toml
[dependencies]
quantum-vault-sys = { path = "../quantum-vault-sys" }
```

Or copy the `quantum-vault-sys` directory into your project.

## Step 2: Copy Libraries

Copy the pre-built libraries for your target platforms:

```bash
# From the zig-quantum-encryption directory
cp -r quantum-vault-sys/lib/* your-tauri-app/src-tauri/quantum-vault-sys/lib/
```

Required libraries per platform:
- macOS arm64: `libquantum_vault_macos-arm64.a`
- macOS x86_64: `libquantum_vault_macos-x86_64.a`
- Windows: `quantum_vault_windows-x86_64.lib`
- Linux: `libquantum_vault_linux-x86_64.a`

## Step 3: Tauri Commands

Add these commands to `src-tauri/src/main.rs`:

```rust
use quantum_vault_sys::{
    MlKemKeyPair, MlKemEncapsKey, MlKemCiphertext,
    MlDsaKeyPair, MlDsaPublicKey, MlDsaSignature,
    HybridKeyPair, HybridEncapsKey, HybridCiphertext,
    QvError,
};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::State;

// Wallet state
pub struct WalletState {
    pub mlkem_keypair: Option<MlKemKeyPair>,
    pub mldsa_keypair: Option<MlDsaKeyPair>,
    pub hybrid_keypair: Option<HybridKeyPair>,
}

impl Default for WalletState {
    fn default() -> Self {
        Self {
            mlkem_keypair: None,
            mldsa_keypair: None,
            hybrid_keypair: None,
        }
    }
}

// Response types for frontend
#[derive(Serialize)]
pub struct KeyGenResponse {
    pub mlkem_public_key: Vec<u8>,
    pub mldsa_public_key: Vec<u8>,
    pub hybrid_public_key: Vec<u8>,
}

#[derive(Serialize)]
pub struct EncapsResponse {
    pub ciphertext: Vec<u8>,
    pub shared_secret: Vec<u8>,
}

#[derive(Serialize)]
pub struct SignResponse {
    pub signature: Vec<u8>,
}

// Commands
#[tauri::command]
pub fn generate_wallet_keys(
    state: State<Mutex<WalletState>>,
) -> Result<KeyGenResponse, String> {
    let mut wallet = state.lock().map_err(|e| e.to_string())?;

    // Generate all key pairs
    let mlkem = MlKemKeyPair::generate().map_err(|e| format!("ML-KEM keygen failed: {}", e))?;
    let mldsa = MlDsaKeyPair::generate().map_err(|e| format!("ML-DSA keygen failed: {}", e))?;
    let hybrid = HybridKeyPair::generate().map_err(|e| format!("Hybrid keygen failed: {}", e))?;

    let response = KeyGenResponse {
        mlkem_public_key: mlkem.ek.as_bytes().to_vec(),
        mldsa_public_key: mldsa.pk.as_bytes().to_vec(),
        hybrid_public_key: hybrid.ek.as_bytes().to_vec(),
    };

    wallet.mlkem_keypair = Some(mlkem);
    wallet.mldsa_keypair = Some(mldsa);
    wallet.hybrid_keypair = Some(hybrid);

    Ok(response)
}

#[tauri::command]
pub fn sign_message(
    state: State<Mutex<WalletState>>,
    message: Vec<u8>,
) -> Result<SignResponse, String> {
    let wallet = state.lock().map_err(|e| e.to_string())?;
    let kp = wallet.mldsa_keypair.as_ref().ok_or("Wallet not initialized")?;

    let signature = kp.sk.sign(&message).map_err(|e| format!("Signing failed: {}", e))?;

    Ok(SignResponse {
        signature: signature.as_bytes().to_vec(),
    })
}

#[tauri::command]
pub fn verify_signature(
    public_key: Vec<u8>,
    message: Vec<u8>,
    signature: Vec<u8>,
) -> Result<bool, String> {
    if public_key.len() != 1952 {
        return Err("Invalid public key length".to_string());
    }
    if signature.len() != 3309 {
        return Err("Invalid signature length".to_string());
    }

    let pk_array: [u8; 1952] = public_key.try_into().map_err(|_| "Invalid public key")?;
    let sig_array: [u8; 3309] = signature.try_into().map_err(|_| "Invalid signature")?;

    let pk = MlDsaPublicKey::from_bytes(&pk_array);
    let sig = MlDsaSignature::from_bytes(&sig_array);

    Ok(pk.verify(&message, &sig).is_ok())
}

#[tauri::command]
pub fn hybrid_encaps(
    public_key: Vec<u8>,
) -> Result<EncapsResponse, String> {
    if public_key.len() != 1216 {
        return Err("Invalid hybrid public key length".to_string());
    }

    let pk_array: [u8; 1216] = public_key.try_into().map_err(|_| "Invalid public key")?;
    let ek = HybridEncapsKey::from_bytes(&pk_array);

    let result = ek.encaps().map_err(|e| format!("Encapsulation failed: {}", e))?;

    Ok(EncapsResponse {
        ciphertext: result.ciphertext.as_bytes().to_vec(),
        shared_secret: result.shared_secret.as_bytes().to_vec(),
    })
}

#[tauri::command]
pub fn hybrid_decaps(
    state: State<Mutex<WalletState>>,
    ciphertext: Vec<u8>,
) -> Result<Vec<u8>, String> {
    if ciphertext.len() != 1120 {
        return Err("Invalid ciphertext length".to_string());
    }

    let wallet = state.lock().map_err(|e| e.to_string())?;
    let kp = wallet.hybrid_keypair.as_ref().ok_or("Wallet not initialized")?;

    let ct_array: [u8; 1120] = ciphertext.try_into().map_err(|_| "Invalid ciphertext")?;
    let ct = HybridCiphertext::from_bytes(&ct_array);

    let shared_secret = kp.dk.decaps(&ct).map_err(|e| format!("Decapsulation failed: {}", e))?;

    Ok(shared_secret.as_bytes().to_vec())
}

// Register commands in main()
fn main() {
    tauri::Builder::default()
        .manage(Mutex::new(WalletState::default()))
        .invoke_handler(tauri::generate_handler![
            generate_wallet_keys,
            sign_message,
            verify_signature,
            hybrid_encaps,
            hybrid_decaps,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

## Step 4: Svelte Frontend

```typescript
// lib/quantum.ts
import { invoke } from '@tauri-apps/api/tauri';

interface KeyGenResponse {
  mlkem_public_key: number[];
  mldsa_public_key: number[];
  hybrid_public_key: number[];
}

interface EncapsResponse {
  ciphertext: number[];
  shared_secret: number[];
}

interface SignResponse {
  signature: number[];
}

export async function generateWalletKeys(): Promise<KeyGenResponse> {
  return await invoke('generate_wallet_keys');
}

export async function signMessage(message: Uint8Array): Promise<Uint8Array> {
  const response = await invoke<SignResponse>('sign_message', {
    message: Array.from(message),
  });
  return new Uint8Array(response.signature);
}

export async function verifySignature(
  publicKey: Uint8Array,
  message: Uint8Array,
  signature: Uint8Array
): Promise<boolean> {
  return await invoke('verify_signature', {
    publicKey: Array.from(publicKey),
    message: Array.from(message),
    signature: Array.from(signature),
  });
}

export async function hybridEncaps(publicKey: Uint8Array): Promise<{
  ciphertext: Uint8Array;
  sharedSecret: Uint8Array;
}> {
  const response = await invoke<EncapsResponse>('hybrid_encaps', {
    publicKey: Array.from(publicKey),
  });
  return {
    ciphertext: new Uint8Array(response.ciphertext),
    sharedSecret: new Uint8Array(response.shared_secret),
  };
}

export async function hybridDecaps(ciphertext: Uint8Array): Promise<Uint8Array> {
  const result = await invoke<number[]>('hybrid_decaps', {
    ciphertext: Array.from(ciphertext),
  });
  return new Uint8Array(result);
}
```

## Step 5: Example Svelte Component

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import { generateWalletKeys, signMessage, verifySignature } from '$lib/quantum';

  let walletInitialized = false;
  let publicKeys = {
    mlkem: '',
    mldsa: '',
    hybrid: '',
  };
  let message = '';
  let signature = '';
  let verificationResult = '';

  async function initWallet() {
    try {
      const keys = await generateWalletKeys();
      publicKeys.mlkem = bytesToHex(new Uint8Array(keys.mlkem_public_key));
      publicKeys.mldsa = bytesToHex(new Uint8Array(keys.mldsa_public_key));
      publicKeys.hybrid = bytesToHex(new Uint8Array(keys.hybrid_public_key));
      walletInitialized = true;
    } catch (e) {
      console.error('Failed to initialize wallet:', e);
    }
  }

  async function sign() {
    try {
      const msgBytes = new TextEncoder().encode(message);
      const sig = await signMessage(msgBytes);
      signature = bytesToHex(sig);
    } catch (e) {
      console.error('Signing failed:', e);
    }
  }

  function bytesToHex(bytes: Uint8Array): string {
    return Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  }
</script>

<main>
  {#if !walletInitialized}
    <button on:click={initWallet}>Initialize Quantum Wallet</button>
  {:else}
    <h2>Post-Quantum Wallet Initialized</h2>

    <div class="keys">
      <h3>Public Keys</h3>
      <p><strong>ML-KEM (1184 bytes):</strong> {publicKeys.mlkem.slice(0, 64)}...</p>
      <p><strong>ML-DSA (1952 bytes):</strong> {publicKeys.mldsa.slice(0, 64)}...</p>
      <p><strong>Hybrid (1216 bytes):</strong> {publicKeys.hybrid.slice(0, 64)}...</p>
    </div>

    <div class="sign">
      <h3>Sign Message</h3>
      <input bind:value={message} placeholder="Enter message to sign" />
      <button on:click={sign}>Sign</button>
      {#if signature}
        <p><strong>Signature (3309 bytes):</strong> {signature.slice(0, 64)}...</p>
      {/if}
    </div>
  {/if}
</main>
```

## Platform-Specific Notes

### macOS
No additional setup required. The Security framework is automatically linked.

### Windows
The `bcrypt.dll` is automatically linked. Works on Windows Vista and later.

### Linux
The `getrandom` syscall is used. Works on kernel 3.17+ (2014 and later).

### iOS/Android
For mobile builds, use the respective pre-built libraries and configure your Tauri mobile setup accordingly.

## Testing

```bash
# Run Rust tests
cd quantum-vault-sys
cargo test

# Run Zig tests
cd ..
zig build test
```

## Security Checklist

- [ ] Store private keys securely (e.g., system keychain)
- [ ] Clear sensitive data from memory after use
- [ ] Use hybrid mode for maximum security
- [ ] Validate all input lengths before processing
- [ ] Handle errors appropriately (don't expose internal errors to users)
