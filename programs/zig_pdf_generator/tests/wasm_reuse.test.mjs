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
import { crc32, deflateRawSync, deflateSync } from 'node:zlib';
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

/** A workbook (ZIP, deflated entries, as Excel writes them) whose first sheet
 *  holds `rows` rows of two inline-string cells, with a blank row after the
 *  first. */
function xlsx(rows) {
	let sheet = '<worksheet><sheetData>';
	sheet += '<row r="1"><c r="A1" t="inlineStr"><is><t>Item</t></is></c><c r="B1" t="inlineStr"><is><t>Note</t></is></c></row>';
	for (let r = 3; r < rows + 3; r++) {
		sheet += `<row r="${r}"><c r="A${r}" t="inlineStr"><is><t>item ${r}</t></is></c><c r="B${r}" t="inlineStr"><is><t>a note long enough to fill the row ${r}</t></is></c></row>`;
	}
	sheet += '</sheetData></worksheet>';
	const files = [
		['xl/workbook.xml', '<workbook xmlns:r="r"><sheets><sheet name="Items" sheetId="1" r:id="rId1"/></sheets></workbook>'],
		['xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'],
		['xl/worksheets/sheet1.xml', sheet],
	];
	const locals = [];
	const centrals = [];
	let offset = 0;
	for (const [name, text] of files) {
		const nameBuf = Buffer.from(name);
		const raw = Buffer.from(text);
		const crc = crc32(raw);
		const data = deflateRawSync(raw);
		const local = Buffer.alloc(30);
		local.writeUInt32LE(0x04034b50, 0);
		local.writeUInt16LE(20, 4);
		local.writeUInt16LE(8, 8);
		local.writeUInt32LE(crc, 14);
		local.writeUInt32LE(data.length, 18);
		local.writeUInt32LE(raw.length, 22);
		local.writeUInt16LE(nameBuf.length, 26);
		const central = Buffer.alloc(46);
		central.writeUInt32LE(0x02014b50, 0);
		central.writeUInt16LE(20, 4);
		central.writeUInt16LE(20, 6);
		central.writeUInt16LE(8, 10);
		central.writeUInt32LE(crc, 16);
		central.writeUInt32LE(data.length, 20);
		central.writeUInt32LE(raw.length, 24);
		central.writeUInt16LE(nameBuf.length, 28);
		central.writeUInt32LE(offset, 42);
		locals.push(local, nameBuf, data);
		centrals.push(central, nameBuf);
		offset += 30 + nameBuf.length + data.length;
	}
	const cd = Buffer.concat(centrals);
	const eocd = Buffer.alloc(22);
	eocd.writeUInt32LE(0x06054b50, 0);
	eocd.writeUInt16LE(files.length, 8);
	eocd.writeUInt16LE(files.length, 10);
	eocd.writeUInt32LE(cd.length, 12);
	eocd.writeUInt32LE(offset, 16);
	return { bytes: Buffer.concat([...locals, cd, eocd]), sheetXmlLength: Buffer.byteLength(sheet) };
}

/** zig_docx_xlsx_to_csv through the wasm C ABI (the 12-byte ZigDocxResult is
 *  returned through a pointer passed first); frees everything it allocated. */
function xlsxToCsv(ex, bytes, sheet) {
	const inPtr = ex.wasm_alloc(bytes.length);
	new Uint8Array(ex.memory.buffer).set(bytes, inPtr);
	const res = ex.wasm_alloc(12);
	ex.zig_docx_xlsx_to_csv(res, inPtr, bytes.length, sheet);
	const view = new DataView(ex.memory.buffer);
	const data = view.getUint32(res, true);
	const len = view.getUint32(res + 4, true);
	const err = view.getUint32(res + 8, true);
	let out = null;
	if (data && len) {
		out = dec.decode(new Uint8Array(ex.memory.buffer, data, len));
		ex.zig_docx_free(data, len);
	}
	if (err) ex.zig_docx_free_string(err);
	ex.wasm_free(res, 12);
	ex.wasm_free(inPtr, bytes.length);
	return out;
}

// The sheet inflates to about 28,500 bytes. zig_docx's ZIP reader inflates
// into a list that jumps straight to a 37 KiB capacity (one 64 KiB big page of
// std.heap.wasm_allocator) and is cut to its length on return, the in-place
// shrink that loses the page when the allocator is not guarded: 64 KiB per
// workbook. Excel deflates every part, so any sheet, shared-strings or styles
// part of roughly 25 to 32 KiB did this.
const { bytes: book, sheetXmlLength } = xlsx(180);

for (const [name, ex] of [
	['zigpdf.wasm (WASI)', wasiEx],
	['zigpdf_web.wasm (freestanding)', webEx],
]) {
	test(`${name}: zig_docx_xlsx_to_csv on one instance gives the same CSV every time and keeps memory flat`, () => {
		const first = xlsxToCsv(ex, book, 0);
		assert.ok(first, 'zig_docx_xlsx_to_csv failed');
		assert.ok(sheetXmlLength > 24779 && sheetXmlLength <= 32760, `sheet XML is ${sheetXmlLength} bytes`);
		assert.ok(first.startsWith('Item,Note\n,\nitem 3,a note long enough to fill the row 3\n'), first.slice(0, 80));
		assert.ok(first.endsWith('item 182,a note long enough to fill the row 182\n'), first.slice(-80));
		for (let i = 0; i < 5; i++) assert.equal(xlsxToCsv(ex, book, 0), first);
		const before = ex.memory.buffer.byteLength;
		for (let i = 0; i < 60; i++) assert.equal(xlsxToCsv(ex, book, 0), first);
		const after = ex.memory.buffer.byteLength;
		assert.equal(after, before, `memory grew ${after - before} bytes over 60 workbooks`);
		// The host freed each input once; had the module freed it too, the slot
		// would be on the free list twice and handed out twice.
		const a = ex.wasm_alloc(book.length);
		const b = ex.wasm_alloc(book.length);
		assert.notEqual(a, b);
		ex.wasm_free(a, book.length);
		ex.wasm_free(b, book.length);
	});
}
