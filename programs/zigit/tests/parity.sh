#!/usr/bin/env bash
#
# Parity tests: every plumbing operation we ship must produce
# byte-identical results to the real `git` binary.
#
# What we cover:
#   1. SHA-1 of a battery of inputs (empty, ASCII, binary, large)
#      via `hash-object` (file path) and `hash-object --stdin`.
#   2. Cross-direction loose-object interop:
#        a. zigit writes → git reads
#        b. git writes  → zigit reads
#   3. cat-file modes (-p, -t, -s, -e) with prefix lookup.
#
# Exits non-zero on the first divergence and prints a diff.

set -u

ZIGIT_BIN="${ZIGIT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/zigit}"
[[ -x "$ZIGIT_BIN" ]] || { echo "ERROR: zigit binary not found at $ZIGIT_BIN — run \`zig build\` first" >&2; exit 2; }

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

PASS=0
FAIL=0
FAILED_NAMES=()

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $name"
        echo -e "    ${DIM}expected: $expected${NC}"
        echo -e "    ${DIM}actual:   $actual${NC}"
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$name")
    fi
}

WORK="$(mktemp -d -t zigit-parity-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ── Section 1: hash-object parity (no write) ──────────────────────────────────
echo "1. hash-object parity (file path, no -w)"
mkdir -p "$WORK/fixtures"

# Generate a battery of fixtures.
: > "$WORK/fixtures/empty.txt"
echo -n "hello" > "$WORK/fixtures/no-newline.txt"
echo "hello" > "$WORK/fixtures/with-newline.txt"
printf 'line1\nline2\nline3\n' > "$WORK/fixtures/multiline.txt"
head -c 16 /dev/urandom > "$WORK/fixtures/binary-small.bin"
head -c 1048576 /dev/urandom > "$WORK/fixtures/binary-1mb.bin"

for f in "$WORK"/fixtures/*; do
    name="$(basename "$f")"
    git_sha=$(git hash-object "$f")
    zigit_sha=$("$ZIGIT_BIN" hash-object "$f")
    check "$name" "$git_sha" "$zigit_sha"
done

# ── Section 2: --stdin parity ─────────────────────────────────────────────────
echo
echo "2. hash-object --stdin parity"
for payload in "" "x" "hello world" "$(printf 'a\nb\nc\n')"; do
    git_sha=$(printf '%s' "$payload" | git hash-object --stdin)
    zigit_sha=$(printf '%s' "$payload" | "$ZIGIT_BIN" hash-object --stdin)
    label="payload-len-${#payload}"
    check "$label" "$git_sha" "$zigit_sha"
done

# ── Section 3: zigit-writes → git-reads ───────────────────────────────────────
echo
echo "3. zigit writes → git reads"
ZW="$WORK/zigit-writes"
mkdir -p "$ZW"
( cd "$ZW" && "$ZIGIT_BIN" init >/dev/null )

for f in "$WORK"/fixtures/empty.txt "$WORK"/fixtures/with-newline.txt "$WORK"/fixtures/binary-1mb.bin; do
    name="$(basename "$f")"
    sha=$(cd "$ZW" && "$ZIGIT_BIN" hash-object -w "$f")

    # git uses GIT_DIR + the same loose-store layout, so it can read
    # zigit's objects directly out of $ZW/.git/objects/.
    git_payload=$(GIT_DIR="$ZW/.git" git cat-file -p "$sha" | shasum -a 1 | awk '{print $1}')
    actual_payload=$(shasum -a 1 < "$f" | awk '{print $1}')
    check "git reads $name (sha-of-payload)" "$actual_payload" "$git_payload"
done

# ── Section 4: git-writes → zigit-reads ───────────────────────────────────────
echo
echo "4. git writes → zigit reads"
GW="$WORK/git-writes"
mkdir -p "$GW"
( cd "$GW" && git init -q )

for f in "$WORK"/fixtures/empty.txt "$WORK"/fixtures/with-newline.txt "$WORK"/fixtures/binary-1mb.bin; do
    name="$(basename "$f")"
    sha=$(cd "$GW" && git hash-object -w "$f")

    zigit_payload_sha=$(cd "$GW" && "$ZIGIT_BIN" cat-file -p "$sha" | shasum -a 1 | awk '{print $1}')
    actual_payload_sha=$(shasum -a 1 < "$f" | awk '{print $1}')
    check "zigit reads $name" "$actual_payload_sha" "$zigit_payload_sha"
done

# ── Section 5: cat-file modes ─────────────────────────────────────────────────
echo
echo "5. cat-file modes (-t, -s, -e, prefix lookup)"
sample_sha=$(cd "$GW" && git hash-object -w "$WORK/fixtures/multiline.txt")
expected_size=$(wc -c < "$WORK/fixtures/multiline.txt" | tr -d ' ')

git_kind=$(cd "$GW" && git cat-file -t "$sample_sha")
zigit_kind=$(cd "$GW" && "$ZIGIT_BIN" cat-file -t "$sample_sha")
check "-t (kind)" "$git_kind" "$zigit_kind"

zigit_size=$(cd "$GW" && "$ZIGIT_BIN" cat-file -s "$sample_sha")
check "-s (size)" "$expected_size" "$zigit_size"

# Existence checks via exit code.
if (cd "$GW" && "$ZIGIT_BIN" cat-file -e "$sample_sha"); then
    check "-e existing" "0" "0"
else
    check "-e existing" "0" "$?"
fi
if (cd "$GW" && "$ZIGIT_BIN" cat-file -e "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null); then
    check "-e missing returns nonzero" "nonzero" "0"
else
    check "-e missing returns nonzero" "nonzero" "nonzero"
fi

# Prefix lookup (git supports >= 4 hex chars; we mirror that).
prefix6="${sample_sha:0:6}"
git_prefix=$(cd "$GW" && git cat-file -p "$prefix6" | shasum -a 1 | awk '{print $1}')
zigit_prefix=$(cd "$GW" && "$ZIGIT_BIN" cat-file -p "$prefix6" | shasum -a 1 | awk '{print $1}')
check "prefix lookup ($prefix6)" "$git_prefix" "$zigit_prefix"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All $TOTAL parity checks passed.${NC}"
    exit 0
else
    echo -e "${RED}$FAIL of $TOTAL parity checks failed:${NC}"
    for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
    exit 1
fi
