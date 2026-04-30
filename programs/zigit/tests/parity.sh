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

# ── Section 6: index parity (update-index + ls-files) ─────────────────────────
echo
echo "6. update-index → ls-files parity"
IDX="$WORK/index-test"
mkdir -p "$IDX"
( cd "$IDX" && "$ZIGIT_BIN" init >/dev/null )
echo "alpha" > "$IDX/a.txt"
echo "beta" > "$IDX/b.txt"
mkdir -p "$IDX/sub/deep"
echo "gamma" > "$IDX/sub/c.txt"
echo "delta" > "$IDX/sub/deep/d.txt"

( cd "$IDX" && "$ZIGIT_BIN" update-index --add a.txt b.txt sub/c.txt sub/deep/d.txt )

# git reads the zigit-written index transparently — both should agree.
git_paths=$(cd "$IDX" && git ls-files)
zigit_paths=$(cd "$IDX" && "$ZIGIT_BIN" ls-files)
check "ls-files paths" "$git_paths" "$zigit_paths"

git_stage=$(cd "$IDX" && git ls-files -s)
zigit_stage=$(cd "$IDX" && "$ZIGIT_BIN" ls-files -s)
check "ls-files -s lines" "$git_stage" "$zigit_stage"

# ── Section 7: write-tree parity (across nested dirs) ─────────────────────────
echo
echo "7. write-tree parity"
git_tree=$(cd "$IDX" && git write-tree)
zigit_tree=$(cd "$IDX" && "$ZIGIT_BIN" write-tree)
check "root tree oid" "$git_tree" "$zigit_tree"

# Pretty-print a sub-tree both ways.
sub_oid=$(cd "$IDX" && git ls-tree "$git_tree" sub | awk '{print $3}')
git_sub_pretty=$(cd "$IDX" && git cat-file -p "$sub_oid")
zigit_sub_pretty=$(cd "$IDX" && "$ZIGIT_BIN" cat-file -p "$sub_oid")
check "tree pretty-print (sub)" "$git_sub_pretty" "$zigit_sub_pretty"

# ── Section 8: commit-tree round-trip ─────────────────────────────────────────
echo
echo "8. commit-tree round-trip"
# zigit currently always emits +0000 for the tz offset (computing the
# local offset takes a libc detour we don't link yet). Force git to do
# the same by exporting TZ=UTC for both sides — when zigit gains real
# tz handling in Phase 5 we can drop this.
export TZ=UTC
export GIT_AUTHOR_NAME="Parity Bot"
export GIT_AUTHOR_EMAIL="parity@example.com"
export GIT_AUTHOR_DATE=1700000000
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE

# Same identity + same date + same tree → same commit oid both ways.
zigit_commit=$(cd "$IDX" && "$ZIGIT_BIN" commit-tree "$zigit_tree" -m "first")
git_commit=$(cd "$IDX" && echo "first" | git commit-tree "$git_tree")
check "commit oid (same identity, date, tree)" "$git_commit" "$zigit_commit"

# git can `log` a zigit-written commit when pointed at it via a ref.
( cd "$IDX" && git update-ref refs/heads/main "$zigit_commit" )
git_log_subject=$(cd "$IDX" && git log -1 --format='%s' refs/heads/main)
check "git log reads zigit commit subject" "first" "$git_log_subject"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 9: porcelain — add / commit / log ─────────────────────────────────
echo
echo "9. porcelain: add → commit → log"
PR="$WORK/porcelain"
mkdir -p "$PR"

# Each side gets its own working copy with identical content + identity
# + dates so the resulting commit OIDs must match bit-for-bit.
ZW2="$PR/zigit"
GW2="$PR/git"
mkdir -p "$ZW2" "$GW2"
( cd "$ZW2" && "$ZIGIT_BIN" init >/dev/null )
( cd "$GW2" && git init -q )

export TZ=UTC
export GIT_AUTHOR_NAME="Porcelain Bot"
export GIT_AUTHOR_EMAIL="porcelain@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

for n in 1 2 3; do
    payload="commit number $n contents"
    echo "$payload" > "$ZW2/file$n.txt"
    echo "$payload" > "$GW2/file$n.txt"

    # Use a stable timestamp per commit so the chain is reproducible.
    export GIT_AUTHOR_DATE="$((1700000000 + n * 100))"
    export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"

    ( cd "$ZW2" && "$ZIGIT_BIN" add "file$n.txt" >/dev/null && "$ZIGIT_BIN" commit -m "commit $n" >/dev/null )
    ( cd "$GW2" && git add "file$n.txt" && git commit -q -m "commit $n" )
done

# Compare the resulting HEADs (use rev-parse since real git may have
# packed the ref or chosen a different default branch name).
zigit_head=$(cd "$ZW2" && git rev-parse HEAD)
git_head=$(cd "$GW2" && git rev-parse HEAD)
check "HEAD oid after 3 commits" "$git_head" "$zigit_head"

# Compare the full log via real git running against each repo.
zigit_log=$(cd "$ZW2" && git log --pretty=oneline)
git_log_=$(cd "$GW2" && git log --pretty=oneline)
check "git log against zigit repo" "$git_log_" "$zigit_log"

# zigit's own log should at minimum hit the same oids and subjects.
zigit_log_self=$(cd "$ZW2" && "$ZIGIT_BIN" log | grep -E '^(commit |    )' | sed 's/^    //')
expected_self="commit $zigit_head
commit 3
commit $(cd "$ZW2" && git rev-parse HEAD~1)
commit 2
commit $(cd "$ZW2" && git rev-parse HEAD~2)
commit 1"
check "zigit log content" "$expected_self" "$zigit_log_self"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 10: status ────────────────────────────────────────────────────────
echo
echo "10. status — staged / unstaged / untracked"
ST="$WORK/status-test"
mkdir -p "$ST"
( cd "$ST" && "$ZIGIT_BIN" init >/dev/null )

export TZ=UTC
export GIT_AUTHOR_NAME="Status Bot"
export GIT_AUTHOR_EMAIL="status@example.com"
export GIT_AUTHOR_DATE=1700000000
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE

# Empty repo, no commits, no files: clean.
zigit_porc=$(cd "$ST" && "$ZIGIT_BIN" status -s)
git_porc=$(cd "$ST" && git status --porcelain)
check "porcelain on empty repo" "$git_porc" "$zigit_porc"

# Single untracked file.
echo alpha > "$ST/a.txt"
zigit_porc=$(cd "$ST" && "$ZIGIT_BIN" status -s)
git_porc=$(cd "$ST" && git status --porcelain)
check "porcelain with untracked" "$git_porc" "$zigit_porc"

# After staging — new file in index, untracked is gone.
( cd "$ST" && "$ZIGIT_BIN" add a.txt >/dev/null )
zigit_porc=$(cd "$ST" && "$ZIGIT_BIN" status -s)
git_porc=$(cd "$ST" && git status --porcelain)
check "porcelain with staged new" "$git_porc" "$zigit_porc"

# Commit, then mix: modify a.txt (unstaged), add b.txt (staged), drop c.txt (untracked).
( cd "$ST" && "$ZIGIT_BIN" commit -m "first" >/dev/null )
echo "more" >> "$ST/a.txt"
echo "beta" > "$ST/b.txt"
( cd "$ST" && "$ZIGIT_BIN" add b.txt >/dev/null )
echo "gamma" > "$ST/c.txt"
zigit_porc=$(cd "$ST" && "$ZIGIT_BIN" status -s)
git_porc=$(cd "$ST" && git status --porcelain)
check "porcelain with mixed states" "$git_porc" "$zigit_porc"

# After staging the modification too (a.txt now has both staged + further unstaged).
echo "even more" >> "$ST/a.txt"
( cd "$ST" && "$ZIGIT_BIN" add a.txt >/dev/null )
echo "yet more" >> "$ST/a.txt"
zigit_porc=$(cd "$ST" && "$ZIGIT_BIN" status -s)
git_porc=$(cd "$ST" && git status --porcelain)
check "porcelain MM (staged + unstaged on same file)" "$git_porc" "$zigit_porc"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 11: diff ──────────────────────────────────────────────────────────
echo
echo "11. diff — workdir vs index, --cached, multi-hunk"
DT="$WORK/diff-test"
mkdir -p "$DT"
( cd "$DT" && "$ZIGIT_BIN" init >/dev/null )

export TZ=UTC
export GIT_AUTHOR_NAME="Diff Bot"
export GIT_AUTHOR_EMAIL="diff@example.com"
export GIT_AUTHOR_DATE=1700000000
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE

# Multi-line file with replace + insert + delete.
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "$DT/poem.txt"
( cd "$DT" && "$ZIGIT_BIN" add poem.txt >/dev/null )
( cd "$DT" && "$ZIGIT_BIN" commit -m "init" >/dev/null )

printf 'ONE\ntwo\nthree\nINSERTED\nfour\nsix\nseven\n' > "$DT/poem.txt"
zigit_diff=$(cd "$DT" && "$ZIGIT_BIN" diff)
git_diff=$(cd "$DT" && git diff)
check "diff workdir vs index (multi-hunk)" "$git_diff" "$zigit_diff"

( cd "$DT" && "$ZIGIT_BIN" add poem.txt >/dev/null )
zigit_cached=$(cd "$DT" && "$ZIGIT_BIN" diff --cached)
git_cached=$(cd "$DT" && git diff --cached)
check "diff --cached" "$git_cached" "$zigit_cached"

# After commit, workdir changes only.
( cd "$DT" && "$ZIGIT_BIN" commit -m "edit" >/dev/null )
printf 'ZZZ\ntwo\nthree\nINSERTED\nfour\nsix\nseven\nNEW_LAST\n' > "$DT/poem.txt"
zigit_diff=$(cd "$DT" && "$ZIGIT_BIN" diff)
git_diff=$(cd "$DT" && git diff)
check "diff after commit (workdir vs index)" "$git_diff" "$zigit_diff"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

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
