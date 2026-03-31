// Quantum Vault - Post-Quantum Cryptography for Cloudflare Workers
// Zig WASM FFI glue for ML-KEM-768, ML-DSA-65, and Hybrid ML-KEM+X25519
//
// Usage:
//   import wasm from "./quantum_vault.wasm";
//   import { QuantumVault } from "./quantum-vault.js";
//   const qv = new QuantumVault(wasm);

// Size constants (must match quantum_vault_ffi.zig)
const MLKEM768_EK_SIZE = 1184;
const MLKEM768_DK_SIZE = 2400;
const MLKEM768_CT_SIZE = 1088;
const MLKEM768_SS_SIZE = 32;

const MLDSA65_PK_SIZE = 1952;
const MLDSA65_SK_SIZE = 4032;
const MLDSA65_SIG_SIZE = 3309;

const HYBRID_EK_SIZE = 1216;
const HYBRID_DK_SIZE = 2432;
const HYBRID_CT_SIZE = 1120;
const HYBRID_SS_SIZE = 32;

// Error code descriptions
const QV_ERRORS = {
  0: "success",
  [-1]: "invalid_parameter",
  [-2]: "rng_failure",
  [-3]: "memory_error",
  [-10]: "mlkem_invalid_ek",
  [-11]: "mlkem_invalid_dk",
  [-12]: "mlkem_invalid_ct",
  [-13]: "mlkem_encaps_failed",
  [-14]: "mlkem_decaps_failed",
  [-15]: "mlkem_keygen_failed",
  [-20]: "mldsa_invalid_pk",
  [-21]: "mldsa_invalid_sk",
  [-22]: "mldsa_invalid_sig",
  [-23]: "mldsa_signing_failed",
  [-24]: "mldsa_verification_failed",
  [-25]: "mldsa_keygen_failed",
  [-30]: "hybrid_keygen_failed",
  [-31]: "hybrid_encaps_failed",
  [-32]: "hybrid_decaps_failed",
  [-33]: "hybrid_invalid_pk",
};

function checkError(code, op) {
  if (code !== 0) {
    const name = QV_ERRORS[code] || `unknown_error_${code}`;
    throw new Error(`QuantumVault.${op}: ${name} (code ${code})`);
  }
}

export class QuantumVault {
  #instance;
  #memory;
  #alloc;
  #exports;

  /**
   * @param {WebAssembly.Module} wasmModule - Static import of the .wasm file
   */
  constructor(wasmModule) {
    // Cloudflare Workers: static WASM import gives us a Module, instantiate synchronously
    const instance = new WebAssembly.Instance(wasmModule, {
      env: {
        // Provide crypto-secure RNG to the Zig WASM module
        seedRandom: (ptr, len) => {
          const buf = new Uint8Array(this.#memory.buffer, ptr, len);
          crypto.getRandomValues(buf);
        },
      },
    });

    this.#instance = instance;
    this.#exports = instance.exports;
    this.#memory = instance.exports.memory;

    // Simple bump allocator using WASM linear memory
    // The Zig code uses stack allocation, but we need heap space for passing data
    this.#alloc = this.#stackAlloc.bind(this);
  }

  // Allocate from the end of WASM memory (simple bump pointer)
  // Safe because we only use it transiently within a single API call
  #stackBase = null;

  #stackAlloc(size) {
    if (!this.#stackBase) {
      // Start allocating after the first 64KB (Zig's static data)
      this.#stackBase = this.#memory.buffer.byteLength > 65536 ? 65536 : 4096;
    }
    const ptr = this.#stackBase;
    this.#stackBase += size;
    // Align to 8 bytes
    this.#stackBase = (this.#stackBase + 7) & ~7;
    return ptr;
  }

  #resetStack() {
    this.#stackBase = null;
  }

  #writeBytes(ptr, data) {
    new Uint8Array(this.#memory.buffer, ptr, data.length).set(data);
  }

  #readBytes(ptr, len) {
    return new Uint8Array(this.#memory.buffer, ptr, len).slice();
  }

  /** Get library version string */
  version() {
    const ptr = this.#exports.qv_version();
    const mem = new Uint8Array(this.#memory.buffer);
    let end = ptr;
    while (mem[end] !== 0) end++;
    return new TextDecoder().decode(mem.slice(ptr, end));
  }

  // ─── ML-KEM-768 ──────────────────────────────────────────────────────

  /** Generate ML-KEM-768 keypair → { ek: Uint8Array, dk: Uint8Array } */
  mlKemKeygen() {
    this.#resetStack();
    const kpPtr = this.#alloc(MLKEM768_EK_SIZE + MLKEM768_DK_SIZE);
    const rc = this.#exports.qv_mlkem768_keygen(kpPtr);
    checkError(rc, "mlKemKeygen");
    return {
      ek: this.#readBytes(kpPtr, MLKEM768_EK_SIZE),
      dk: this.#readBytes(kpPtr + MLKEM768_EK_SIZE, MLKEM768_DK_SIZE),
    };
  }

  /** Encapsulate with public key → { sharedSecret: Uint8Array, ciphertext: Uint8Array } */
  mlKemEncaps(ek) {
    this.#resetStack();
    const ekPtr = this.#alloc(MLKEM768_EK_SIZE);
    this.#writeBytes(ekPtr, ek);

    const resultPtr = this.#alloc(MLKEM768_SS_SIZE + MLKEM768_CT_SIZE);
    const rc = this.#exports.qv_mlkem768_encaps(ekPtr, resultPtr);
    checkError(rc, "mlKemEncaps");
    return {
      sharedSecret: this.#readBytes(resultPtr, MLKEM768_SS_SIZE),
      ciphertext: this.#readBytes(resultPtr + MLKEM768_SS_SIZE, MLKEM768_CT_SIZE),
    };
  }

  /** Decapsulate with private key → Uint8Array (32-byte shared secret) */
  mlKemDecaps(dk, ciphertext) {
    this.#resetStack();
    const dkPtr = this.#alloc(MLKEM768_DK_SIZE);
    this.#writeBytes(dkPtr, dk);

    const ctPtr = this.#alloc(MLKEM768_CT_SIZE);
    this.#writeBytes(ctPtr, ciphertext);

    const ssPtr = this.#alloc(MLKEM768_SS_SIZE);
    const rc = this.#exports.qv_mlkem768_decaps(dkPtr, ctPtr, ssPtr);
    checkError(rc, "mlKemDecaps");
    return this.#readBytes(ssPtr, MLKEM768_SS_SIZE);
  }

  // ─── ML-DSA-65 ───────────────────────────────────────────────────────

  /** Generate ML-DSA-65 keypair → { pk: Uint8Array, sk: Uint8Array } */
  mlDsaKeygen(seed = null) {
    this.#resetStack();
    const kpPtr = this.#alloc(MLDSA65_PK_SIZE + MLDSA65_SK_SIZE);
    let seedPtr = 0; // null pointer
    if (seed) {
      seedPtr = this.#alloc(32);
      this.#writeBytes(seedPtr, seed);
    }
    const rc = this.#exports.qv_mldsa65_keygen(kpPtr, seedPtr);
    checkError(rc, "mlDsaKeygen");
    return {
      pk: this.#readBytes(kpPtr, MLDSA65_PK_SIZE),
      sk: this.#readBytes(kpPtr + MLDSA65_PK_SIZE, MLDSA65_SK_SIZE),
    };
  }

  /** Sign message → Uint8Array (3309-byte signature) */
  mlDsaSign(sk, message, { randomized = true } = {}) {
    this.#resetStack();
    const skPtr = this.#alloc(MLDSA65_SK_SIZE);
    this.#writeBytes(skPtr, sk);

    const msgBytes = typeof message === "string" ? new TextEncoder().encode(message) : message;
    const msgPtr = this.#alloc(msgBytes.length);
    this.#writeBytes(msgPtr, msgBytes);

    const sigPtr = this.#alloc(MLDSA65_SIG_SIZE);
    const rc = this.#exports.qv_mldsa65_sign(skPtr, msgPtr, msgBytes.length, sigPtr, randomized ? 1 : 0);
    checkError(rc, "mlDsaSign");
    return this.#readBytes(sigPtr, MLDSA65_SIG_SIZE);
  }

  /** Verify signature → boolean */
  mlDsaVerify(pk, message, signature) {
    this.#resetStack();
    const pkPtr = this.#alloc(MLDSA65_PK_SIZE);
    this.#writeBytes(pkPtr, pk);

    const msgBytes = typeof message === "string" ? new TextEncoder().encode(message) : message;
    const msgPtr = this.#alloc(msgBytes.length);
    this.#writeBytes(msgPtr, msgBytes);

    const sigPtr = this.#alloc(MLDSA65_SIG_SIZE);
    this.#writeBytes(sigPtr, signature);

    const rc = this.#exports.qv_mldsa65_verify(pkPtr, msgPtr, msgBytes.length, sigPtr);
    return rc === 0;
  }

  // ─── Hybrid ML-KEM+X25519 ────────────────────────────────────────────

  /** Generate hybrid keypair → { ek: Uint8Array, dk: Uint8Array } */
  hybridKeygen() {
    this.#resetStack();
    const kpPtr = this.#alloc(HYBRID_EK_SIZE + HYBRID_DK_SIZE);
    const rc = this.#exports.qv_hybrid_keygen(kpPtr);
    checkError(rc, "hybridKeygen");
    return {
      ek: this.#readBytes(kpPtr, HYBRID_EK_SIZE),
      dk: this.#readBytes(kpPtr + HYBRID_EK_SIZE, HYBRID_DK_SIZE),
    };
  }

  /** Hybrid encapsulate → { sharedSecret: Uint8Array, ciphertext: Uint8Array } */
  hybridEncaps(ek) {
    this.#resetStack();
    const ekPtr = this.#alloc(HYBRID_EK_SIZE);
    this.#writeBytes(ekPtr, ek);

    const resultPtr = this.#alloc(HYBRID_SS_SIZE + HYBRID_CT_SIZE);
    const rc = this.#exports.qv_hybrid_encaps(ekPtr, resultPtr);
    checkError(rc, "hybridEncaps");
    return {
      sharedSecret: this.#readBytes(resultPtr, HYBRID_SS_SIZE),
      ciphertext: this.#readBytes(resultPtr + HYBRID_SS_SIZE, HYBRID_CT_SIZE),
    };
  }

  /** Hybrid decapsulate → Uint8Array (32-byte shared secret) */
  hybridDecaps(dk, ciphertext) {
    this.#resetStack();
    const dkPtr = this.#alloc(HYBRID_DK_SIZE);
    this.#writeBytes(dkPtr, dk);

    const ctPtr = this.#alloc(HYBRID_CT_SIZE);
    this.#writeBytes(ctPtr, ciphertext);

    const ssPtr = this.#alloc(HYBRID_SS_SIZE);
    const rc = this.#exports.qv_hybrid_decaps(dkPtr, ctPtr, ssPtr);
    checkError(rc, "hybridDecaps");
    return this.#readBytes(ssPtr, HYBRID_SS_SIZE);
  }

  // ─── Utilities ────────────────────────────────────────────────────────

  /** Constant-time byte comparison */
  constantTimeEqual(a, b) {
    if (a.length !== b.length) return false;
    this.#resetStack();
    const aPtr = this.#alloc(a.length);
    this.#writeBytes(aPtr, a);
    const bPtr = this.#alloc(b.length);
    this.#writeBytes(bPtr, b);
    return this.#exports.qv_constant_time_eq(aPtr, bPtr, a.length) === 1;
  }

  /** Securely zero a buffer in WASM memory */
  secureZero(ptr, len) {
    this.#exports.qv_secure_zero(ptr, len);
  }
}
