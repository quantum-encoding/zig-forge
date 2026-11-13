// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

/**
 * Browser / edge loader for zig_docx_web.wasm — the freestanding
 * (wasm32-freestanding, no WASI, no libc) build: Fire Risk Assessments,
 * redline proofreading sheets, and Markdown ↔ DOCX.
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

import type { FraData, RedlineOptions, RedlineSheet, ZigDocxModule } from './types';

interface WasmExports {
  memory: WebAssembly.Memory;
  wasm_alloc: (size: number) => number;
  wasm_free: (ptr: number, size: number) => void;
  zigdocx_free: (ptr: number, size: number) => void;
  zigdocx_generate_fra: (jsonPtr: number, jsonLen: number, outLenPtr: number) => number;
  zigdocx_generate_redline: (jsonPtr: number, jsonLen: number, outLenPtr: number) => number;
  zigdocx_redline_compare: (
    beforePtr: number, beforeLen: number,
    afterPtr: number, afterLen: number,
    optsPtr: number, optsLen: number,
    outLenPtr: number,
  ) => number;
  zigdocx_md_to_docx: (mdPtr: number, mdLen: number, outLenPtr: number) => number;
  zigdocx_docx_to_md: (docxPtr: number, docxLen: number, outLenPtr: number) => number;
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

type Generator = 'zigdocx_generate_redline' | 'zigdocx_redline_compare' | 'zigdocx_md_to_docx' | 'zigdocx_docx_to_md';

/**
 * Call a generator: each input is copied into module memory and passed as
 * (ptr, len), the out-length slot goes last, and the output is copied out.
 * Every buffer is freed exactly once, on success or failure.
 */
function callGenerator(exports: WasmExports, name: Generator, inputs: Uint8Array[]): Uint8Array {
  const memory = exports.memory;
  const held: Array<[number, number]> = [];
  let outLenPtr = 0;
  let resultPtr = 0;
  let outLen = 0;
  try {
    for (const bytes of inputs) {
      if (bytes.length === 0) {
        held.push([0, 0]);
        continue;
      }
      const ptr = exports.wasm_alloc(bytes.length);
      if (ptr === 0) throw new Error('zig_docx: failed to allocate WASM memory for input');
      held.push([ptr, bytes.length]);
      new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    }
    outLenPtr = exports.wasm_alloc(4);
    if (outLenPtr === 0) throw new Error('zig_docx: failed to allocate output-length slot');
    const fn = exports[name] as (...args: number[]) => number;
    resultPtr = fn(...held.flat(), outLenPtr);
    if (resultPtr === 0) {
      throw new Error(`zig_docx: ${readCString(memory, exports.zigdocx_get_error()) || 'unknown error'}`);
    }
    outLen = new DataView(memory.buffer).getUint32(outLenPtr, true);
    return new Uint8Array(memory.buffer, resultPtr, outLen).slice();
  } finally {
    for (const [ptr, len] of held) if (ptr) exports.wasm_free(ptr, len);
    if (outLenPtr) exports.wasm_free(outLenPtr, 4);
    if (resultPtr) exports.zigdocx_free(resultPtr, outLen);
  }
}

function createModule(exports: WasmExports): ZigDocxModule {
  const memory = exports.memory;
  const utf8 = (s: string) => new TextEncoder().encode(s);

  return {
    generateRedline(sheet: RedlineSheet): Uint8Array {
      return callGenerator(exports, 'zigdocx_generate_redline', [utf8(JSON.stringify(sheet))]);
    },

    compareDocx(before: Uint8Array, after: Uint8Array, options?: RedlineOptions): Uint8Array {
      const opts = options ? utf8(JSON.stringify(options)) : new Uint8Array(0);
      return callGenerator(exports, 'zigdocx_redline_compare', [before, after, opts]);
    },

    markdownToDocx(markdown: string): Uint8Array {
      return callGenerator(exports, 'zigdocx_md_to_docx', [utf8(markdown)]);
    },

    docxToMarkdown(docx: Uint8Array): string {
      return new TextDecoder().decode(callGenerator(exports, 'zigdocx_docx_to_md', [docx]));
    },

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
