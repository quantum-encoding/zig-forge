/**
 * ZigPDF WASM Loader
 *
 * Handles loading and initializing the ZigPDF WebAssembly module.
 * Designed for Next.js with support for both client and edge runtimes.
 */

import type { ZigPdfModule, OrderEmailEnvelope } from './types';

// ============================================================================
// WASM Memory Management
// ============================================================================

// WASM memory configuration
const WASM_PAGE_SIZE = 65536; // 64KB per page
const INITIAL_PAGES = 256;    // 16MB initial
const MAX_PAGES = 16384;      // 1GB max

// Singleton instance
let wasmModule: ZigPdfModule | null = null;
let wasmMemory: WebAssembly.Memory | null = null;
let loadPromise: Promise<ZigPdfModule> | null = null;

// ============================================================================
// Low-level WASM Interface
// ============================================================================

interface WasmExports {
  memory: WebAssembly.Memory;
  zigpdf_generate_presentation: (jsonPtr: number, jsonLen: number, outLenPtr: number) => number;
  zigpdf_generate_invoice: (jsonPtr: number, jsonLen: number, outLenPtr: number) => number;
  zigpdf_generate_invoice_encrypted: (jsonPtr: number, jsonLen: number, seedPtr: number, outLenPtr: number) => number;
  zigpdf_generate_letter_quote: (jsonPtr: number, jsonLen: number, outLenPtr: number) => number;
  zigpdf_generate_letter: (jsonPtr: number, jsonLen: number, outLenPtr: number) => number;
  zigpdf_generate_letter_encrypted: (jsonPtr: number, jsonLen: number, seedPtr: number, outLenPtr: number) => number;
  zigpdf_generate_order_email: (jsonPtr: number, jsonLen: number, outLenPtr: number) => number;
  zigpdf_free: (ptr: number, len: number) => void;
  zigpdf_get_error: () => number;
  zigpdf_version: () => number;
  wasm_alloc: (size: number) => number;
  wasm_free: (ptr: number, size: number) => void;
}

/**
 * Allocate 32 bytes of WASM memory and fill them with cryptographically-random
 * bytes from the host (crypto.getRandomValues). The WASM module has no
 * in-module CSPRNG, so encryption requires the host to supply the seed; an
 * all-zero seed is refused by the engine. Returns the pointer (free with
 * wasm_free(ptr, 32)).
 */
function writeRandomSeed(
  memory: WebAssembly.Memory,
  exports: WasmExports
): number {
  const ptr = exports.wasm_alloc(32);
  if (ptr === 0) {
    throw new Error('Failed to allocate WASM memory for encryption seed');
  }
  const seed = new Uint8Array(32);
  crypto.getRandomValues(seed);
  new Uint8Array(memory.buffer).set(seed, ptr);
  return ptr;
}

/**
 * Read a null-terminated string from WASM memory
 */
function readCString(memory: WebAssembly.Memory, ptr: number): string {
  const bytes = new Uint8Array(memory.buffer);
  let end = ptr;
  while (bytes[end] !== 0 && end < bytes.length) end++;
  const slice = bytes.slice(ptr, end);
  return new TextDecoder().decode(slice);
}

/**
 * Write a string to WASM memory, returns pointer and length
 */
function writeString(
  memory: WebAssembly.Memory,
  exports: WasmExports,
  str: string
): { ptr: number; len: number } {
  const encoded = new TextEncoder().encode(str);
  const ptr = exports.wasm_alloc(encoded.length);
  if (ptr === 0) {
    throw new Error('Failed to allocate WASM memory for string');
  }
  const bytes = new Uint8Array(memory.buffer);
  bytes.set(encoded, ptr);
  return { ptr, len: encoded.length };
}

/**
 * Read bytes from WASM memory
 */
function readBytes(memory: WebAssembly.Memory, ptr: number, len: number): Uint8Array {
  const bytes = new Uint8Array(memory.buffer);
  return bytes.slice(ptr, ptr + len);
}

// ============================================================================
// Module Wrapper
// ============================================================================

/**
 * Create the high-level ZigPdfModule interface from raw WASM exports
 */
function createModule(exports: WasmExports): ZigPdfModule {
  const memory = exports.memory;

  return {
    generatePresentation(jsonString: string): Uint8Array {
      // Allocate space for output length (4 bytes for u32)
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) {
        throw new Error('Failed to allocate memory for output length');
      }

      // Write JSON string to WASM memory
      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);

      try {
        // Call the WASM function
        const resultPtr = exports.zigpdf_generate_presentation(jsonPtr, jsonLen, outLenPtr);

        if (resultPtr === 0) {
          // Check for error
          const errorPtr = exports.zigpdf_get_error();
          if (errorPtr !== 0) {
            const errorMsg = readCString(memory, errorPtr);
            throw new Error(`PDF generation failed: ${errorMsg}`);
          }
          throw new Error('PDF generation failed: unknown error');
        }

        // Read output length
        const outLenBytes = new Uint32Array(memory.buffer, outLenPtr, 1);
        const outLen = outLenBytes[0];

        // Copy result bytes (important: copy before freeing!)
        const result = readBytes(memory, resultPtr, outLen).slice();

        // Free the result memory
        exports.zigpdf_free(resultPtr, outLen);

        return result;
      } finally {
        // Clean up input memory
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    generateInvoice(jsonString: string): Uint8Array {
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) {
        throw new Error('Failed to allocate memory for output length');
      }

      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);

      try {
        const resultPtr = exports.zigpdf_generate_invoice(jsonPtr, jsonLen, outLenPtr);

        if (resultPtr === 0) {
          const errorPtr = exports.zigpdf_get_error();
          if (errorPtr !== 0) {
            const errorMsg = readCString(memory, errorPtr);
            throw new Error(`Invoice generation failed: ${errorMsg}`);
          }
          throw new Error('Invoice generation failed: unknown error');
        }

        const outLenBytes = new Uint32Array(memory.buffer, outLenPtr, 1);
        const outLen = outLenBytes[0];
        const result = readBytes(memory, resultPtr, outLen).slice();
        exports.zigpdf_free(resultPtr, outLen);

        return result;
      } finally {
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    // AES-256 password-encrypted invoice. The JSON must carry `password` (and
    // optionally `owner_password`); the 32-byte CSPRNG seed is sourced from the
    // host here (crypto.getRandomValues) since WASM has no in-module entropy.
    generateInvoiceEncrypted(jsonString: string): Uint8Array {
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) {
        throw new Error('Failed to allocate memory for output length');
      }

      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);
      const seedPtr = writeRandomSeed(memory, exports);

      try {
        const resultPtr = exports.zigpdf_generate_invoice_encrypted(jsonPtr, jsonLen, seedPtr, outLenPtr);

        if (resultPtr === 0) {
          const errorPtr = exports.zigpdf_get_error();
          if (errorPtr !== 0) {
            throw new Error(`Encrypted invoice generation failed: ${readCString(memory, errorPtr)}`);
          }
          throw new Error('Encrypted invoice generation failed: unknown error');
        }

        const outLen = new Uint32Array(memory.buffer, outLenPtr, 1)[0];
        const result = readBytes(memory, resultPtr, outLen).slice();
        exports.zigpdf_free(resultPtr, outLen);
        return result;
      } finally {
        // Zero the seed before freeing — don't leave key material in the heap.
        new Uint8Array(memory.buffer).fill(0, seedPtr, seedPtr + 32);
        exports.wasm_free(seedPtr, 32);
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    // A receipt uses the exact same WASM export and wire format as an invoice.
    // Pass JSON with `document_type: "receipt"` (defaults show_tax to false) for
    // a non-VAT-registered business. This alias exists for call-site clarity;
    // it closes over `exports`/`memory` so it survives destructuring.
    generateReceipt(jsonString: string): Uint8Array {
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) {
        throw new Error('Failed to allocate memory for output length');
      }

      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);

      try {
        const resultPtr = exports.zigpdf_generate_invoice(jsonPtr, jsonLen, outLenPtr);

        if (resultPtr === 0) {
          const errorPtr = exports.zigpdf_get_error();
          if (errorPtr !== 0) {
            const errorMsg = readCString(memory, errorPtr);
            throw new Error(`Receipt generation failed: ${errorMsg}`);
          }
          throw new Error('Receipt generation failed: unknown error');
        }

        const outLenBytes = new Uint32Array(memory.buffer, outLenPtr, 1);
        const outLen = outLenBytes[0];
        const result = readBytes(memory, resultPtr, outLen).slice();
        exports.zigpdf_free(resultPtr, outLen);

        return result;
      } finally {
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    generateLetterQuote(jsonString: string): Uint8Array {
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) {
        throw new Error('Failed to allocate memory for output length');
      }

      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);

      try {
        const resultPtr = exports.zigpdf_generate_letter_quote(jsonPtr, jsonLen, outLenPtr);

        if (resultPtr === 0) {
          const errorPtr = exports.zigpdf_get_error();
          if (errorPtr !== 0) {
            const errorMsg = readCString(memory, errorPtr);
            throw new Error(`Letter quote generation failed: ${errorMsg}`);
          }
          throw new Error('Letter quote generation failed: unknown error');
        }

        const outLenBytes = new Uint32Array(memory.buffer, outLenPtr, 1);
        const outLen = outLenBytes[0];
        const result = readBytes(memory, resultPtr, outLen).slice();
        exports.zigpdf_free(resultPtr, outLen);

        return result;
      } finally {
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    // Letter: markdown body flowed across pages + letterhead + optional
    // full-page background image. Returns PDF bytes (same wire format as the
    // other generators). See docs/ORDER_EMAIL.md sibling docs/schema for fields.
    generateLetter(jsonString: string): Uint8Array {
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) {
        throw new Error('Failed to allocate memory for output length');
      }

      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);

      try {
        const resultPtr = exports.zigpdf_generate_letter(jsonPtr, jsonLen, outLenPtr);

        if (resultPtr === 0) {
          const errorPtr = exports.zigpdf_get_error();
          if (errorPtr !== 0) {
            const errorMsg = readCString(memory, errorPtr);
            throw new Error(`Letter generation failed: ${errorMsg}`);
          }
          throw new Error('Letter generation failed: unknown error');
        }

        const outLenBytes = new Uint32Array(memory.buffer, outLenPtr, 1);
        const outLen = outLenBytes[0];
        const result = readBytes(memory, resultPtr, outLen).slice();
        exports.zigpdf_free(resultPtr, outLen);

        return result;
      } finally {
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    // AES-256 password-encrypted letter (see generateInvoiceEncrypted). JSON
    // carries `password`/`owner_password`; the CSPRNG seed is host-supplied.
    generateLetterEncrypted(jsonString: string): Uint8Array {
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) {
        throw new Error('Failed to allocate memory for output length');
      }

      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);
      const seedPtr = writeRandomSeed(memory, exports);

      try {
        const resultPtr = exports.zigpdf_generate_letter_encrypted(jsonPtr, jsonLen, seedPtr, outLenPtr);

        if (resultPtr === 0) {
          const errorPtr = exports.zigpdf_get_error();
          if (errorPtr !== 0) {
            throw new Error(`Encrypted letter generation failed: ${readCString(memory, errorPtr)}`);
          }
          throw new Error('Encrypted letter generation failed: unknown error');
        }

        const outLen = new Uint32Array(memory.buffer, outLenPtr, 1)[0];
        const result = readBytes(memory, resultPtr, outLen).slice();
        exports.zigpdf_free(resultPtr, outLen);
        return result;
      } finally {
        new Uint8Array(memory.buffer).fill(0, seedPtr, seedPtr + 32);
        exports.wasm_free(seedPtr, 32);
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    // App-aware order-confirmation email. Unlike the PDF generators this
    // returns a JSON *envelope* (text), not a binary document. The caller
    // inspects `action`: "send" -> mail {from_name,from_email,to,subject,html};
    // "skip" -> do nothing (unknown/untagged app — never default to Lutuno).
    // Input is the normalized Stripe checkout.session.completed event; see
    // docs/ORDER_EMAIL.md for the field contract.
    generateOrderEmail(jsonString: string): OrderEmailEnvelope {
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) {
        throw new Error('Failed to allocate memory for output length');
      }

      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);

      try {
        const resultPtr = exports.zigpdf_generate_order_email(jsonPtr, jsonLen, outLenPtr);

        if (resultPtr === 0) {
          const errorPtr = exports.zigpdf_get_error();
          if (errorPtr !== 0) {
            const errorMsg = readCString(memory, errorPtr);
            throw new Error(`Order email generation failed: ${errorMsg}`);
          }
          throw new Error('Order email generation failed: unknown error');
        }

        const outLenBytes = new Uint32Array(memory.buffer, outLenPtr, 1);
        const outLen = outLenBytes[0];
        const bytes = readBytes(memory, resultPtr, outLen).slice();
        exports.zigpdf_free(resultPtr, outLen);

        return JSON.parse(new TextDecoder().decode(bytes)) as OrderEmailEnvelope;
      } finally {
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    getVersion(): string {
      const ptr = exports.zigpdf_version();
      if (ptr === 0) return 'unknown';
      return readCString(memory, ptr);
    },

    getLastError(): string | null {
      const ptr = exports.zigpdf_get_error();
      if (ptr === 0) return null;
      return readCString(memory, ptr);
    }
  };
}

// ============================================================================
// Loading Functions
// ============================================================================

/**
 * Load the WASM module from a URL
 */
async function loadFromUrl(wasmUrl: string): Promise<ZigPdfModule> {
  // Create shared memory
  wasmMemory = new WebAssembly.Memory({
    initial: INITIAL_PAGES,
    maximum: MAX_PAGES,
    shared: false
  });

  // Fetch and instantiate
  const response = await fetch(wasmUrl);
  if (!response.ok) {
    throw new Error(`Failed to fetch WASM: ${response.status} ${response.statusText}`);
  }

  const wasmBytes = await response.arrayBuffer();

  const imports = {
    env: {
      memory: wasmMemory
    },
    wasi_snapshot_preview1: {
      // Minimal WASI stubs for Zig's stdlib
      fd_write: () => 0,
      fd_read: () => 0,
      fd_close: () => 0,
      fd_seek: () => 0,
      proc_exit: () => {},
      environ_get: () => 0,
      environ_sizes_get: () => 0,
      clock_time_get: () => 0
    }
  };

  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const exports = instance.exports as unknown as WasmExports;

  return createModule(exports);
}

/**
 * Load from ArrayBuffer (for bundled WASM)
 */
async function loadFromBuffer(wasmBytes: ArrayBuffer): Promise<ZigPdfModule> {
  wasmMemory = new WebAssembly.Memory({
    initial: INITIAL_PAGES,
    maximum: MAX_PAGES,
    shared: false
  });

  const imports = {
    env: {
      memory: wasmMemory
    },
    wasi_snapshot_preview1: {
      fd_write: () => 0,
      fd_read: () => 0,
      fd_close: () => 0,
      fd_seek: () => 0,
      proc_exit: () => {},
      environ_get: () => 0,
      environ_sizes_get: () => 0,
      clock_time_get: () => 0
    }
  };

  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const exports = instance.exports as unknown as WasmExports;

  return createModule(exports);
}

// ============================================================================
// Public API
// ============================================================================

/**
 * Configuration options for loading
 */
export interface LoadOptions {
  /**
   * URL to the WASM file (default: '/zigpdf.wasm')
   */
  wasmUrl?: string;

  /**
   * Pre-loaded WASM bytes (alternative to URL)
   */
  wasmBytes?: ArrayBuffer;

  /**
   * Force reload even if already loaded
   */
  forceReload?: boolean;
}

/**
 * Load the ZigPDF WASM module
 *
 * @example
 * ```ts
 * const zigPdf = await loadZigPdf();
 * const pdfBytes = zigPdf.generatePresentation(jsonTemplate);
 * ```
 */
export async function loadZigPdf(options: LoadOptions = {}): Promise<ZigPdfModule> {
  const { wasmUrl = '/zigpdf.wasm', wasmBytes, forceReload = false } = options;

  // Return cached module if available
  if (wasmModule && !forceReload) {
    return wasmModule;
  }

  // Return existing load promise if in progress
  if (loadPromise && !forceReload) {
    return loadPromise;
  }

  // Start loading
  loadPromise = (async () => {
    try {
      if (wasmBytes) {
        wasmModule = await loadFromBuffer(wasmBytes);
      } else {
        wasmModule = await loadFromUrl(wasmUrl);
      }
      return wasmModule;
    } catch (error) {
      loadPromise = null;
      throw error;
    }
  })();

  return loadPromise;
}

/**
 * Check if the module is loaded
 */
export function isLoaded(): boolean {
  return wasmModule !== null;
}

/**
 * Get the loaded module (throws if not loaded)
 */
export function getModule(): ZigPdfModule {
  if (!wasmModule) {
    throw new Error('ZigPDF module not loaded. Call loadZigPdf() first.');
  }
  return wasmModule;
}

/**
 * Unload the module and free resources
 */
export function unload(): void {
  wasmModule = null;
  wasmMemory = null;
  loadPromise = null;
}

// ============================================================================
// Server-side Loading (for API routes / Edge)
// ============================================================================

/**
 * Load WASM for server-side use (API routes, Edge functions)
 * Reads the WASM file from the filesystem or fetches from URL
 */
export async function loadZigPdfServer(wasmPath?: string): Promise<ZigPdfModule> {
  // In Edge runtime, use fetch
  if (typeof globalThis.fetch === 'function' && typeof process === 'undefined') {
    return loadZigPdf({ wasmUrl: wasmPath || '/zigpdf.wasm' });
  }

  // In Node.js, read from filesystem
  if (typeof process !== 'undefined' && process.versions?.node) {
    const fs = await import('fs/promises');
    const path = await import('path');

    const resolvedPath = wasmPath || path.join(process.cwd(), 'public', 'zigpdf.wasm');
    const wasmBytes = await fs.readFile(resolvedPath);

    return loadZigPdf({ wasmBytes: wasmBytes.buffer });
  }

  throw new Error('Unsupported runtime for server-side WASM loading');
}
