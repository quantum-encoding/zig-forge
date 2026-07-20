// Minimal browser/Node loader for zigpdf_web.wasm (freestanding, no WASI shim).
//
// Build the module with:  zig build wasm-web   ->  zig-out/lib/zigpdf_web.wasm
// Then in a SvelteKit route / +server.js or client component:
//
//   import { loadZigPdf } from './zigpdf_web.js';
//   const pdf = await loadZigPdf('/zigpdf_web.wasm');       // fetch + instantiate once
//   const bytes = pdf.presentation(JSON.stringify(reportTemplate));  // Uint8Array
//   // -> new Blob([bytes], {type:'application/pdf'})  for download / preview
//
// The wasm imports nothing from the host, so instantiation needs no import
// object. Every generate call copies JSON in, returns a fresh Uint8Array PDF,
// and frees the wasm-side buffers.

const GENERATORS = {
  // The CRG solar proposal: pass a small CrgQuote JSON (the ~28 per-lead fields;
  // omitted fields fall back to the sample). Brand assets are embedded in the
  // wasm, so nothing else is needed. -> pdf.crgReport(JSON.stringify(quote))
  crgReport: 'zigpdf_generate_crg_solar_report',
  // baton-audit Website Health report: pass a SiteHealthReport JSON.
  healthReport: 'zigpdf_generate_health_report',
  presentation: 'zigpdf_generate_presentation', // raw canvas schema
  invoice: 'zigpdf_generate_invoice',
  proposal: 'zigpdf_generate_proposal',
  cleanQuote: 'zigpdf_generate_clean_quote',
  letter: 'zigpdf_generate_letter',
  orderEmail: 'zigpdf_generate_order_email',
};

function makeApi(exports) {
  const enc = new TextEncoder();

  function call(fnName, json) {
    const fn = exports[fnName];
    if (!fn) throw new Error(`export ${fnName} missing from wasm`);
    const bytes = enc.encode(json);
    const inPtr = exports.wasm_alloc(bytes.length);
    if (inPtr === 0) throw new Error('wasm_alloc failed (out of memory)');
    new Uint8Array(exports.memory.buffer, inPtr, bytes.length).set(bytes);
    const lenPtr = exports.wasm_alloc(4);
    const outPtr = fn(inPtr, bytes.length, lenPtr);
    try {
      if (outPtr === 0) {
        const errPtr = exports.zigpdf_get_error();
        const mem = new Uint8Array(exports.memory.buffer);
        let msg = '';
        for (let i = errPtr; mem[i] !== 0; i++) msg += String.fromCharCode(mem[i]);
        throw new Error(msg || 'PDF generation failed');
      }
      // DataView is re-created each call: memory.buffer can be detached after grow.
      const outLen = new DataView(exports.memory.buffer).getUint32(lenPtr, true);
      // .slice() copies out of wasm memory before we free it.
      const pdf = new Uint8Array(exports.memory.buffer, outPtr, outLen).slice();
      exports.zigpdf_free(outPtr, outLen);
      return pdf;
    } finally {
      exports.wasm_free(inPtr, bytes.length);
      exports.wasm_free(lenPtr, 4);
    }
  }

  const api = { call, version: () => readCStr(exports, exports.zigpdf_version()) };
  for (const [name, fnName] of Object.entries(GENERATORS)) {
    api[name] = (json) => call(fnName, json);
  }
  return api;
}

function readCStr(exports, ptr) {
  const mem = new Uint8Array(exports.memory.buffer);
  let s = '';
  for (let i = ptr; mem[i] !== 0; i++) s += String.fromCharCode(mem[i]);
  return s;
}

// Accepts a URL (browser: fetched with streaming compile), a Response, an
// ArrayBuffer, or a Uint8Array of the wasm module.
export async function loadZigPdf(source) {
  let instance;
  const isUrlString =
    typeof source === 'string' && /^(https?:|data:|blob:|file:)/.test(source);

  if (isUrlString && typeof fetch === 'function' && WebAssembly.instantiateStreaming) {
    // Browser fast path: stream-compile straight from the network.
    ({ instance } = await WebAssembly.instantiateStreaming(fetch(source), {}));
  } else {
    let buf = source;
    if (typeof source === 'string') {
      // A bare path (e.g. Node, or a build without streaming): read the file.
      const { readFile } = await import('node:fs/promises');
      buf = await readFile(source);
    } else if (source instanceof Response) {
      buf = new Uint8Array(await source.arrayBuffer());
    }
    ({ instance } = await WebAssembly.instantiate(buf, {}));
  }
  return makeApi(instance.exports);
}

export default loadZigPdf;
