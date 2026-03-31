/**
 * ZigCharts — WASM-powered chart generation.
 * JSON in → SVG out. 147 KB, zero dependencies.
 *
 * Usage:
 *   const charts = await ZigCharts.load('/zigcharts.wasm');
 *   const svg = charts.render({ type: 'pie', data: { segments: [...] } });
 *   document.getElementById('chart').innerHTML = svg;
 */

class ZigCharts {
  constructor(instance) {
    this.wasm = instance.exports;
    this.memory = this.wasm.memory;
  }

  /** Load the WASM module from a URL or path. */
  static async load(wasmPath = '/zigcharts.wasm') {
    const response = await fetch(wasmPath);
    const bytes = await response.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {
      env: { memory: new WebAssembly.Memory({ initial: 128 }) },
    });
    return new ZigCharts(instance);
  }

  /**
   * Render a chart from a JSON spec. Returns SVG string.
   * @param {object|string} spec — Chart specification (object or JSON string)
   * @returns {string} SVG markup
   */
  render(spec) {
    const json = typeof spec === 'string' ? spec : JSON.stringify(spec);
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const jsonBytes = encoder.encode(json);

    // Reset allocator between renders
    this.wasm.zigcharts_reset();

    // Allocate + copy JSON into WASM memory
    const jsonPtr = this.wasm.wasm_alloc(jsonBytes.length);
    if (!jsonPtr) throw new Error('WASM alloc failed');

    const mem = new Uint8Array(this.memory.buffer);
    mem.set(jsonBytes, jsonPtr);

    // Render
    const svgLen = this.wasm.zigcharts_render(jsonPtr, jsonBytes.length);

    if (svgLen === 0) {
      // Get error
      const errPtr = this.wasm.zigcharts_get_error();
      const errLen = this.wasm.zigcharts_get_error_len();
      const errBytes = new Uint8Array(this.memory.buffer, errPtr, errLen);
      throw new Error('Chart render failed: ' + decoder.decode(errBytes));
    }

    // Read SVG output
    const svgPtr = this.wasm.zigcharts_get_output();
    const svgBytes = new Uint8Array(this.memory.buffer, svgPtr, svgLen);
    return decoder.decode(svgBytes);
  }

  /** Get the WASM module version. */
  version() {
    const ptr = this.wasm.zigcharts_version();
    const mem = new Uint8Array(this.memory.buffer);
    let len = 0;
    while (mem[ptr + len] !== 0 && len < 32) len++;
    return new TextDecoder().decode(mem.slice(ptr, ptr + len));
  }
}

// CommonJS + ESM + browser global
if (typeof module !== 'undefined') module.exports = ZigCharts;
if (typeof window !== 'undefined') window.ZigCharts = ZigCharts;
export default ZigCharts;
