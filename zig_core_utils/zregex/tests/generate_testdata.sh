#!/bin/bash
# Generate test data for regex benchmarks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

mkdir -p "$DATA_DIR"

echo "Generating test data..."

# 1. Simple text file with repeated patterns (1MB)
echo "  Creating simple_1mb.txt..."
{
    for i in $(seq 1 20000); do
        echo "Line $i: The quick brown fox jumps over the lazy dog."
        echo "Line $i: Hello world, this is a test line with numbers 12345."
        echo "Line $i: foo bar baz qux hello world testing regex patterns"
    done
} > "$DATA_DIR/simple_1mb.txt"

# 2. Log-like file with timestamps and varying content (1MB)
echo "  Creating log_1mb.txt..."
{
    for i in $(seq 1 15000); do
        ts="2024-01-$((i % 28 + 1))T$((i % 24)):$((i % 60)):$((i % 60))"
        level=$(echo "INFO DEBUG WARN ERROR" | tr ' ' '\n' | shuf -n1)
        echo "[$ts] [$level] Request from 192.168.$((i % 256)).$((i % 256)) - GET /api/v1/users/$i"
        echo "[$ts] [INFO] Processing request id=$i status=200 time=${i}ms"
    done
} > "$DATA_DIR/log_1mb.txt"

# 3. Source code-like file (1MB)
echo "  Creating code_1mb.txt..."
{
    for i in $(seq 1 10000); do
        echo "fn process_item_$i(data: []const u8) !void {"
        echo "    const result = try allocator.alloc(u8, data.len);"
        echo "    defer allocator.free(result);"
        echo "    std.mem.copy(u8, result, data);"
        echo "    return result;"
        echo "}"
        echo ""
    done
} > "$DATA_DIR/code_1mb.txt"

# 4. Dictionary words file
echo "  Creating words.txt..."
if [ -f /usr/share/dict/words ]; then
    cat /usr/share/dict/words > "$DATA_DIR/words.txt"
else
    # Generate synthetic word list
    {
        for i in $(seq 1 100000); do
            echo "word$i"
            echo "testing"
            echo "hello"
            echo "world"
            echo "function"
        done
    } > "$DATA_DIR/words.txt"
fi

# 5. ReDoS-prone pattern test file (tests catastrophic backtracking immunity)
echo "  Creating redos_test.txt..."
{
    # Lines that could cause exponential backtracking in naive regex engines
    echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    for i in $(seq 1 1000); do
        printf 'a%.0s' $(seq 1 50)
        echo ""
        printf 'a%.0s' $(seq 1 50)
        echo "b"
    done
} > "$DATA_DIR/redos_test.txt"

# 6. Large file for throughput testing (10MB)
echo "  Creating large_10mb.txt..."
{
    for j in $(seq 1 10); do
        cat "$DATA_DIR/simple_1mb.txt"
    done
} > "$DATA_DIR/large_10mb.txt"

echo ""
echo "Test data generated in $DATA_DIR:"
ls -lh "$DATA_DIR"
