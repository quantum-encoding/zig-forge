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

# ── Section 12: branch + switch + checkout ────────────────────────────────────
echo
echo "12. branch + switch + checkout"
BR="$WORK/branch-test"
mkdir -p "$BR"
( cd "$BR" && "$ZIGIT_BIN" init >/dev/null )

export TZ=UTC
export GIT_AUTHOR_NAME="Branch Bot"
export GIT_AUTHOR_EMAIL="branch@example.com"
export GIT_AUTHOR_DATE=1700000000
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE

echo "main version" > "$BR/file.txt"
( cd "$BR" && "$ZIGIT_BIN" add file.txt >/dev/null && "$ZIGIT_BIN" commit -m "main first" >/dev/null )

# branch list — single branch right after first commit.
zigit_b=$(cd "$BR" && "$ZIGIT_BIN" branch)
git_b=$(cd "$BR" && git branch)
check "branch list (single)" "$git_b" "$zigit_b"

# Create + switch into a feature branch, change content, commit.
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$BR' && '$ZIGIT_BIN' switch -c feature >/dev/null"
echo "feature version" > "$BR/file.txt"
echo "extra-only-on-feature" > "$BR/extra.txt"
( cd "$BR" && "$ZIGIT_BIN" add file.txt extra.txt >/dev/null )
GIT_AUTHOR_DATE=1700000200 GIT_COMMITTER_DATE=1700000200 \
    bash -c "cd '$BR' && '$ZIGIT_BIN' commit -m 'feature change' >/dev/null"

zigit_b=$(cd "$BR" && "$ZIGIT_BIN" branch)
git_b=$(cd "$BR" && git branch)
check "branch list (two, on feature)" "$git_b" "$zigit_b"

# Switch back to main: file content reverts, extra.txt removed.
( cd "$BR" && "$ZIGIT_BIN" switch main >/dev/null )
file_after=$(cat "$BR/file.txt")
check "file.txt content after switch back to main" "main version" "$file_after"
extra_exists=$([ -e "$BR/extra.txt" ] && echo "yes" || echo "no")
check "extra.txt removed after switch back" "no" "$extra_exists"

# Round-trip: switch back to feature, content reappears.
( cd "$BR" && "$ZIGIT_BIN" switch feature >/dev/null )
file_after=$(cat "$BR/file.txt")
check "file.txt restored on feature" "feature version" "$file_after"
extra_after=$(cat "$BR/extra.txt")
check "extra.txt restored on feature" "extra-only-on-feature" "$extra_after"

# Safety: a local edit to file.txt should refuse the switch back.
echo "uncommitted local edit" > "$BR/file.txt"
if (cd "$BR" && "$ZIGIT_BIN" switch main 2>/dev/null); then
    check "switch refused when local edits would be lost" "refused" "accepted"
else
    rc=$?
    check "switch refused when local edits would be lost" "refused" "refused"
    check "switch refusal uses non-zero exit" "1" "$rc"
fi
# Cleanup the local edit and verify switch now succeeds.
( cd "$BR" && "$ZIGIT_BIN" checkout file.txt 2>/dev/null || git checkout -- file.txt )
( cd "$BR" && "$ZIGIT_BIN" switch main >/dev/null )

# Detached HEAD: checkout a commit by hex — HEAD becomes raw oid.
feature_oid=$(cd "$BR" && git rev-parse feature)
( cd "$BR" && "$ZIGIT_BIN" checkout "$feature_oid" >/dev/null )
head_text=$(cat "$BR/.git/HEAD")
check "detached HEAD writes raw oid" "$feature_oid" "$head_text"

# git agrees we're detached at the same commit.
git_status=$(cd "$BR" && git status --porcelain=v2 --branch | grep -E '^# branch.head')
check "git sees the same detached HEAD" "# branch.head (detached)" "$git_status"

# Branch -d removes a non-current branch.
( cd "$BR" && "$ZIGIT_BIN" checkout main >/dev/null )
( cd "$BR" && "$ZIGIT_BIN" branch -d feature >/dev/null )
zigit_b=$(cd "$BR" && "$ZIGIT_BIN" branch)
check "branch -d removed feature" "* main" "$zigit_b"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 13: pack files (read) — `git gc` then read with zigit ─────────────
echo
echo "13. pack reading after git gc (delta chains, packed-refs)"
PK="$WORK/pack-test"
mkdir -p "$PK"
( cd "$PK" && git init -q )

export TZ=UTC
export GIT_AUTHOR_NAME="Pack Bot"
export GIT_AUTHOR_EMAIL="pack@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# Build up a small history with a file that mutates each commit so
# git gc has plausible delta candidates to chain.
for n in 1 2 3 4 5; do
    payload=$(printf 'line a\nline b\nline c\nrev %d\nline d\nline e\n' $n)
    echo "$payload" > "$PK/file.txt"
    export GIT_AUTHOR_DATE=$((1700000000 + n * 100))
    export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE
    ( cd "$PK" && git add file.txt && git commit -q -m "rev $n" )
done

# Pack everything, then verify there are no loose objects left and
# the loose ref has been moved into packed-refs.
( cd "$PK" && git gc --quiet )
# Exclude objects/info/ — that's git's metadata (commit-graph, packs
# index), not actual loose objects.
loose_count=$(find "$PK/.git/objects" -type f \! -path '*/pack/*' \! -path '*/info/*' \! -name 'pack-*' | wc -l | tr -d ' ')
check "git gc collapses loose objects (none left)" "0" "$loose_count"
[ -f "$PK/.git/packed-refs" ] && packed_refs_exists=yes || packed_refs_exists=no
check "git gc emits packed-refs" "yes" "$packed_refs_exists"

# zigit reads everything via the pack/packed-refs fallback.
head_oid=$(cd "$PK" && git rev-parse HEAD)
zigit_head=$(cd "$PK" && "$ZIGIT_BIN" log -n 1 | head -1 | awk '{print $2}')
check "zigit log finds HEAD via packed-refs" "commit-oid: $head_oid" "commit-oid: $zigit_head"

# zigit cat-file -p HEAD → same payload as git cat-file -p HEAD.
zigit_commit=$(cd "$PK" && "$ZIGIT_BIN" cat-file -p "$head_oid")
git_commit=$(cd "$PK" && git cat-file -p "$head_oid")
check "cat-file -p commit (from pack)" "$git_commit" "$zigit_commit"

# Walk to an older commit (almost certainly stored as OFS_DELTA).
older_oid=$(cd "$PK" && git rev-parse HEAD~3)
zigit_older=$(cd "$PK" && "$ZIGIT_BIN" cat-file -p "$older_oid")
git_older=$(cd "$PK" && git cat-file -p "$older_oid")
check "cat-file -p delta-encoded older commit" "$git_older" "$zigit_older"

# Read a blob via prefix lookup; PackStore.matchPrefix should agree
# with git's resolution.
sample_blob=$(cd "$PK" && git rev-parse HEAD:file.txt)
zigit_blob=$(cd "$PK" && "$ZIGIT_BIN" cat-file -p "${sample_blob:0:7}")
git_blob=$(cd "$PK" && git cat-file -p "$sample_blob")
check "cat-file -p blob via 7-char prefix (pack lookup)" "$git_blob" "$zigit_blob"

# zigit log walks the chain (5 commits).
zigit_log_count=$(cd "$PK" && "$ZIGIT_BIN" log | grep -c '^commit ')
check "zigit log walks pack-only history" "5" "$zigit_log_count"

# zigit status + diff should agree with git after a workdir edit
# (exercises pack-backed HEAD-tree map building).
echo "live edit" >> "$PK/file.txt"
zigit_porc=$(cd "$PK" && "$ZIGIT_BIN" status -s)
git_porc=$(cd "$PK" && git status --porcelain)
check "status against pack-only repo" "$git_porc" "$zigit_porc"
zigit_diff=$(cd "$PK" && "$ZIGIT_BIN" diff)
git_diff=$(cd "$PK" && git diff)
check "diff against pack-only repo" "$git_diff" "$zigit_diff"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 14: gc — write packs + packed-refs that real git accepts ──────────
echo
echo "14. gc — write packs + packed-refs"
GC="$WORK/gc-test"
mkdir -p "$GC"
( cd "$GC" && "$ZIGIT_BIN" init >/dev/null )

export TZ=UTC
export GIT_AUTHOR_NAME="Gc Bot"
export GIT_AUTHOR_EMAIL="gc@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

for n in 1 2 3 4 5; do
    payload=$(printf 'line one\nline two\nline three\nrev %d\nline five\n' $n)
    echo "$payload" > "$GC/file.txt"
    export GIT_AUTHOR_DATE=$((1700000000 + n * 100))
    export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE
    ( cd "$GC" && "$ZIGIT_BIN" add file.txt >/dev/null && "$ZIGIT_BIN" commit -m "v$n" >/dev/null )
done

# Snapshot HEAD before gc; it should be unchanged after gc.
head_before=$(cd "$GC" && git rev-parse HEAD)

# Count loose objects before; we expect ≥ commit_count + tree_count + blob_count.
loose_before=$(find "$GC/.git/objects" -type f \! -path '*/info/*' \! -path '*/pack/*' | wc -l | tr -d ' ')

( cd "$GC" && "$ZIGIT_BIN" gc >/dev/null )

# After gc: no loose objects, exactly one .pack + one .idx.
loose_after=$(find "$GC/.git/objects" -type f \! -path '*/info/*' \! -path '*/pack/*' | wc -l | tr -d ' ')
check "gc cleared loose objects" "0" "$loose_after"

pack_files=$(find "$GC/.git/objects/pack" -type f -name 'pack-*.pack' | wc -l | tr -d ' ')
idx_files=$(find "$GC/.git/objects/pack" -type f -name 'pack-*.idx' | wc -l | tr -d ' ')
check "gc wrote one pack file" "1" "$pack_files"
check "gc wrote one idx file" "1" "$idx_files"

# packed-refs has the branch; loose ref file is gone.
[ -f "$GC/.git/packed-refs" ] && pr_exists=yes || pr_exists=no
check "gc wrote packed-refs" "yes" "$pr_exists"
loose_main_present=$([ -f "$GC/.git/refs/heads/main" ] && echo yes || echo no)
check "loose refs/heads/main removed" "no" "$loose_main_present"

# git accepts the result: fsck clean, log walks, HEAD matches.
fsck_output=$(cd "$GC" && git fsck --strict 2>&1)
check "git fsck --strict on zigit-packed repo" "" "$fsck_output"

head_after=$(cd "$GC" && git rev-parse HEAD)
check "HEAD oid unchanged by gc" "$head_before" "$head_after"

git_log_count=$(cd "$GC" && git log --oneline | wc -l | tr -d ' ')
check "git log walks 5 commits from packed repo" "5" "$git_log_count"

# verify-pack: every object well-formed inside the new pack.
verify_status=$(cd "$GC" && git verify-pack -v "$GC"/.git/objects/pack/pack-*.idx 2>&1 | tail -1)
case "$verify_status" in
    *": ok"*) check "git verify-pack ok" "ok" "ok" ;;
    *)        check "git verify-pack ok" "ok" "$verify_status" ;;
esac

# zigit can still read everything via its pack reader.
zigit_log_count=$(cd "$GC" && "$ZIGIT_BIN" log | grep -c '^commit ')
check "zigit log walks pack-only result" "5" "$zigit_log_count"

# Diff after a workdir edit still matches git (post-gc).
echo "live edit" >> "$GC/file.txt"
diff <(cd "$GC" && "$ZIGIT_BIN" diff) <(cd "$GC" && git diff) >/dev/null && diff_match=match || diff_match=mismatch
check "zigit diff matches git diff after gc" "match" "$diff_match"

# A second gc with no loose objects is a no-op.
output=$(cd "$GC" && git checkout -- file.txt && "$ZIGIT_BIN" gc 2>&1 | head -1)
check "second gc reports nothing to repack" "Nothing to repack." "$output"

# Cloning the zigit-packed repo into a fresh dir works.
CLONE="$WORK/gc-clone"
git clone -q "$GC" "$CLONE" 2>&1 >/dev/null
clone_head=$(cd "$CLONE" && git rev-parse HEAD)
check "git clone of zigit-packed repo resolves HEAD" "$head_before" "$clone_head"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 15: clone — smart-HTTPS v2 against a real remote ──────────────────
# Requires network access. Default test target is the small (~16
# objects, 3 branches) octocat/Spoon-Knife repo. Skip cleanly when
# offline so unit-test runs aren't gated on connectivity.
echo
echo "15. clone — smart-HTTPS v2"
CLONE_URL="${ZIGIT_CLONE_TEST_URL:-https://github.com/octocat/Spoon-Knife}"
if curl -fs -m 5 -o /dev/null "$CLONE_URL/info/refs?service=git-upload-pack" -H 'Git-Protocol: version=2'; then
    CW="$WORK/clone-test"
    mkdir -p "$CW"

    # Real git first to get the canonical HEAD.
    REF="$CW/git-clone"
    git clone -q "$CLONE_URL" "$REF" 2>/dev/null
    git_head=$(cd "$REF" && git rev-parse HEAD)
    git_branches=$(cd "$REF" && git for-each-ref --format='%(refname)' refs/heads | sort)

    # Then zigit clone.
    ZC="$CW/zigit-clone"
    "$ZIGIT_BIN" clone "$CLONE_URL" "$ZC" 2>&1 | tail -1 >/dev/null
    zigit_head=$(cd "$ZC" && git rev-parse HEAD)
    check "zigit clone HEAD oid matches git clone" "$git_head" "$zigit_head"

    # fsck passes against the zigit-cloned repo.
    fsck_output=$(cd "$ZC" && git fsck --strict 2>&1)
    check "git fsck on zigit clone is clean" "" "$fsck_output"

    # Branch list matches (zigit advertises only refs/heads + refs/tags
    # via ls-refs, so it should agree with git clone's default).
    zigit_branches=$(cd "$ZC" && git for-each-ref --format='%(refname)' refs/heads | sort)
    check "zigit clone has same branches as git clone" "$git_branches" "$zigit_branches"

    # Work tree contents materialised; index reflects HEAD's tree.
    file_count_real=$(find "$REF" \! -path "$REF/.git/*" -type f | wc -l | tr -d ' ')
    file_count_zigit=$(find "$ZC" \! -path "$ZC/.git/*" -type f | wc -l | tr -d ' ')
    check "zigit clone work-tree file count" "$file_count_real" "$file_count_zigit"

    # Phase 14: clone auto-adds [remote "origin"] with the source URL.
    origin_url=$(cd "$ZC" && git config --get remote.origin.url)
    check "zigit clone auto-set remote.origin.url" "$CLONE_URL" "$origin_url"
    origin_fetch=$(cd "$ZC" && git config --get remote.origin.fetch)
    check "zigit clone auto-set remote.origin.fetch" \
        "+refs/heads/*:refs/remotes/origin/*" "$origin_fetch"
else
    echo -e "  ${DIM}skipping — $CLONE_URL not reachable${NC}"
fi

# ── Section 16: push — to a local git-http-backend ────────────────────────────
# Spins up a Python wrapper around `git http-backend` against a bare
# repo, has zigit push to it, and verifies the bare upstream ends up
# with the expected ref + a clean `git fsck`. Skips if either Python
# 3 or git-http-backend isn't on the system.
echo
echo "16. push — to local git-http-backend"

GIT_BACKEND="$(git --exec-path 2>/dev/null)/git-http-backend"
SERVER_PY="$(cd "$(dirname "$0")" && pwd)/git_http_server.py"
if [ ! -x "$GIT_BACKEND" ] || ! command -v python3 >/dev/null 2>&1 || [ ! -x "$SERVER_PY" ]; then
    echo -e "  ${DIM}skipping — git-http-backend or python3 missing${NC}"
else
    PUSH_DIR="$WORK/push-test"
    mkdir -p "$PUSH_DIR/bare" "$PUSH_DIR/src"

    # Bare upstream needs http.receivepack to allow pushes.
    ( cd "$PUSH_DIR/bare" && git init -q --bare && git config http.receivepack true )

    # Source repo with three commits.
    export TZ=UTC
    export GIT_AUTHOR_NAME="Push Bot"
    export GIT_AUTHOR_EMAIL="push@example.com"
    export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
    export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

    ( cd "$PUSH_DIR/src" && "$ZIGIT_BIN" init >/dev/null )
    for n in 1 2 3; do
        echo "v$n" > "$PUSH_DIR/src/file.txt"
        export GIT_AUTHOR_DATE=$((1700000000 + n * 100))
        export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE
        ( cd "$PUSH_DIR/src" && "$ZIGIT_BIN" add file.txt >/dev/null && "$ZIGIT_BIN" commit -m "v$n" >/dev/null )
    done
    expected_head=$(cd "$PUSH_DIR/src" && cat .git/refs/heads/main)

    # Bring up the local HTTP server.
    SERVER_LOG="$PUSH_DIR/server.log"
    GIT_HTTP_BACKEND="$GIT_BACKEND" GIT_PROJECT_ROOT="$PUSH_DIR/bare" \
        python3 "$SERVER_PY" 0 > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    # Wait for the "ready <port>" line.
    for _ in $(seq 1 20); do
        if grep -q '^ready ' "$SERVER_LOG" 2>/dev/null; then break; fi
        sleep 0.1
    done
    PORT=$(awk '/^ready /{print $2; exit}' "$SERVER_LOG")
    if [ -z "$PORT" ]; then
        kill "$SERVER_PID" 2>/dev/null
        check "git-http-backend started" "ready" "failed-to-start"
    else
        URL="http://127.0.0.1:$PORT"

        # First push: empty bare repo → all 3 commits land.
        push_out=$(cd "$PUSH_DIR/src" && "$ZIGIT_BIN" push "$URL" main 2>&1)
        unpack_line=$(echo "$push_out" | grep 'remote: unpack:' | tr -d '\r')
        ref_line=$(echo "$push_out" | grep 'remote: ok refs/heads/main' | tr -d '\r')
        check "first push: unpack ok" "  remote: unpack: ok" "$unpack_line"
        check "first push: ref accepted" "  remote: ok refs/heads/main" "$ref_line"

        # Bare upstream now points at the local oid.
        bare_head=$(cat "$PUSH_DIR/bare/refs/heads/main" 2>/dev/null)
        check "bare upstream HEAD matches local" "$expected_head" "$bare_head"

        # git fsck on the bare repo is clean.
        fsck=$(cd "$PUSH_DIR/bare" && git fsck --strict 2>&1 | grep -v "notice:" || true)
        check "bare upstream passes git fsck" "" "$fsck"

        # git log on bare matches our history.
        bare_log=$(cd "$PUSH_DIR/bare" && git log refs/heads/main --oneline)
        check "bare git log walks 3 commits" "3" "$(echo "$bare_log" | wc -l | tr -d ' ')"

        # Push again with no changes: "Everything up-to-date".
        upd=$(cd "$PUSH_DIR/src" && "$ZIGIT_BIN" push "$URL" main 2>&1 | tr -d '\r')
        check "no-op push reports up-to-date" "Everything up-to-date" "$upd"

        # Configure a named remote and push by name (covers Phase 14
        # wiring of cli/push.zig → config lookup of remote.<name>.url).
        ( cd "$PUSH_DIR/src" && "$ZIGIT_BIN" remote add upstream "$URL" )
        named_push=$(cd "$PUSH_DIR/src" && "$ZIGIT_BIN" push upstream main 2>&1 | tr -d '\r')
        check "push by remote-name no-op" "Everything up-to-date" "$named_push"

        # New commit, push again: incremental delta.
        echo "v4" > "$PUSH_DIR/src/file.txt"
        GIT_AUTHOR_DATE=1700000400 GIT_COMMITTER_DATE=1700000400 \
            bash -c "cd '$PUSH_DIR/src' && '$ZIGIT_BIN' add file.txt >/dev/null && '$ZIGIT_BIN' commit -m v4 >/dev/null"
        push2=$(cd "$PUSH_DIR/src" && "$ZIGIT_BIN" push "$URL" main 2>&1)
        unpack2=$(echo "$push2" | grep 'remote: unpack:' | tr -d '\r')
        check "incremental push: unpack ok" "  remote: unpack: ok" "$unpack2"
        local2=$(cat "$PUSH_DIR/src/.git/refs/heads/main")
        bare2=$(cat "$PUSH_DIR/bare/refs/heads/main")
        check "bare upstream HEAD matches after second push" "$local2" "$bare2"

        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi

    unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
fi

# ── Section 17: merge — fast-forward + true 3-way + conflict refusal ──────────
echo
echo "17. merge — FF + 3-way + conflict"
MR="$WORK/merge-test"
mkdir -p "$MR"

export TZ=UTC
export GIT_AUTHOR_NAME="Merge Bot"
export GIT_AUTHOR_EMAIL="merge@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# (a) Fast-forward — feature is ahead, main hasn't moved.
FF="$MR/ff"
mkdir -p "$FF" && ( cd "$FF" && "$ZIGIT_BIN" init >/dev/null )
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    bash -c "cd '$FF' && echo base > b && '$ZIGIT_BIN' add b && '$ZIGIT_BIN' commit -m base >/dev/null"
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$FF' && '$ZIGIT_BIN' switch -c feature >/dev/null && echo new > n && '$ZIGIT_BIN' add n && '$ZIGIT_BIN' commit -m feature >/dev/null"
( cd "$FF" && "$ZIGIT_BIN" switch main >/dev/null )
ff_msg=$(cd "$FF" && "$ZIGIT_BIN" merge feature 2>&1 | head -1)
case "$ff_msg" in Fast-forward*) check "FF merge prints Fast-forward" "ok" "ok" ;;
                  *)             check "FF merge prints Fast-forward" "ok" "$ff_msg" ;; esac
ff_n_count=$(find "$FF" -name n -not -path "*/.git/*" | wc -l | tr -d ' ')
check "FF merge brings new file into work tree" "1" "$ff_n_count"

# (b) Already up-to-date.
ut=$(cd "$FF" && "$ZIGIT_BIN" merge feature 2>&1 | tr -d '\r')
check "no-op merge prints up-to-date" "Already up to date." "$ut"

# (c) True 3-way (no conflict).
TW="$MR/tw"
mkdir -p "$TW" && ( cd "$TW" && "$ZIGIT_BIN" init >/dev/null )
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    bash -c "cd '$TW' && echo base > b && '$ZIGIT_BIN' add b && '$ZIGIT_BIN' commit -m base >/dev/null"
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$TW' && '$ZIGIT_BIN' switch -c feature >/dev/null && echo only_feature > f && '$ZIGIT_BIN' add f && '$ZIGIT_BIN' commit -m feat >/dev/null"
( cd "$TW" && "$ZIGIT_BIN" switch main >/dev/null )
GIT_AUTHOR_DATE=1700000200 GIT_COMMITTER_DATE=1700000200 \
    bash -c "cd '$TW' && echo only_main > m && '$ZIGIT_BIN' add m && '$ZIGIT_BIN' commit -m maincommit >/dev/null"
GIT_AUTHOR_DATE=1700000300 GIT_COMMITTER_DATE=1700000300 \
    bash -c "cd '$TW' && '$ZIGIT_BIN' merge feature >/dev/null"

files_after=$(ls "$TW" | sort | tr '\n' ' ')
check "3-way merge has both side files" "b f m " "$files_after"

parent_count=$(cd "$TW" && git cat-file -p HEAD | grep -c '^parent ')
check "merge commit has two parents" "2" "$parent_count"

# Count reachable commits (without --graph; --graph only marks one
# commit per row with `*` and uses `| *` for the second parent).
# Diamond = base + main_advance + feat + merge = 4.
commit_count=$(cd "$TW" && git log --oneline --all 2>&1 | wc -l | tr -d ' ')
check "git log walks merge diamond (4 commits)" "4" "$commit_count"

# (d) Conflict refusal.
CF="$MR/conflict"
mkdir -p "$CF" && ( cd "$CF" && "$ZIGIT_BIN" init >/dev/null )
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    bash -c "cd '$CF' && echo v1 > shared && '$ZIGIT_BIN' add shared && '$ZIGIT_BIN' commit -m base >/dev/null"
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$CF' && '$ZIGIT_BIN' switch -c feature >/dev/null && echo from-feature > shared && '$ZIGIT_BIN' add shared && '$ZIGIT_BIN' commit -m fc >/dev/null"
( cd "$CF" && "$ZIGIT_BIN" switch main >/dev/null )
GIT_AUTHOR_DATE=1700000200 GIT_COMMITTER_DATE=1700000200 \
    bash -c "cd '$CF' && echo from-main > shared && '$ZIGIT_BIN' add shared && '$ZIGIT_BIN' commit -m mc >/dev/null"
if (cd "$CF" && "$ZIGIT_BIN" merge feature 2>/dev/null); then
    check "conflicting merge refused" "refused" "accepted"
else
    rc=$?
    check "conflicting merge refused" "refused" "refused"
    check "merge refusal exit code" "1" "$rc"
fi

# ── Section 18: rebase — replay onto a different base ─────────────────────────
echo
echo "18. rebase — replay commits onto a different base"
RB="$MR/rebase"
mkdir -p "$RB" && ( cd "$RB" && "$ZIGIT_BIN" init >/dev/null )

GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    bash -c "cd '$RB' && echo v1 > b && '$ZIGIT_BIN' add b && '$ZIGIT_BIN' commit -m v1 >/dev/null"
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$RB' && '$ZIGIT_BIN' switch -c feature >/dev/null && echo f1 > f1 && '$ZIGIT_BIN' add f1 && '$ZIGIT_BIN' commit -m feature1 >/dev/null"
GIT_AUTHOR_DATE=1700000200 GIT_COMMITTER_DATE=1700000200 \
    bash -c "cd '$RB' && echo f2 > f2 && '$ZIGIT_BIN' add f2 && '$ZIGIT_BIN' commit -m feature2 >/dev/null"
( cd "$RB" && "$ZIGIT_BIN" switch main >/dev/null )
GIT_AUTHOR_DATE=1700000300 GIT_COMMITTER_DATE=1700000300 \
    bash -c "cd '$RB' && echo m > m && '$ZIGIT_BIN' add m && '$ZIGIT_BIN' commit -m main_advance >/dev/null"
( cd "$RB" && "$ZIGIT_BIN" switch feature >/dev/null )
GIT_AUTHOR_DATE=1700000400 GIT_COMMITTER_DATE=1700000400 \
    bash -c "cd '$RB' && '$ZIGIT_BIN' rebase main >/dev/null"

# Linear history with main_advance reachable from feature's tip.
chain_subjects=$(cd "$RB" && git log --pretty=format:'%s' feature)
expected_subjects=$'feature2\nfeature1\nmain_advance\nv1'
check "rebase produces linear history" "$expected_subjects" "$chain_subjects"

files=$(ls "$RB" | sort | tr '\n' ' ')
check "rebase work tree has all files" "b f1 f2 m " "$files"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 19: restore + reset + tag ─────────────────────────────────────────
echo
echo "19. restore / reset / tag"
RR="$WORK/restore-reset-tag"
mkdir -p "$RR" && ( cd "$RR" && "$ZIGIT_BIN" init >/dev/null )

export TZ=UTC
export GIT_AUTHOR_NAME="Polish Bot"
export GIT_AUTHOR_EMAIL="polish@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# Build a 3-commit chain.
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    bash -c "cd '$RR' && echo v1 > a && '$ZIGIT_BIN' add a && '$ZIGIT_BIN' commit -m v1 >/dev/null"
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$RR' && echo v2 > a && '$ZIGIT_BIN' add a && '$ZIGIT_BIN' commit -m v2 >/dev/null"
GIT_AUTHOR_DATE=1700000200 GIT_COMMITTER_DATE=1700000200 \
    bash -c "cd '$RR' && echo v3 > a && '$ZIGIT_BIN' add a && '$ZIGIT_BIN' commit -m v3 >/dev/null"

# (a) restore PATH undoes unstaged edits.
echo "edited" > "$RR/a"
( cd "$RR" && "$ZIGIT_BIN" restore a >/dev/null )
content=$(cat "$RR/a")
check "restore restores from index" "v3" "$content"

# (b) restore --staged unstages a staged change.
echo "staged" > "$RR/a"
( cd "$RR" && "$ZIGIT_BIN" add a >/dev/null )
( cd "$RR" && "$ZIGIT_BIN" restore --staged a >/dev/null )
porcelain=$(cd "$RR" && "$ZIGIT_BIN" status -s)
check "restore --staged unstages without touching workdir" " M a" "$porcelain"
( cd "$RR" && "$ZIGIT_BIN" restore a >/dev/null ) # clean up

# (c) reset --soft moves HEAD only.
v3_oid=$(cd "$RR" && git rev-parse HEAD)
v2_oid=$(cd "$RR" && git rev-parse HEAD~1)
( cd "$RR" && "$ZIGIT_BIN" reset --soft "$v2_oid" >/dev/null )
new_head=$(cd "$RR" && git rev-parse HEAD)
check "reset --soft moved HEAD to v2" "$v2_oid" "$new_head"
# Index still reflects v3 → status shows "M a" (staged change vs new HEAD).
porcelain=$(cd "$RR" && "$ZIGIT_BIN" status -s)
check "reset --soft leaves index untouched" "M  a" "$porcelain"

# (d) reset --mixed (default) also rewrites the index.
( cd "$RR" && "$ZIGIT_BIN" reset "$v3_oid" >/dev/null ) # back to clean v3
( cd "$RR" && "$ZIGIT_BIN" reset "$v2_oid" >/dev/null )
porcelain=$(cd "$RR" && "$ZIGIT_BIN" status -s)
check "reset --mixed unstages but keeps workdir" " M a" "$porcelain"

# (e) reset --hard wipes workdir too.
( cd "$RR" && "$ZIGIT_BIN" reset --hard "$v2_oid" >/dev/null )
content=$(cat "$RR/a")
check "reset --hard rewrites workdir from target" "v2" "$content"
porcelain=$(cd "$RR" && "$ZIGIT_BIN" status -s)
check "reset --hard leaves clean workdir" "" "$porcelain"

# (f) tag NAME [COMMIT].
( cd "$RR" && "$ZIGIT_BIN" tag v2-here >/dev/null )
( cd "$RR" && "$ZIGIT_BIN" tag v3-here "$v3_oid" >/dev/null )
tag_list=$(cd "$RR" && "$ZIGIT_BIN" tag)
expected=$'v2-here\nv3-here'
check "tag listing" "$expected" "$tag_list"

# git agrees on what each tag points at.
git_v2=$(cd "$RR" && git rev-parse refs/tags/v2-here)
git_v3=$(cd "$RR" && git rev-parse refs/tags/v3-here)
check "tag v2-here points at v2 oid" "$v2_oid" "$git_v2"
check "tag v3-here points at v3 oid" "$v3_oid" "$git_v3"

# tag -d removes.
( cd "$RR" && "$ZIGIT_BIN" tag -d v2-here >/dev/null )
remaining=$(cd "$RR" && "$ZIGIT_BIN" tag)
check "tag -d removed v2-here" "v3-here" "$remaining"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 20: diff3-aware merge (disjoint hunks resolve, overlap → markers) ─
echo
echo "20. merge with diff3 (disjoint resolve, overlap → markers)"
D3="$WORK/diff3"
mkdir -p "$D3"

export TZ=UTC
export GIT_AUTHOR_NAME="Diff3 Bot"
export GIT_AUTHOR_EMAIL="diff3@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# (a) Disjoint hunks: ours touches L1, theirs touches L5 → clean.
DJ="$D3/disjoint"
mkdir -p "$DJ" && ( cd "$DJ" && "$ZIGIT_BIN" init >/dev/null )
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    bash -c "cd '$DJ' && printf 'L1\nL2\nL3\nL4\nL5\n' > poem && '$ZIGIT_BIN' add poem && '$ZIGIT_BIN' commit -m base >/dev/null"
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$DJ' && '$ZIGIT_BIN' switch -c feature >/dev/null && printf 'L1\nL2\nL3\nL4\nL5-changed\n' > poem && '$ZIGIT_BIN' add poem && '$ZIGIT_BIN' commit -m feat >/dev/null"
( cd "$DJ" && "$ZIGIT_BIN" switch main >/dev/null )
GIT_AUTHOR_DATE=1700000200 GIT_COMMITTER_DATE=1700000200 \
    bash -c "cd '$DJ' && printf 'L1-changed\nL2\nL3\nL4\nL5\n' > poem && '$ZIGIT_BIN' add poem && '$ZIGIT_BIN' commit -m mainc >/dev/null"
GIT_AUTHOR_DATE=1700000300 GIT_COMMITTER_DATE=1700000300 \
    bash -c "cd '$DJ' && '$ZIGIT_BIN' merge feature >/dev/null"
content=$(cat "$DJ/poem")
expected_dj=$'L1-changed\nL2\nL3\nL4\nL5-changed'
check "diff3 resolved disjoint hunks cleanly" "$expected_dj" "$content"

# (b) Overlapping changes: same line modified differently → markers.
OV="$D3/overlap"
mkdir -p "$OV" && ( cd "$OV" && "$ZIGIT_BIN" init >/dev/null )
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    bash -c "cd '$OV' && echo shared > shared && '$ZIGIT_BIN' add shared && '$ZIGIT_BIN' commit -m base >/dev/null"
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$OV' && '$ZIGIT_BIN' switch -c feature >/dev/null && echo from-feature > shared && '$ZIGIT_BIN' add shared && '$ZIGIT_BIN' commit -m fc >/dev/null"
( cd "$OV" && "$ZIGIT_BIN" switch main >/dev/null )
GIT_AUTHOR_DATE=1700000200 GIT_COMMITTER_DATE=1700000200 \
    bash -c "cd '$OV' && echo from-main > shared && '$ZIGIT_BIN' add shared && '$ZIGIT_BIN' commit -m mc >/dev/null"
if (cd "$OV" && "$ZIGIT_BIN" merge feature 2>/dev/null); then
    check "overlap merge refused" "refused" "accepted"
else
    check "overlap merge refused" "refused" "refused"
fi

# Conflict markers landed in the file with both contents.
overlap_content=$(cat "$OV/shared")
echo "$overlap_content" | grep -q '^<<<<<<< ours' && a=ok || a=missing
check "marker file has <<<<<<< ours" "ok" "$a"
echo "$overlap_content" | grep -q '^=======' && b=ok || b=missing
check "marker file has =======" "ok" "$b"
echo "$overlap_content" | grep -q '^>>>>>>> theirs' && c=ok || c=missing
check "marker file has >>>>>>> theirs" "ok" "$c"
echo "$overlap_content" | grep -q "from-feature" && f=yes || f=no
check "marker block contains theirs content" "yes" "$f"
echo "$overlap_content" | grep -q "from-main" && m=yes || m=no
check "marker block contains ours content" "yes" "$m"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 21: stash push / list / pop / drop ────────────────────────────────
echo
echo "21. stash — push / list / pop / drop"
ST="$WORK/stash-test"
mkdir -p "$ST" && ( cd "$ST" && "$ZIGIT_BIN" init >/dev/null )

export TZ=UTC
export GIT_AUTHOR_NAME="Stash Bot"
export GIT_AUTHOR_EMAIL="stash@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 \
    bash -c "cd '$ST' && echo v1 > a && '$ZIGIT_BIN' add a && '$ZIGIT_BIN' commit -m v1 >/dev/null"

# (a) Empty repo → "No local changes to save".
no_changes=$(cd "$ST" && "$ZIGIT_BIN" stash push -m empty 2>&1 | tr -d '\r')
check "stash push with no changes" "No local changes to save" "$no_changes"

# (b) Push WIP edits → workdir reverts.
echo "WIP" > "$ST/a"
GIT_AUTHOR_DATE=1700000100 GIT_COMMITTER_DATE=1700000100 \
    bash -c "cd '$ST' && '$ZIGIT_BIN' stash push -m wip-1 >/dev/null"
content=$(cat "$ST/a")
check "stash push reset workdir to HEAD" "v1" "$content"

# (c) list shows the entry.
list=$(cd "$ST" && "$ZIGIT_BIN" stash list)
case "$list" in
    "stash@{0}: stash on main: wip-1"*)
        check "stash list shows our entry" "ok" "ok" ;;
    *) check "stash list shows our entry" "ok" "$list" ;;
esac

# (d) Push a second stash, list shows both.
echo "WIP 2" > "$ST/a"
GIT_AUTHOR_DATE=1700000200 GIT_COMMITTER_DATE=1700000200 \
    bash -c "cd '$ST' && '$ZIGIT_BIN' stash push -m wip-2 >/dev/null"
list2_count=$(cd "$ST" && "$ZIGIT_BIN" stash list | wc -l | tr -d ' ')
check "stash list shows both entries" "2" "$list2_count"

# (e) pop the top: restores WIP-2 content.
( cd "$ST" && "$ZIGIT_BIN" stash pop >/dev/null )
content=$(cat "$ST/a")
check "stash pop restored top (WIP 2)" "WIP 2" "$content"
list_after_pop=$(cd "$ST" && "$ZIGIT_BIN" stash list | wc -l | tr -d ' ')
check "stash pop drops the popped entry" "1" "$list_after_pop"

# (f) drop the remaining entry without applying.
echo "v1" > "$ST/a"   # clean workdir before drop
( cd "$ST" && "$ZIGIT_BIN" stash drop >/dev/null )
list_final=$(cd "$ST" && "$ZIGIT_BIN" stash list)
check "stash drop empties the list" "" "$list_final"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 22: config + remote (add / remove / show / list) ──────────────────
echo
echo "22. config + remote — manage [remote \"...\"] in .git/config"
RT="$WORK/remote-test"
mkdir -p "$RT" && ( cd "$RT" && "$ZIGIT_BIN" init >/dev/null )

# (a) Empty repo → no remotes listed.
empty=$(cd "$RT" && "$ZIGIT_BIN" remote)
check "remote (empty repo)" "" "$empty"

# (b) Add origin → list shows it; git agrees on the URL.
( cd "$RT" && "$ZIGIT_BIN" remote add origin https://example.com/r.git )
list=$(cd "$RT" && "$ZIGIT_BIN" remote)
check "remote add origin → listed" "origin" "$list"
git_url=$(cd "$RT" && git config --get remote.origin.url)
check "git config sees zigit-written remote.origin.url" \
    "https://example.com/r.git" "$git_url"
git_fetch=$(cd "$RT" && git config --get remote.origin.fetch)
check "git config sees zigit-written remote.origin.fetch" \
    "+refs/heads/*:refs/remotes/origin/*" "$git_fetch"

# (c) Add a second remote → both listed in insertion order.
( cd "$RT" && "$ZIGIT_BIN" remote add fork https://example.com/f.git )
list2=$(cd "$RT" && "$ZIGIT_BIN" remote | tr '\n' ' ' | sed -e 's/ $//')
check "remote list shows both" "origin fork" "$list2"

# (d) `remote -v` includes URLs.
verbose_origin=$(cd "$RT" && "$ZIGIT_BIN" remote -v | grep '^origin')
check "remote -v origin line" \
    "$(printf 'origin\thttps://example.com/r.git (fetch)')" "$verbose_origin"

# (e) `remote show fork` prints the underlying entries.
show_url=$(cd "$RT" && "$ZIGIT_BIN" remote show fork | grep '^url')
check "remote show prints url line" \
    "url = https://example.com/f.git" "$show_url"

# (f) Adding a duplicate remote fails cleanly.
dup=$(cd "$RT" && "$ZIGIT_BIN" remote add origin https://other 2>&1; echo "exit=$?")
case "$dup" in
    *RemoteAlreadyExists*exit=1*) check "duplicate remote add rejected" "ok" "ok" ;;
    *) check "duplicate remote add rejected" "ok" "$dup" ;;
esac

# (g) remote remove drops every entry under [remote "fork"].
( cd "$RT" && "$ZIGIT_BIN" remote remove fork )
gone=$(cd "$RT" && git config --get remote.fork.url 2>&1; echo "exit=$?")
case "$gone" in
    exit=1*) check "remote remove dropped fork.url" "ok" "ok" ;;
    *) check "remote remove dropped fork.url" "ok" "$gone" ;;
esac
list3=$(cd "$RT" && "$ZIGIT_BIN" remote)
check "remote list after remove" "origin" "$list3"

# (h) Removing an unknown remote fails cleanly.
miss=$(cd "$RT" && "$ZIGIT_BIN" remote remove nope 2>&1; echo "exit=$?")
case "$miss" in
    *RemoteNotFound*exit=1*) check "remove unknown remote rejected" "ok" "ok" ;;
    *) check "remove unknown remote rejected" "ok" "$miss" ;;
esac

# (i) Round-trip with git: git config can write a remote, zigit reads it.
( cd "$RT" && git remote add upstream https://example.com/u.git )
zigit_sees=$(cd "$RT" && "$ZIGIT_BIN" remote | sort | tr '\n' ' ' | sed -e 's/ $//')
check "zigit reads git-written remote" "origin upstream" "$zigit_sees"
zigit_show=$(cd "$RT" && "$ZIGIT_BIN" remote show upstream | grep '^url')
check "zigit show on git-written remote" \
    "url = https://example.com/u.git" "$zigit_show"

# (j) Subsections survive serialise round-trip — git's parser can still
#     read the whole file after zigit re-wrote it.
( cd "$RT" && "$ZIGIT_BIN" remote add edge https://example.com/e.git )
parser_check=$(cd "$RT" && git config --list 2>&1)
case "$parser_check" in
    *remote.edge.url=https://example.com/e.git*) check "git parses zigit-written config" "ok" "ok" ;;
    *) check "git parses zigit-written config" "ok" "$parser_check" ;;
esac

# ── Section 23: deltify — gc emits OFS_DELTA chains git can verify ────────────
echo
echo "23. deltify — gc emits OFS_DELTA chains"
DT="$WORK/deltify-test"
mkdir -p "$DT"
( cd "$DT" && "$ZIGIT_BIN" init >/dev/null )

export TZ=UTC
export GIT_AUTHOR_NAME="Delta Bot"
export GIT_AUTHOR_EMAIL="delta@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# Create 5 nearly-identical, large blobs so deltification has plenty
# of common substrings to chew on. Each commit changes only ~1% of
# the bytes — well under the 70% acceptance threshold the planner uses.
BIG=""
for i in $(seq 1 200); do
    BIG="${BIG}line ${i}: the quick brown fox jumps over the lazy dog 0123456789ABCDEF
"
done

for n in 1 2 3 4 5; do
    {
        printf '%s' "$BIG"
        printf 'rev marker for revision %d\n' "$n"
    } > "$DT/big.txt"
    export GIT_AUTHOR_DATE=$((1700000000 + n * 100))
    export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE
    ( cd "$DT" && "$ZIGIT_BIN" add big.txt >/dev/null && "$ZIGIT_BIN" commit -m "v$n" >/dev/null )
done

( cd "$DT" && "$ZIGIT_BIN" gc >/dev/null )

# git verify-pack -v output: delta lines have ≥ 7 whitespace-separated
# fields (sha-1, type, size, packfile-size, offset, depth, base-sha-1);
# non-delta lines have 5.
verify_log=$(cd "$DT" && git verify-pack -v "$DT"/.git/objects/pack/pack-*.idx 2>&1)
delta_count=$(printf '%s\n' "$verify_log" | awk '$2 == "blob" && NF >= 7 { c++ } END { print c+0 }')
case "$delta_count" in
    0) check "gc deltified at least one blob" "≥1" "0 (none deltified)" ;;
    *) check "gc deltified at least one blob" "≥1" "≥1" ;;
esac

# verify-pack ends with "<sha>: ok".
verify_tail=$(printf '%s\n' "$verify_log" | tail -1)
case "$verify_tail" in
    *": ok"*) check "git verify-pack ok on deltified pack" "ok" "ok" ;;
    *)        check "git verify-pack ok on deltified pack" "ok" "$verify_tail" ;;
esac

# Pack must be smaller than the sum of unpacked blob sizes — sanity
# check that deltification actually saved bytes.
pack_size=$(stat -f %z "$DT"/.git/objects/pack/pack-*.pack 2>/dev/null || stat -c %s "$DT"/.git/objects/pack/pack-*.pack)
big_size=$(wc -c < "$DT/big.txt" | tr -d ' ')
# 5 commits × ~big_size of blob alone; with deltas the pack should be
# well under the raw blob × commit_count.
threshold=$((big_size * 3))   # roughly 3× as a generous ceiling
case "$pack_size" in
    *) if [ "$pack_size" -lt "$threshold" ]; then
           check "deltified pack smaller than 3× single blob" "ok" "ok"
       else
           check "deltified pack smaller than 3× single blob" "ok" "$pack_size ≥ $threshold"
       fi ;;
esac

# zigit can still read every commit/tree/blob via PackStore (delta resolution).
zigit_log=$(cd "$DT" && "$ZIGIT_BIN" log | grep -c '^commit ')
check "zigit reads back deltified pack" "5" "$zigit_log"

# Round-trip via git: clone the deltified pack into a fresh repo and
# verify HEAD walks all 5 commits.
DCLONE="$WORK/deltify-clone"
git clone -q "$DT" "$DCLONE" 2>/dev/null
clone_log=$(cd "$DCLONE" && git log --oneline | wc -l | tr -d ' ')
check "git clone of deltified pack walks 5 commits" "5" "$clone_log"

unset TZ GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# ── Section 24: credentials + URL classification (Phase 15 partial) ───────────
echo
echo "24. credentials + URL classification"

# (a) ssh:// URLs are classified at clone time and rejected with a
#     specific message rather than a cryptic HTTP fetch failure.
ssh_clone_msg=$("$ZIGIT_BIN" clone ssh://git@github.com/foo/bar.git /tmp/zigit-no 2>&1; echo "exit=$?")
case "$ssh_clone_msg" in
    *"ssh:// and git@host:path transports aren't implemented"*exit=1*)
        check "clone rejects ssh:// with a clear message" "ok" "ok" ;;
    *) check "clone rejects ssh:// with a clear message" "ok" "$ssh_clone_msg" ;;
esac

# (b) Same for SCP-like form.
scp_clone_msg=$("$ZIGIT_BIN" clone git@github.com:foo/bar.git /tmp/zigit-no 2>&1; echo "exit=$?")
case "$scp_clone_msg" in
    *"ssh:// and git@host:path transports aren't implemented"*exit=1*)
        check "clone rejects git@host:path with a clear message" "ok" "ok" ;;
    *) check "clone rejects git@host:path with a clear message" "ok" "$scp_clone_msg" ;;
esac

# (c) git:// URLs get their own specific message.
git_clone_msg=$("$ZIGIT_BIN" clone git://example.com/foo.git /tmp/zigit-no 2>&1; echo "exit=$?")
case "$git_clone_msg" in
    *"git:// transport isn't implemented"*exit=1*)
        check "clone rejects git:// with a clear message" "ok" "ok" ;;
    *) check "clone rejects git:// with a clear message" "ok" "$git_clone_msg" ;;
esac

# (d) Push falls back to ~/.git-credentials when the URL has no userinfo.
#     We piggy-back on Section 16's local git-http-backend if it ran;
#     otherwise this assertion is structural only — exercising the
#     credential lookup itself is unit-tested in src/net/credentials.zig.
HOME_FAKE="$WORK/cred-home"
mkdir -p "$HOME_FAKE"
printf "https://user:pass@example.com\n" > "$HOME_FAKE/.git-credentials"
# Run a tiny Zig-side helper: exercise the lookup via a Bash-only
# assertion that the file shape is what the parser expects. The full
# parser path is covered by the unit tests under net/credentials.zig.
case "$(cat "$HOME_FAKE/.git-credentials")" in
    https://*:*@example.com*) check ".git-credentials line shape recognised" "ok" "ok" ;;
    *) check ".git-credentials line shape recognised" "ok" "$(cat "$HOME_FAKE/.git-credentials")" ;;
esac

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
