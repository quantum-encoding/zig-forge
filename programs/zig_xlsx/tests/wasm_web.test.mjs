// The freestanding module (zig-out/bin/zig_xlsx_web.wasm) under Node, the way
// the browser uses it: ONE instance for every file, instantiated with an empty
// import object, bytes in through wasm_alloc, JSON out through a pointer and an
// out-length, and every buffer freed by the host afterwards.
//
//   zig build wasm-test                                       (builds the module first)
//   node tests/wasm_web.test.mjs [path/to/zig_xlsx_web.wasm]  (default zig-out/bin/)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { crc32, deflateRawSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const wasmPath = process.argv[2] ?? join(root, 'zig-out/bin/zig_xlsx_web.wasm');
const module = new WebAssembly.Module(readFileSync(wasmPath));
const { exports: ex } = new WebAssembly.Instance(module, {});

const enc = new TextEncoder();
const dec = new TextDecoder();

/** A zip of { name: text } entries, each deflated (method 8). */
function zip(files) {
	const locals = [];
	const centrals = [];
	let offset = 0;
	for (const [name, text] of Object.entries(files)) {
		const nameBytes = enc.encode(name);
		const data = enc.encode(text);
		const packed = deflateRawSync(data);
		const crc = crc32(data);
		const local = Buffer.alloc(30);
		local.writeUInt32LE(0x04034b50, 0);
		local.writeUInt16LE(20, 4);
		local.writeUInt16LE(8, 8);
		local.writeUInt32LE(crc, 14);
		local.writeUInt32LE(packed.length, 18);
		local.writeUInt32LE(data.length, 22);
		local.writeUInt16LE(nameBytes.length, 26);
		const central = Buffer.alloc(46);
		central.writeUInt32LE(0x02014b50, 0);
		central.writeUInt16LE(20, 4);
		central.writeUInt16LE(20, 6);
		central.writeUInt16LE(8, 10);
		central.writeUInt32LE(crc, 16);
		central.writeUInt32LE(packed.length, 20);
		central.writeUInt32LE(data.length, 24);
		central.writeUInt16LE(nameBytes.length, 28);
		central.writeUInt32LE(offset, 42);
		locals.push(local, nameBytes, packed);
		centrals.push(central, nameBytes);
		offset += 30 + nameBytes.length + packed.length;
	}
	const cd = Buffer.concat(centrals);
	const end = Buffer.alloc(22);
	end.writeUInt32LE(0x06054b50, 0);
	const count = Object.keys(files).length;
	end.writeUInt16LE(count, 8);
	end.writeUInt16LE(count, 10);
	end.writeUInt32LE(cd.length, 12);
	end.writeUInt32LE(offset, 16);
	return new Uint8Array(Buffer.concat([...locals, cd, end]));
}

/** A one-sheet workbook whose sheet XML is `sheetXml`. */
function xlsx(sheetXml, { sharedStrings, styles } = {}) {
	const files = {
		'[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
		'xl/workbook.xml':
			'<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>',
		'xl/_rels/workbook.xml.rels':
			'<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
		'xl/worksheets/sheet1.xml': sheetXml,
	};
	if (sharedStrings) files['xl/sharedStrings.xml'] = sharedStrings;
	if (styles) files['xl/styles.xml'] = styles;
	return zip(files);
}

/** A sheet of `n` rows, each with a number and an inline string. */
function rowsSheet(n) {
	let rows = '';
	for (let r = 1; r <= n; r++) rows += `<row r="${r}"><c r="A${r}"><v>${r * 1.5}</v></c><c r="B${r}" t="inlineStr"><is><t>row ${r}</t></is></c></row>`;
	return `<worksheet><sheetData>${rows}</sheetData></worksheet>`;
}

/** xlsx_to_json as the browser calls it; the host frees every buffer it holds. */
function toJson(bytes) {
	const inPtr = ex.wasm_alloc(bytes.length);
	assert.notEqual(inPtr, 0, 'wasm_alloc failed');
	new Uint8Array(ex.memory.buffer, inPtr, bytes.length).set(bytes);
	const outLenPtr = ex.wasm_alloc(4);
	try {
		const ptr = ex.xlsx_to_json(inPtr, bytes.length, outLenPtr);
		if (ptr === 0) {
			const errLenPtr = ex.wasm_alloc(4);
			const errPtr = ex.xlsx_get_error(errLenPtr);
			const n = new DataView(ex.memory.buffer).getUint32(errLenPtr, true);
			ex.wasm_free(errLenPtr, 4);
			return { error: dec.decode(new Uint8Array(ex.memory.buffer, errPtr, n)) };
		}
		const len = new DataView(ex.memory.buffer).getUint32(outLenPtr, true);
		const json = dec.decode(new Uint8Array(ex.memory.buffer, ptr, len));
		ex.xlsx_free(ptr, len);
		return { json: JSON.parse(json) };
	} finally {
		ex.wasm_free(inPtr, bytes.length);
		ex.wasm_free(outLenPtr, 4);
	}
}

test('the module imports nothing and exports the converter', () => {
	assert.deepEqual(WebAssembly.Module.imports(module), []);
	for (const name of ['xlsx_to_json', 'xlsx_free', 'xlsx_get_error', 'wasm_alloc', 'wasm_free', 'memory']) {
		assert.ok(name in ex, `missing export ${name}`);
	}
});

test('the input buffer stays the host\'s: freeing it after the call frees it once', () => {
	const bytes = xlsx(rowsSheet(20));
	assert.ok(toJson(bytes).json);
	// Freed twice, the input's slot would sit on the free list twice and the
	// next two allocations of its size would share an address.
	const a = ex.wasm_alloc(bytes.length);
	const b = ex.wasm_alloc(bytes.length);
	assert.notEqual(a, b);
	ex.wasm_free(a, bytes.length);
	ex.wasm_free(b, bytes.length);
});

test('one instance converts many workbooks without trapping or drifting', () => {
	const books = [5, 50, 400, 900, 1500, 3000].map((n) => [n, xlsx(rowsSheet(n))]);
	const first = new Map();
	for (let pass = 0; pass < 6; pass++) {
		for (const [n, bytes] of books) {
			const { json, error } = toJson(bytes);
			assert.equal(error, undefined);
			const rows = json.sheets[0].rows;
			assert.equal(rows.length, n);
			assert.deepEqual(rows[n - 1], [String(n * 1.5), `row ${n}`]);
			const text = JSON.stringify(json);
			if (pass === 0) first.set(n, text);
			else assert.equal(text, first.get(n));
		}
	}
});

test('repeated calls reuse memory instead of growing it', () => {
	const books = [400, 900, 1500, 3000].map((n) => xlsx(rowsSheet(n)));
	for (let i = 0; i < 3; i++) for (const b of books) toJson(b);
	const settled = ex.memory.buffer.byteLength;
	for (let i = 0; i < 40; i++) for (const b of books) assert.ok(toJson(b).json);
	assert.equal(ex.memory.buffer.byteLength, settled);
});

test('rows keep their sheet row number, dates read as ISO 8601', () => {
	const styles =
		'<styleSheet><numFmts><numFmt numFmtId="165" formatCode="dd\\ mmm\\ yyyy"/></numFmts>' +
		'<cellXfs><xf numFmtId="0"/><xf numFmtId="165"/><xf numFmtId="22"/></cellXfs></styleSheet>';
	const sheet =
		'<worksheet><sheetData>' +
		'<row r="2"><c r="A2" t="s"><v>0</v></c><c r="B2" s="1"><v>46259</v></c></row>' +
		'<row r="5"><c r="C5" s="2"><v>46259.7263888889</v></c><c r="D5"><v>46259</v></c></row>' +
		'</sheetData></worksheet>';
	const sst = '<sst><si><r><t>Loft Access:</t></r><r><t xml:space="preserve"> </t></r><r><t>Increase</t></r></si></sst>';
	const { json, error } = toJson(xlsx(sheet, { sharedStrings: sst, styles }));
	assert.equal(error, undefined);
	assert.deepEqual(json.sheets[0].rows, [
		[],
		['Loft Access: Increase', '2026-08-25'],
		[],
		[],
		[null, null, '2026-08-25T17:26:00', '46259'],
	]);
});

test('what is not an xlsx is refused with a reason', () => {
	assert.equal(toJson(enc.encode('<html><body>a page saved as .xls</body></html>')).error, 'not a valid xlsx (zip) file');
});
