# zig-json

Text-to-JSON structured formatter. Takes unstructured text (names, lists, CSV, config files) and outputs valid JSON.

## Usage

```bash
zig-json [file] [options]
cat data.txt | zig-json [options]
```

## Options

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Force format: `csv`, `tsv`, `kv`, `lines` |
| `-p, --pretty` | Pretty-print JSON output |
| `-n, --numbers` | Detect numeric values (output as JSON numbers) |
| `--no-headers` | CSV/TSV: treat first row as data, not headers |
| `-o, --output <path>` | Write JSON to file instead of stdout |

## Auto-Detection

The format is auto-detected by examining the first 20 lines:

1. **CSV** — consistent comma count across lines (>=80% match)
2. **TSV** — consistent tab count across lines
3. **KV** — >=50% of lines match `key: value` or `key = value`
4. **Lines** — fallback: each line becomes a string

The detected format is printed to stderr: `[auto-detected: csv]`

## Examples

**Plain lines** — list of names to JSON array:

```bash
echo -e "Alice\nBob\nCharlie" | zig-json --pretty
# [
#   "Alice",
#   "Bob",
#   "Charlie"
# ]
```

**CSV** — auto-detected, first row becomes object keys:

```bash
echo -e "Name,Age,City\nAlice,30,London\nBob,25,Paris" | zig-json --pretty --numbers
# [
#   {"Name": "Alice", "Age": 30, "City": "London"},
#   {"Name": "Bob", "Age": 25, "City": "Paris"}
# ]
```

**Key-value pairs** — config-style to JSON object:

```bash
echo -e "name: Alice\nage: 30\ncity: London" | zig-json --pretty --numbers
# {
#   "name": "Alice",
#   "age": 30,
#   "city": "London"
# }
```

**File input with output redirect**:

```bash
zig-json data.csv --pretty --numbers -o output.json
```

## Build

```bash
cd programs/zig_json
zig build          # binary at zig-out/bin/zig-json
zig build test     # run 11 unit tests
```
