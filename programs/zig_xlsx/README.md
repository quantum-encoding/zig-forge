# zig-xlsx

General-purpose XLSX to JSON converter. Pure Zig, no external dependencies.

## Usage

```bash
zig-xlsx <file.xlsx> [options]
```

## Options

| Flag | Description |
|------|-------------|
| `--list` | List sheet names only |
| `--pretty` | Pretty-print JSON output |
| `--headers` | Use first row as object keys (outputs array of objects) |
| `-s <name>` | Select a specific sheet by name |
| `-o <path>` | Write output to file instead of stdout |

## Output Formats

**Default** — array of arrays (each row is an array of cell values):

```bash
zig-xlsx data.xlsx
# {"sheets":[{"name":"Sheet1","rows":[["Name","Age","Joined"],[],["Alice","30","2026-08-25"]]}]}
```

Every cell is a JSON string, or `null` for an empty cell. Rows and cells keep
their place in the sheet: `rows[i]` is spreadsheet row `i+1` and cell `j` is
column `j+1`, so a blank row Excel leaves out of the file is an empty array and
a skipped cell is `null`. Numbers are written as stored (formulas give their
cached result), except numbers in a date or time style, which are ISO 8601
text: `2026-08-25`, `2026-08-25T17:26:00`, `17:26:00`, or `26:30:00` for an
elapsed-time format (`[h]:mm:ss`). The 1904 date system is honoured. Rich-text
runs are joined as written, CR LF reads as LF, and `_x000D_`-style escapes are
decoded.

**Headers mode** — array of objects (first row becomes keys):

```bash
zig-xlsx data.xlsx --headers
# {"sheets":[{"name":"Sheet1","rows":[{},{"Name":"Alice","Age":"30","Joined":"2026-08-25"}]}]}
```

**List sheets**:

```bash
zig-xlsx data.xlsx --list
# {"sheets":["Sheet1","Revenue","Summary"]}
```

## How It Works

- Manual ZIP parsing (EOCD scan + central directory + local file headers)
- DEFLATE decompression via `std.compress.flate`
- Hand-written streaming XML parser (no DOM, no dependencies)
- Handles shared strings (rich text, phonetic runs skipped), inline strings,
  numeric cells, booleans, errors, sparse rows and sparse columns
- Reads `xl/styles.xml` (cellXfs, custom and built-in number formats) to tell
  dates from plain numbers
- Supports both absolute and relative paths in workbook relationships

## Browser / edge module

`zig build wasm-web` writes `zig-out/bin/zig_xlsx_web.wasm`: wasm32-freestanding,
no imports. `wasm_alloc(n)` reserves the input, `xlsx_to_json(ptr, len, outLenPtr)`
returns the JSON above (or 0, with the reason from `xlsx_get_error(outLenPtr)`),
and the host frees the output with `xlsx_free(ptr, len)` and its own input with
`wasm_free(ptr, len)`. One instance serves any number of calls.

## Build

```bash
cd programs/zig_xlsx
zig build            # binary at zig-out/bin/zig-xlsx
zig build test       # unit tests
zig build wasm-web   # zig-out/bin/zig_xlsx_web.wasm
zig build wasm-test  # the wasm module under Node, one instance for every call
```
