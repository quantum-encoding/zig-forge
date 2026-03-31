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
# [["Name","Age","City"],["Alice",30,"London"],["Bob",25,"Paris"]]
```

**Headers mode** — array of objects (first row becomes keys):

```bash
zig-xlsx data.xlsx --headers --pretty
# [
#   {"Name": "Alice", "Age": 30, "City": "London"},
#   {"Name": "Bob", "Age": 25, "City": "Paris"}
# ]
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
- Handles shared strings, inline strings, numeric cells, and sparse columns
- Supports both absolute and relative paths in workbook relationships

## Build

```bash
cd programs/zig_xlsx
zig build          # binary at zig-out/bin/zig-xlsx
zig build test     # run 10 unit tests
```
