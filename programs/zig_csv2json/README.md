# zig-csv2json

Structured-text → JSON CLI formatter for CSV, TSV, key-value, and line-based input.

> **One-way only.** This is a JSON **writer**. It cannot read JSON. If you need to parse JSON, use Zig's `std.json` or (Rust side) `serde_json` — see `CLAUDE.md` at the repo root for the in-tree library standardization rule.

Originally named `zig_json`, which led at least one audit to assume a bidirectional JSON parser existed in-tree when it did not. Renamed for honesty in 2025 along with grammar fixes — see "Audit-driven changes" below.

## Usage

```bash
zig-csv2json [file] [options]
cat data.txt | zig-csv2json [options]
```

## Options

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Force format: `csv`, `tsv`, `kv`, `lines` |
| `-p, --pretty` | Pretty-print JSON output (2-space indent) |
| `-n, --numbers` | Detect numeric values per RFC 8259 §6 grammar and emit them as bare JSON numbers; otherwise quote everything |
| `--no-headers` | CSV/TSV: treat first row as data, not headers |
| `-o, --output <path>` | Write JSON to file (default: stdout) |

Exit codes: `0` on success, `1` on parse/IO error, `2` on bad arguments.

## Auto-detection

The format is auto-detected by examining the first ~20 lines:

1. **CSV** — consistent comma count across lines (≥80% match)
2. **TSV** — consistent tab count across lines
3. **KV** — ≥50% of lines match `key: value` or `key = value`
4. **Lines** — fallback: each line becomes a string

The detected format is printed to stderr: `[auto-detected: csv]`.

## Examples

**Plain lines → JSON array:**

```bash
$ printf "Alice\nBob\nCharlie\n" | zig-csv2json --pretty
[
  "Alice",
  "Bob",
  "Charlie"
]
```

**CSV with header row:**

```bash
$ printf "Name,Age,City\nAlice,30,London\nBob,25,Paris\n" | zig-csv2json -f csv --numbers --pretty
[
  { "Name": "Alice", "Age": 30, "City": "London" },
  { "Name": "Bob",   "Age": 25, "City": "Paris" }
]
```

**Key-value config → JSON object:**

```bash
$ printf "name: Alice\nage: 30\ncity: London\n" | zig-csv2json --pretty --numbers
{
  "name": "Alice",
  "age": 30,
  "city": "London"
}
```

**Note on numbers:** `--numbers` only treats values as numeric if they match the RFC 8259 grammar. Values like `007`, `1.`, `.5`, `NaN`, and `Infinity` are NOT numeric — they pass through as JSON strings:

```bash
$ printf "id,code\n1,007\n2,42\n" | zig-csv2json -f csv --numbers --pretty
[
  { "id": 1, "code": "007" },   # 007 kept as string (leading zero invalid in JSON)
  { "id": 2, "code": 42 }
]
```

This is intentional and matches every conforming JSON consumer. The pre-audit version emitted `007` as a bare number, producing invalid JSON.

**Crypto amounts / large integers:** the writer preserves the bytes you give it. `1.8e19` and `18000000000000000000` both pass through verbatim. JSON itself has no precision limit; whether the downstream consumer parses these as f64 (losing precision) or as a bignum is the consumer's problem. If you control both ends, prefer quoting wallet amounts as strings (`"amount": "18000000000000000000"`).

## Build & test

```bash
zig build           # produces zig-out/bin/zig-csv2json
zig build run -- [args]
zig build test      # runs 48 unit tests (parser + writer)
```

## Limitations (post-audit, documented honestly)

- **Embedded newlines inside quoted CSV fields are not supported.** RFC 4180 §2.6 permits them but this parser splits on `\n` before row parsing, so a quoted field that spans multiple physical lines is reported as `UnclosedQuote`. Pre-process such CSV with a tool that joins multi-line cells (or use Python's `csv` module to convert first).
- **No JSON parsing.** This tool reads CSV/TSV/KV; it writes JSON. The directory name `zig_csv2json` reflects that explicitly.

## Audit-driven changes (2025)

The pre-audit version had four shipped bugs:

| ID | Bug | Fix |
|----|-----|-----|
| H-1 | `isNumeric("007")` returned true → CLI emitted invalid JSON | Tightened to RFC 8259 §6 grammar (no leading zeros) |
| M-1 | `JsonWriter.number(s)` accepted any bytes verbatim (e.g. `"NaN"`, empty) | Validates input via `isValidJsonNumber` before writing |
| M-3 | Unclosed CSV quote silently swallowed the rest of the line | Returns `CsvError.UnclosedQuote` with non-zero exit code |
| M-4/M-5 | Container stack silently truncated at 64 levels and never enforced object/array matching | Growable stack; `endObject`/`endArray` return `WrongContainer` on mismatch |
| M-6 | `fwrite` return values dropped — silent truncation on disk-full | Replaced libc I/O with `*std.Io.Writer`; all writes `!void` |
| M-7 | Library tied to libc via `*std.c.FILE` | Removed; usable in freestanding builds via any `Writer` sink |

## Project structure

```
zig_csv2json/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest
├── src/
│   ├── parser.zig         # CSV/TSV/KV detection + parsing (RFC 4180 + RFC 8259 isNumeric)
│   ├── json_writer.zig    # Streaming JSON output (RFC 8259-compliant)
│   └── main.zig           # CLI entry point
└── zig-out/
    └── bin/zig-csv2json   # Compiled CLI
```
