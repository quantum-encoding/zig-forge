// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

/**
 * Browser / edge loader for zig_docx_web.wasm — the freestanding
 * (wasm32-freestanding, no WASI, no libc) Fire Risk Assessment generator.
 *
 * The module imports NOTHING from the host, so it instantiates with an
 * empty import object — no WASI shim, no polyfills. This mirrors the
 * zig_pdf_generator loader; if you already vendor that one the shape here
 * will look familiar.
 *
 * Build the wasm with:  zig build wasm-web   (output zig-out/bin/zig_docx_web.wasm)
 *
 * Typical Next.js usage (server route or edge function):
 *
 *   import { loadZigDocx } from './zigdocx-loader';
 *   import wasmUrl from './zig_docx_web.wasm';            // or fs.readFile on the server
 *
 *   const zigDocx = await loadZigDocx(await fetch(wasmUrl).then(r => r.arrayBuffer()));
 *   const bytes = zigDocx.generateFireRiskAssessment(JSON.stringify(fraData));
 *   // return as application/vnd.openxmlformats-officedocument.wordprocessingml.document
 */

import type { FraData, ZigDocxModule } from './types';

interface WasmExports {
  memory: WebAssembly.Memory;
  wasm_alloc: (size: number) => number;
  wasm_free: (ptr: number, size: number) => void;
  zigdocx_free: (ptr: number, size: number) => void;
  zigdocx_generate_fra: (jsonPtr: number, jsonLen: number, outLenPtr: number) => number;
  zigdocx_get_error: () => number;
  zigdocx_version: () => number;
}

function readCString(memory: WebAssembly.Memory, ptr: number): string {
  if (ptr === 0) return '';
  const bytes = new Uint8Array(memory.buffer);
  let end = ptr;
  while (bytes[end] !== 0 && end < bytes.length) end++;
  return new TextDecoder().decode(bytes.slice(ptr, end));
}

function writeString(
  memory: WebAssembly.Memory,
  exports: WasmExports,
  str: string,
): { ptr: number; len: number } {
  const encoded = new TextEncoder().encode(str);
  const ptr = exports.wasm_alloc(encoded.length);
  if (ptr === 0) throw new Error('zig_docx: failed to allocate WASM memory for input');
  new Uint8Array(memory.buffer).set(encoded, ptr);
  return { ptr, len: encoded.length };
}

function createModule(exports: WasmExports): ZigDocxModule {
  const memory = exports.memory;

  return {
    /**
     * Generate a Fire Risk Assessment .docx from a JSON string matching the
     * FRA schema (see FraData). Returns the DOCX as bytes — a complete Open
     * XML (zip) package ready to stream to the client for download.
     *
     * Photo evidence: pass section images as base64 data URLs
     * ("data:image/png;base64,…" — png/jpeg/gif) and they embed inline.
     * Filename-based images are skipped in the browser build (no filesystem);
     * everything else renders identically to native.
     */
    generateFireRiskAssessment(jsonString: string): Uint8Array {
      const outLenPtr = exports.wasm_alloc(4);
      if (outLenPtr === 0) throw new Error('zig_docx: failed to allocate output-length slot');

      const { ptr: jsonPtr, len: jsonLen } = writeString(memory, exports, jsonString);

      try {
        const resultPtr = exports.zigdocx_generate_fra(jsonPtr, jsonLen, outLenPtr);

        if (resultPtr === 0) {
          const msg = readCString(memory, exports.zigdocx_get_error());
          throw new Error(`FRA generation failed: ${msg || 'unknown error'}`);
        }

        const outLen = new Uint32Array(memory.buffer, outLenPtr, 1)[0];
        // .slice() copies out of linear memory before we free the source.
        const result = new Uint8Array(memory.buffer, resultPtr, outLen).slice();
        exports.zigdocx_free(resultPtr, outLen);
        return result;
      } finally {
        exports.wasm_free(jsonPtr, jsonLen);
        exports.wasm_free(outLenPtr, 4);
      }
    },

    getVersion(): string {
      return readCString(memory, exports.zigdocx_version());
    },
  };
}

/**
 * Instantiate the freestanding zig_docx web module from its wasm bytes.
 * Accepts an ArrayBuffer/Uint8Array (e.g. from fetch() or fs.readFile).
 */
export async function loadZigDocx(wasm: BufferSource): Promise<ZigDocxModule> {
  // Empty import object — the module is freestanding and needs no host imports.
  const { instance } = await WebAssembly.instantiate(wasm, {});
  return createModule(instance.exports as unknown as WasmExports);
}

/** Convenience: serialise an FraData object and generate the DOCX in one call. */
export function generateFra(zigDocx: ZigDocxModule, data: FraData): Uint8Array {
  return zigDocx.generateFireRiskAssessment(JSON.stringify(data));
}
