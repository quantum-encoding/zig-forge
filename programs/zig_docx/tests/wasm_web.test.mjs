// The freestanding module (zig-out/bin/zig_docx_web.wasm) under Node, the way
// a Cloudflare Worker uses it: instantiated with an empty import object, bytes
// in through wasm_alloc, bytes out through a pointer and an out-length.
//
//   zig build wasm-test                                   (builds the module first)
//   node tests/wasm_web.test.mjs [path/to/zig_docx_web.wasm]   (default zig-out/bin/)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const wasmPath = process.argv[2] ?? join(root, 'zig-out/bin/zig_docx_web.wasm');
const module = new WebAssembly.Module(readFileSync(wasmPath));
const { exports: ex } = new WebAssembly.Instance(module, {});

const enc = new TextEncoder();
const dec = new TextDecoder();

function cString(ptr) {
	const mem = new Uint8Array(ex.memory.buffer);
	let end = ptr;
	while (mem[end] !== 0) end++;
	return dec.decode(mem.subarray(ptr, end));
}

/** Copy `bytes` into module memory; returns [ptr, len]. */
function put(bytes) {
	if (bytes.length === 0) return [0, 0];
	const ptr = ex.wasm_alloc(bytes.length);
	assert.notEqual(ptr, 0, 'wasm_alloc failed');
	new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
	return [ptr, bytes.length];
}

/**
 * Call an export whose last argument is the out-length pointer. `inputs` are
 * byte arrays passed as (ptr, len) pairs. Every buffer is freed exactly once.
 */
function call(name, ...inputs) {
	const held = inputs.map(put);
	const outLenPtr = ex.wasm_alloc(4);
	try {
		const ptr = ex[name](...held.flat(), outLenPtr);
		if (ptr === 0) return { error: cString(ex.zigdocx_get_error()) };
		const len = new DataView(ex.memory.buffer).getUint32(outLenPtr, true);
		const bytes = new Uint8Array(ex.memory.buffer, ptr, len).slice();
		ex.zigdocx_free(ptr, len);
		return { bytes };
	} finally {
		for (const [p, n] of held) if (p) ex.wasm_free(p, n);
		ex.wasm_free(outLenPtr, 4);
	}
}

/** One file out of a ZIP: the central directory, then its local header. */
function unzipEntry(zip, name) {
	const dv = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
	let eocd = zip.length - 22;
	while (eocd >= 0 && dv.getUint32(eocd, true) !== 0x06054b50) eocd--;
	assert.ok(eocd >= 0, 'no end of central directory');
	const count = dv.getUint16(eocd + 10, true);
	let p = dv.getUint32(eocd + 16, true);
	for (let i = 0; i < count; i++) {
		assert.equal(dv.getUint32(p, true), 0x02014b50);
		const method = dv.getUint16(p + 10, true);
		const csize = dv.getUint32(p + 20, true);
		const nlen = dv.getUint16(p + 28, true);
		const xlen = dv.getUint16(p + 30, true);
		const clen = dv.getUint16(p + 32, true);
		const local = dv.getUint32(p + 42, true);
		const entry = dec.decode(zip.subarray(p + 46, p + 46 + nlen));
		if (entry === name) {
			const start = local + 30 + dv.getUint16(local + 26, true) + dv.getUint16(local + 28, true);
			const data = zip.subarray(start, start + csize);
			return dec.decode(method === 8 ? inflateRawSync(data) : data);
		}
		p += 46 + nlen + xlen + clen;
	}
	throw new Error(`${name} not in the archive`);
}

const fixture = JSON.parse(readFileSync(join(root, 'src/testdata/redline_sheet.json'), 'utf8'));

test('the module imports nothing and exports the generators', () => {
	assert.deepEqual(WebAssembly.Module.imports(module), []);
	for (const name of ['zigdocx_generate_fra', 'zigdocx_generate_redline', 'zigdocx_redline_compare', 'zigdocx_md_to_docx', 'zigdocx_docx_to_md', 'wasm_alloc', 'wasm_free', 'zigdocx_free', 'zigdocx_get_error', 'memory']) {
		assert.ok(name in ex, `missing export ${name}`);
	}
});

test('a redline sheet from JSON', () => {
	const { bytes, error } = call('zigdocx_generate_redline', enc.encode(JSON.stringify(fixture)));
	assert.equal(error, undefined);
	assert.equal(dec.decode(bytes.subarray(0, 2)), 'PK');
	const xml = unzipEntry(bytes, 'word/document.xml');
	assert.match(xml, /w:orient="landscape"/);
	assert.match(xml, /<w:tblHeader\/>/);
	assert.match(xml, /<w:strike\/><w:color w:val="A00000"\/><w:shd w:val="clear" w:color="auto" w:fill="FDDADA"\/><\/w:rPr><w:t xml:space="preserve">5<\/w:t>/);
	assert.match(xml, /<w:b\/><w:color w:val="006400"\/><w:shd w:val="clear" w:color="auto" w:fill="D7F5D7"\/><\/w:rPr><w:t xml:space="preserve">7<\/w:t>/);
	assert.equal((xml.match(/<w:gridSpan w:val="3"\/>/g) ?? []).length, 4);
	assert.match(unzipEntry(bytes, 'docProps/core.xml'), /<dc:title>Proofread: 12 Example Road/);
});

test('tracked changes carry the author and date', () => {
	// The default key for tracked mode: the fixture's own key shows the colours.
	const json = { ...fixture, key: undefined, mode: 'tracked', author: 'Proofreader', date: '2026-01-02T10:00:00Z' };
	const { bytes, error } = call('zigdocx_generate_redline', enc.encode(JSON.stringify(json)));
	assert.equal(error, undefined);
	const xml = unzipEntry(bytes, 'word/document.xml');
	assert.match(xml, /<w:del w:id="1" w:author="Proofreader" w:date="2026-01-02T10:00:00Z"><w:r><w:rPr><\/w:rPr><w:delText xml:space="preserve">/);
	assert.match(xml, /<w:ins w:id="2" w:author="Proofreader" w:date="2026-01-02T10:00:00Z">/);
	assert.doesNotMatch(xml, /<w:strike\/>/);
});

test('bad input is refused with a reason', () => {
	assert.equal(call('zigdocx_generate_redline', enc.encode('{"colors": {"added": "nope"}}')).error, 'Redline JSON: InvalidColor');
	assert.equal(call('zigdocx_generate_redline', enc.encode('{"date": "yesterday"}')).error, 'Redline JSON: InvalidDate');
	assert.equal(call('zigdocx_generate_redline', enc.encode('not json')).error, 'Redline JSON: InvalidJson');
	assert.equal(call('zigdocx_generate_redline', new Uint8Array([0x7b, 0xff, 0x7d])).error, 'Invalid UTF-8 input');
});

test('Markdown marks reach the .docx', () => {
	const md = '# Notes\n\nKeep ~~this~~ and ==that==, [warn]{color=red bg=#fee2e2} and {--old--}{++new++}.\n';
	const { bytes, error } = call('zigdocx_md_to_docx', enc.encode(md));
	assert.equal(error, undefined);
	const xml = unzipEntry(bytes, 'word/document.xml');
	assert.match(xml, /<w:strike\/><\/w:rPr><w:t xml:space="preserve">this</);
	assert.match(xml, /<w:highlight w:val="yellow"\/><\/w:rPr><w:t xml:space="preserve">that</);
	assert.match(xml, /<w:color w:val="B91C1C"\/><w:shd w:val="clear" w:color="auto" w:fill="FEE2E2"\/><\/w:rPr><w:t xml:space="preserve">warn</);
	assert.match(xml, /<w:color w:val="006400"\/>/);

	// And back: .docx → Markdown gives ~~ and == again.
	const back = call('zigdocx_docx_to_md', bytes);
	assert.equal(back.error, undefined);
	assert.match(dec.decode(back.bytes), /Keep ~~this~~ and ==that==/);
});

test('two documents compare into a redline sheet', () => {
	const a = call('zigdocx_md_to_docx', enc.encode('# Doors\n\nThe door closes onto its rebate.\n\nUnchanged line.\n')).bytes;
	const b = call('zigdocx_md_to_docx', enc.encode('# Doors\n\nThe door closes fully onto its rebate.\n\nUnchanged line.\n')).bytes;
	const { bytes, error } = call('zigdocx_redline_compare', a, b, enc.encode('{"title": "Changes"}'));
	assert.equal(error, undefined);
	const xml = unzipEntry(bytes, 'word/document.xml');
	assert.match(xml, />Doors</);
	assert.match(xml, />Paragraph 2</);
	assert.match(xml, /<w:t xml:space="preserve">fully <\/w:t>/);
	// Kept text either side of a pure insertion is one run in the Now column.
	assert.match(xml, /<w:t xml:space="preserve">The door closes onto its rebate.<\/w:t>/);
	assert.doesNotMatch(xml, /Unchanged line/);

	// No options: (0, 0) is allowed.
	const plain = call('zigdocx_redline_compare', a, b, new Uint8Array(0));
	assert.equal(plain.error, undefined);
});

test('repeated calls reuse memory instead of growing it', () => {
	const json = enc.encode(JSON.stringify(fixture));
	for (let i = 0; i < 5; i++) call('zigdocx_generate_redline', json);
	const settled = ex.memory.buffer.byteLength;
	for (let i = 0; i < 200; i++) assert.equal(call('zigdocx_generate_redline', json).error, undefined);
	assert.equal(ex.memory.buffer.byteLength, settled);
});
