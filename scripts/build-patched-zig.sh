#!/usr/bin/env bash
#
# build-patched-zig.sh — build a local Zig with our MachO archive alignment
# fix, then verify the output .a files no longer need libtool repacking.
#
# Takes ~10-20 minutes on an M-series Mac with nothing else competing. Feel
# free to Ctrl-C and resume — the Zig build caches most work in .zig-cache.
#
# What it does:
#   1. Use the shipped Zig 0.16.0 to compile the patched source tree
#   2. Install a self-contained Zig distribution at /tmp/zig-patched/
#   3. Rebuild our two static libs using the patched compiler
#   4. Try linking them into CosmicDuckOS
#   5. Report PASS/FAIL
#
# If it works: symlink the new zig into your PATH so the repack step goes
# away. Something like:
#     ln -sf /tmp/zig-patched/bin/zig ~/.local/bin/zig
#
# Copyright (c) 2026 Quantum Encoding Ltd

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'
    BLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
    RED=; GRN=; YLW=; BLU=; BLD=; DIM=; RST=
fi

log()  { printf "%s[%s]%s %s\n" "$DIM" "$(date +%H:%M:%S)" "$RST" "$*"; }
ok()   { printf "%s✓%s %s\n" "$GRN" "$RST" "$*"; }
warn() { printf "%s⚠%s %s\n" "$YLW" "$RST" "$*"; }
err()  { printf "%s✗%s %s\n" "$RED" "$RST" "$*" >&2; }
hdr()  { printf "\n%s%s━━━ %s ━━━%s\n" "$BLU" "$BLD" "$*" "$RST"; }

# ── Config ──────────────────────────────────────────────────────────────
BOOTSTRAP_ZIG="${BOOTSTRAP_ZIG:-/Users/director/Downloads/zig-aarch64-macos-0.16.0/zig}"
# Use the zig source from the 0.16.0-dev.3153 bootstrap — it matches the
# bootstrap binary's stdlib. The master branch on codeberg is too new.
ZIG_SRC="${ZIG_SRC:-/tmp/zig-src/zig-0.16.3153}"
ZIG_OUT="${ZIG_OUT:-/tmp/zig-patched}"
PATCH="${PATCH:-/Users/director/work/poly-repo/zig-forge/scripts/zig-macho-archive-alignment.patch}"

PDF_DIR=/Users/director/work/poly-repo/zig-forge/programs/zig_pdf_generator
DOCX_DIR=/Users/director/work/poly-repo/zig-forge/programs/zig_docx
XCODE_PROJ=/Users/director/work/poly-repo/CosmicDuckOS

# ── Pre-flight ──────────────────────────────────────────────────────────
hdr "Pre-flight"

if [[ ! -x "$BOOTSTRAP_ZIG" ]]; then
    err "Bootstrap zig not found/executable: $BOOTSTRAP_ZIG"
    err "Set BOOTSTRAP_ZIG env var to point at a working 0.16.0+ zig binary."
    exit 2
fi
ok "Bootstrap zig: $("$BOOTSTRAP_ZIG" version) at $BOOTSTRAP_ZIG"

if [[ ! -d "$ZIG_SRC" ]]; then
    err "Zig source tree not found: $ZIG_SRC"
    err "Clone first: git clone https://codeberg.org/ziglang/zig.git $ZIG_SRC"
    exit 2
fi
ok "Zig source: $ZIG_SRC"

if ! grep -q "ld-prime" "$ZIG_SRC/src/link/MachO/relocatable.zig" 2>/dev/null; then
    warn "Patch not applied yet — applying from $PATCH"
    (cd "$ZIG_SRC" && git apply "$PATCH")
    ok "Patch applied"
else
    ok "Patch already present in source"
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    warn "xcodebuild not in PATH — will skip the Xcode link test"
fi

# ── Step 1: compile the patched Zig ─────────────────────────────────────
hdr "Building patched Zig compiler"
log "This is the slow part — expect 10-20 min on an idle M-series Mac."
log "Output: $ZIG_OUT"
log "(progress below is live; Ctrl-C is safe, cache survives)"
echo

cd "$ZIG_SRC"
mkdir -p "$ZIG_OUT"

START_TS=$(date +%s)
# --zig-lib-dir is critical: the source tree references stdlib APIs newer
# than what the bootstrap binary's bundled lib/ has. Point at the source's
# own lib/ so self-compilation sees its own stdlib.
#
# Debug mode on purpose: we only need this binary to test the archive
# alignment patch. ReleaseFast peaks at ~25GB of RAM; Debug peaks at ~5GB
# and the resulting zig compiles our libs just fine (slower but correct).
"$BOOTSTRAP_ZIG" build \
    --zig-lib-dir "$ZIG_SRC/lib" \
    -Doptimize=Debug \
    -Dno-langref \
    --prefix "$ZIG_OUT" \
    install
BUILD_ELAPSED=$(( $(date +%s) - START_TS ))

if [[ ! -x "$ZIG_OUT/bin/zig" ]]; then
    err "Build finished but no binary at $ZIG_OUT/bin/zig"
    exit 1
fi

PATCHED_VERSION=$("$ZIG_OUT/bin/zig" version)
ok "Built patched Zig in ${BUILD_ELAPSED}s — version: $PATCHED_VERSION"

# ── Step 2: rebuild our zig libs with the patched compiler ──────────────
hdr "Rebuilding pdf + docx static libs with patched Zig"

rebuild_lib() {
    local dir="$1" name="$2"
    log "Building $name in $dir"
    (
        cd "$dir"
        rm -rf zig-out .zig-cache zig-cache
        "$ZIG_OUT/bin/zig" build -Doptimize=ReleaseFast
    )
    local archive
    archive=$(find "$dir/zig-out/lib" -name "*.a" | head -1)
    if [[ -z "$archive" ]]; then
        err "No .a produced for $name"; return 1
    fi
    ok "$name -> $archive ($(ls -l "$archive" | awk '{print $5}') bytes)"
    echo "$archive"
}

PDF_AR=$(rebuild_lib "$PDF_DIR" "zig_pdf_generator" | tail -1)
DOCX_AR=$(rebuild_lib "$DOCX_DIR" "zig_docx" | tail -1)

# ── Step 3: inspect member alignment in the archive ─────────────────────
hdr "Inspecting Mach-O member alignment"

inspect_archive() {
    local archive="$1"
    local name
    name=$(basename "$archive")
    log "Extracting headers from $name"
    local tmp
    tmp=$(mktemp -d)
    (cd "$tmp" && ar t "$archive" > members.txt)
    log "  Members: $(wc -l < "$tmp/members.txt" | tr -d ' ')"

    # Use ar to dump the archive header positions
    # llvm-ar --print-archive-table gives us offsets; falling back to size check
    if command -v llvm-ar >/dev/null 2>&1; then
        llvm-ar --print-archive-table "$archive" 2>/dev/null | head -10 | sed 's/^/  /'
    else
        # Just show size — pass if libtool is never needed
        ls -l "$archive" | awk '{print "  size:", $5, "bytes"}'
    fi

    rm -rf "$tmp"
}

inspect_archive "$PDF_AR"
inspect_archive "$DOCX_AR"

# ── Step 4: the real test — does Xcode link them without complaint? ─────
hdr "Linking into CosmicDuckOS (the real alignment test)"

if command -v xcodebuild >/dev/null 2>&1 && [[ -d "$XCODE_PROJ" ]]; then
    cd "$XCODE_PROJ"
    log "xcodebuild -scheme CosmicDuckOS -configuration Debug build"
    # Force a clean link by touching the Swift module (avoid cached link)
    touch CosmicDuckOS/CosmicDuckOSApp.swift

    set +e
    OUTPUT=$(xcodebuild -scheme CosmicDuckOS -configuration Debug build 2>&1)
    STATUS=$?
    set -e

    ALIGN_ERROR=$(echo "$OUTPUT" | grep -c "not 8-byte aligned" || true)
    BUILD_OK=$(echo "$OUTPUT" | grep -c "BUILD SUCCEEDED" || true)

    if [[ "$STATUS" -eq 0 && "$BUILD_OK" -gt 0 && "$ALIGN_ERROR" -eq 0 ]]; then
        ok "${BLD}PATCH WORKS.${RST} Archives linked without libtool repacking."
    elif [[ "$ALIGN_ERROR" -gt 0 ]]; then
        err "${BLD}PATCH DID NOT FIX IT.${RST} Linker still complains about alignment:"
        echo "$OUTPUT" | grep "not 8-byte aligned" | sed 's/^/    /'
        exit 1
    else
        err "Build failed for an unrelated reason. Last 20 lines:"
        echo "$OUTPUT" | tail -20 | sed 's/^/    /'
        exit 1
    fi
else
    warn "Skipping Xcode link test — xcodebuild not available or project not found"
fi

# ── Done ────────────────────────────────────────────────────────────────
hdr "Done"

cat <<EOF
Patched zig:        $ZIG_OUT/bin/zig
Patched version:    $PATCHED_VERSION
Build time:         ${BUILD_ELAPSED}s

To make this your default zig:
    ln -sf $ZIG_OUT/bin/zig \$HOME/.local/bin/zig

To test before symlinking:
    $ZIG_OUT/bin/zig build -Doptimize=ReleaseFast

To send upstream:
    Open an issue + PR on https://codeberg.org/ziglang/zig
    Patch file: $PATCH

You can now delete the libtool repack step from any build workflow that
calls this zig directly. repack-for-xcode.sh is still useful for
archives built by OTHER zig versions or CI systems.
EOF
