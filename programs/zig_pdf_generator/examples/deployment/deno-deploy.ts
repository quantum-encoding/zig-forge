/**
 * Deno Deploy - PDF Generation via Zig WASM
 *
 * Ultra-lightweight edge PDF generation using Deno Deploy.
 * Zero cold-start, globally distributed, automatic HTTPS.
 *
 * Setup:
 * 1. Build the WASM module: `zig build wasm`
 * 2. Upload zigpdf.wasm to your project or host on CDN
 * 3. Deploy with: deployctl deploy --project=your-project deno-deploy.ts
 *
 * Local testing:
 *   deno run --allow-read --allow-net deno-deploy.ts
 */

// Import WASM module (embed or fetch)
// For Deno Deploy, the WASM file should be in the same directory or hosted on a CDN
const WASM_URL = new URL("./zigpdf.wasm", import.meta.url);

// =============================================================================
// WASM Module
// =============================================================================

interface WasmExports {
  memory: WebAssembly.Memory;
  wasm_alloc: (size: number) => number;
  wasm_free: (ptr: number, size: number) => void;
  wasm_memory_size: () => number;
  zigpdf_version: () => number;
  zigpdf_get_error: () => number;
  zigpdf_generate_invoice: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_dividend_voucher: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_share_certificate: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_contract: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_board_resolution: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_stock_transfer: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_director_consent: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_director_appointment: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_director_resignation: (inputPtr: number, lenPtr: number) => number;
  zigpdf_generate_written_resolution: (inputPtr: number, lenPtr: number) => number;
}

let wasmExports: WasmExports | null = null;

async function initWasm(): Promise<WasmExports> {
  if (wasmExports) return wasmExports;

  const wasmBuffer = await Deno.readFile(WASM_URL);
  const wasmModule = await WebAssembly.compile(wasmBuffer);

  // WASI imports for Deno
  const instance = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: {
      fd_write: () => 0,
      fd_close: () => 0,
      fd_seek: () => 0,
      fd_read: () => 0,
      proc_exit: (code: number) => { throw new Error(`Exit: ${code}`); },
      environ_sizes_get: (countPtr: number, sizePtr: number) => {
        const view = new DataView((instance.exports as WasmExports).memory.buffer);
        view.setUint32(countPtr, 0, true);
        view.setUint32(sizePtr, 0, true);
        return 0;
      },
      environ_get: () => 0,
      args_sizes_get: (argcPtr: number, argvBufSizePtr: number) => {
        const view = new DataView((instance.exports as WasmExports).memory.buffer);
        view.setUint32(argcPtr, 0, true);
        view.setUint32(argvBufSizePtr, 0, true);
        return 0;
      },
      args_get: () => 0,
      clock_time_get: (_clockId: number, _precision: bigint, timePtr: number) => {
        const view = new DataView((instance.exports as WasmExports).memory.buffer);
        view.setBigUint64(timePtr, BigInt(Date.now()) * 1000000n, true);
        return 0;
      },
      random_get: (bufPtr: number, bufLen: number) => {
        const buffer = new Uint8Array((instance.exports as WasmExports).memory.buffer, bufPtr, bufLen);
        crypto.getRandomValues(buffer);
        return 0;
      },
    },
  });

  wasmExports = instance.exports as WasmExports;
  return wasmExports;
}

function generatePdf(
  exports: WasmExports,
  functionName: keyof WasmExports,
  data: Record<string, unknown>
): Uint8Array {
  const generateFn = exports[functionName] as (
    inputPtr: number,
    lenPtr: number
  ) => number;

  if (typeof generateFn !== "function") {
    throw new Error(`Unknown PDF function: ${String(functionName)}`);
  }

  const encoder = new TextEncoder();
  const jsonStr = JSON.stringify(data);
  const jsonBytes = encoder.encode(jsonStr);

  // Allocate input buffer
  const inputPtr = exports.wasm_alloc(jsonBytes.length + 1);
  if (inputPtr === 0) throw new Error("Failed to allocate input buffer");

  const inputView = new Uint8Array(
    exports.memory.buffer,
    inputPtr,
    jsonBytes.length + 1
  );
  inputView.set(jsonBytes);
  inputView[jsonBytes.length] = 0;

  // Allocate length pointer
  const lenPtr = exports.wasm_alloc(4);
  if (lenPtr === 0) {
    exports.wasm_free(inputPtr, jsonBytes.length + 1);
    throw new Error("Failed to allocate length buffer");
  }

  try {
    const pdfPtr = generateFn(inputPtr, lenPtr);
    exports.wasm_free(inputPtr, jsonBytes.length + 1);

    if (pdfPtr === 0) {
      exports.wasm_free(lenPtr, 4);
      const errorPtr = exports.zigpdf_get_error();
      const errorView = new Uint8Array(exports.memory.buffer, errorPtr, 256);
      const errorEnd = errorView.indexOf(0);
      const errorMsg = new TextDecoder().decode(errorView.subarray(0, errorEnd));
      throw new Error(`PDF generation failed: ${errorMsg}`);
    }

    const pdfLen = new DataView(exports.memory.buffer).getUint32(lenPtr, true);
    exports.wasm_free(lenPtr, 4);

    const pdfBytes = new Uint8Array(exports.memory.buffer, pdfPtr, pdfLen).slice();
    exports.wasm_free(pdfPtr, pdfLen);

    return pdfBytes;
  } catch (e) {
    try { exports.wasm_free(inputPtr, jsonBytes.length + 1); } catch { /* ignore */ }
    try { exports.wasm_free(lenPtr, 4); } catch { /* ignore */ }
    throw e;
  }
}

// =============================================================================
// HTTP Handler
// =============================================================================

const FUNCTION_MAP: Record<string, keyof WasmExports> = {
  invoice: "zigpdf_generate_invoice",
  dividend_voucher: "zigpdf_generate_dividend_voucher",
  share_certificate: "zigpdf_generate_share_certificate",
  contract: "zigpdf_generate_contract",
  board_resolution: "zigpdf_generate_board_resolution",
  stock_transfer: "zigpdf_generate_stock_transfer",
  director_consent: "zigpdf_generate_director_consent",
  director_appointment: "zigpdf_generate_director_appointment",
  director_resignation: "zigpdf_generate_director_resignation",
  written_resolution: "zigpdf_generate_written_resolution",
};

async function handleRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);

  // CORS preflight
  if (request.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
      },
    });
  }

  const corsHeaders = { "Access-Control-Allow-Origin": "*" };

  // Health check
  if (url.pathname === "/health" || url.pathname === "/") {
    try {
      const exports = await initWasm();
      const versionPtr = exports.zigpdf_version();
      const versionView = new Uint8Array(exports.memory.buffer, versionPtr, 20);
      const versionEnd = versionView.indexOf(0);
      const version = new TextDecoder().decode(versionView.subarray(0, versionEnd));

      return Response.json(
        {
          status: "ok",
          version: version,
          memory_pages: exports.wasm_memory_size(),
          platform: "Deno Deploy",
          types: Object.keys(FUNCTION_MAP),
        },
        { headers: corsHeaders }
      );
    } catch (e) {
      return Response.json(
        { status: "error", error: String(e) },
        { status: 500, headers: corsHeaders }
      );
    }
  }

  // Generate PDF: POST /generate/:type
  if (request.method === "POST" && url.pathname.startsWith("/generate/")) {
    const type = url.pathname.split("/")[2];
    const functionName = FUNCTION_MAP[type];

    if (!functionName) {
      return Response.json(
        { error: `Unknown PDF type: ${type}`, available: Object.keys(FUNCTION_MAP) },
        { status: 400, headers: corsHeaders }
      );
    }

    try {
      const data = await request.json();
      const exports = await initWasm();
      const pdfBytes = generatePdf(exports, functionName, data);

      return new Response(pdfBytes, {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/pdf",
          "Content-Disposition": `attachment; filename="${type}.pdf"`,
          "Content-Length": pdfBytes.length.toString(),
        },
      });
    } catch (e) {
      console.error(`PDF generation error (${type}):`, e);
      return Response.json(
        { error: String(e) },
        { status: 500, headers: corsHeaders }
      );
    }
  }

  // Legacy routes for specific types
  const legacyRoutes: Record<string, string> = {
    "/invoice": "invoice",
    "/dividend-voucher": "dividend_voucher",
    "/share-certificate": "share_certificate",
  };

  const legacyType = legacyRoutes[url.pathname];
  if (request.method === "POST" && legacyType) {
    const functionName = FUNCTION_MAP[legacyType];
    try {
      const data = await request.json();
      const exports = await initWasm();
      const pdfBytes = generatePdf(exports, functionName, data);

      return new Response(pdfBytes, {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/pdf",
          "Content-Disposition": `attachment; filename="${legacyType}.pdf"`,
        },
      });
    } catch (e) {
      return Response.json({ error: String(e) }, { status: 500, headers: corsHeaders });
    }
  }

  return Response.json({ error: "Not Found" }, { status: 404, headers: corsHeaders });
}

// =============================================================================
// Server Entry Point
// =============================================================================

Deno.serve({ port: 8000 }, handleRequest);

/*
Usage Examples:

# Health check
curl https://your-project.deno.dev/health

# Generate invoice
curl -X POST https://your-project.deno.dev/generate/invoice \
  -H "Content-Type: application/json" \
  -d '{"invoice_number":"INV-001","company_name":"Acme Corp",...}' \
  -o invoice.pdf

# Generate Irish dividend voucher
curl -X POST https://your-project.deno.dev/generate/dividend_voucher \
  -H "Content-Type: application/json" \
  -d '{"jurisdiction":"Ireland","voucher":{"number":"DIV-001"},...}' \
  -o dividend.pdf

Available PDF types:
- invoice
- dividend_voucher
- share_certificate
- contract
- board_resolution
- stock_transfer
- director_consent
- director_appointment
- director_resignation
- written_resolution
*/
