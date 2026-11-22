// zigpdf.wasm (WASI) and zigpdf_web.wasm (freestanding) under Node, the way a
// page keeps them: ONE instance for every document, bytes in through
// wasm_alloc, output through a pointer and an out-length, every buffer freed by
// the host afterwards. Memory must stop growing once the working set is
// reached, and extraction must give the same answer every time.
//
//   zig build wasm-test                                         (builds both modules first)
//   node tests/wasm_reuse.test.mjs <zigpdf.wasm> <zigpdf_web.wasm>

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { crc32, deflateSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const wasiPath = process.argv[2] ?? join(root, 'zig-out/lib/zigpdf.wasm');
const webPath = process.argv[3] ?? join(root, 'zig-out/lib/zigpdf_web.wasm');

const enc = new TextEncoder();
const dec = new TextDecoder();

/** The WASI module with every WASI import a no-op returning 0, as the
 *  crg-direct-accounts browser loader instantiates it. */
function instantiateWasi(path) {
	const module = new WebAssembly.Module(readFileSync(path));
	const wasi = {};
	for (const imp of WebAssembly.Module.imports(module)) {
		if (imp.module === 'wasi_snapshot_preview1') wasi[imp.name] = () => 0;
	}
	return new WebAssembly.Instance(module, { wasi_snapshot_preview1: wasi }).exports;
}

const wasiEx = instantiateWasi(wasiPath);
const webEx = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(webPath)), {}).exports;

/** An 8-bit PNG: colour type 6 (RGBA, an ellipse on transparent) or 2 (RGB). */
function png(w, h, rgba) {
	const bpp = rgba ? 4 : 3;
	const raw = Buffer.alloc((w * bpp + 1) * h);
	for (let y = 0; y < h; y++) {
		for (let x = 0; x < w; x++) {
			const o = y * (w * bpp + 1) + 1 + x * bpp;
			const inside = ((x - w / 2) / (w / 2)) ** 2 + ((y - h / 2) / (h / 2)) ** 2 < 1;
			raw[o] = 20;
			raw[o + 1] = inside ? 60 : 200;
			raw[o + 2] = 140;
			if (rgba) raw[o + 3] = inside ? 255 : 0;
		}
	}
	const chunk = (type, data) => {
		const len = Buffer.alloc(4);
		len.writeUInt32BE(data.length);
		const body = Buffer.concat([Buffer.from(type), data]);
		const crc = Buffer.alloc(4);
		crc.writeUInt32BE(crc32(body));
		return Buffer.concat([len, body, crc]);
	};
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(w, 0);
	ihdr.writeUInt32BE(h, 4);
	ihdr[8] = 8;
	ihdr[9] = rgba ? 6 : 2;
	return Buffer.concat([
		Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
		chunk('IHDR', ihdr),
		chunk('IDAT', deflateSync(raw)),
		chunk('IEND', Buffer.alloc(0)),
	]);
}

function invoiceJson(number, logo) {
	return JSON.stringify({
		preset: 'invoice',
		invoice_number: number,
		invoice_date: '1 Jan 2026',
		company_name: 'Example Ltd',
		client_name: 'A Customer',
		currency_symbol: '£',
		...(logo ? { company_logo_base64: 'data:image/png;base64,' + logo.toString('base64') } : {}),
		items: [
			{ description: 'Survey', quantity: 1, unit_price: 120, total: 120 },
			{ description: 'Materials', quantity: 3, unit_price: 40, total: 120 },
		],
		subtotal: 240,
		tax_rate: 20,
		tax_amount: 48,
		total: 288,
	});
}

/** alloc → copy → call fn(ptr, len, *outLen) → copy the output out → free all
 *  three buffers. Returns the output bytes, or null when fn returned 0. */
function call(ex, fn, input) {
	const inPtr = ex.wasm_alloc(input.length);
	assert.ok(inPtr, 'wasm_alloc failed');
	new Uint8Array(ex.memory.buffer).set(input, inPtr);
	const lenPtr = ex.wasm_alloc(4);
	const outPtr = ex[fn](inPtr, input.length, lenPtr);
	const outLen = new DataView(ex.memory.buffer).getUint32(lenPtr, true);
	let out = null;
	if (outPtr && outLen) {
		out = new Uint8Array(ex.memory.buffer, outPtr, outLen).slice();
		ex.zigpdf_free(outPtr, outLen);
	}
	ex.wasm_free(inPtr, input.length);
	ex.wasm_free(lenPtr, 4);
	return out;
}

/** Memory after `warm` calls, then after `n` more. */
function growth(ex, fn, input, warm, n) {
	for (let i = 0; i < warm; i++) assert.ok(call(ex, fn, input), `${fn} failed`);
	const before = ex.memory.buffer.byteLength;
	for (let i = 0; i < n; i++) assert.ok(call(ex, fn, input), `${fn} failed`);
	return { before, after: ex.memory.buffer.byteLength };
}

// An alpha mask of 400x200 = 80,000 bytes, and RGB of 200x150 = 90,000 bytes:
// each is compressed into a buffer of half its size (one 64 KiB big page of
// std.heap.wasm_allocator) and shrinks to well under 32 KiB, the in-place
// shrink that loses the page when the allocator is not guarded.
const rgbaLogo = png(400, 200, true);
const rgbLogo = png(200, 150, false);

for (const [name, ex] of [
	['zigpdf.wasm (WASI)', wasiEx],
	['zigpdf_web.wasm (freestanding)', webEx],
]) {
	test(`${name}: invoices with an RGBA logo on one instance do not grow memory`, () => {
		const { before, after } = growth(ex, 'zigpdf_generate_invoice', enc.encode(invoiceJson('INV-1', rgbaLogo)), 5, 60);
		assert.equal(after, before, `memory grew ${after - before} bytes over 60 invoices`);
	});

	test(`${name}: invoices with an RGB logo on one instance do not grow memory`, () => {
		const { before, after } = growth(ex, 'zigpdf_generate_invoice', enc.encode(invoiceJson('INV-2', rgbLogo)), 5, 60);
		assert.equal(after, before, `memory grew ${after - before} bytes over 60 invoices`);
	});
}

test('zigpdf.wasm: extraction on one instance gives the same text every time and keeps memory flat', () => {
	const pdfs = [
		call(wasiEx, 'zigpdf_generate_invoice', enc.encode(invoiceJson('INV-7001', rgbaLogo))),
		call(wasiEx, 'zigpdf_generate_invoice', enc.encode(invoiceJson('INV-7002', null))),
	];
	for (const pdf of pdfs) assert.ok(pdf && dec.decode(pdf.subarray(0, 5)) === '%PDF-');

	const first = pdfs.map((pdf) => dec.decode(call(wasiEx, 'zigpdf_extract_mdx', pdf)));
	assert.match(first[0], /has_text_layer: true/);
	assert.match(first[0], /INV-7001/);
	assert.match(first[1], /INV-7002/);

	const before = wasiEx.memory.buffer.byteLength;
	for (let pass = 0; pass < 40; pass++) {
		pdfs.forEach((pdf, i) => assert.equal(dec.decode(call(wasiEx, 'zigpdf_extract_mdx', pdf)), first[i]));
	}
	assert.equal(wasiEx.memory.buffer.byteLength, before);
});

test('zigpdf.wasm: extraction leaves the host its input buffer (no double free)', () => {
	const pdf = call(wasiEx, 'zigpdf_generate_invoice', enc.encode(invoiceJson('INV-7003', null)));
	for (let i = 0; i < 5; i++) {
		assert.ok(call(wasiEx, 'zigpdf_extract_mdx', pdf));
		// The host has freed the input once. Had the module freed it too, the
		// slot would sit on the free list twice and be handed out twice.
		const a = wasiEx.wasm_alloc(pdf.length);
		const b = wasiEx.wasm_alloc(pdf.length);
		assert.notEqual(a, b);
		wasiEx.wasm_free(a, pdf.length);
		wasiEx.wasm_free(b, pdf.length);
	}
});
