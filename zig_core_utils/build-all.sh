#!/bin/bash
# Build all zig-coreutils with ReleaseFast optimization
# Usage: ./build-all.sh [--parallel N]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PARALLEL=4
if [[ "$1" == "--parallel" ]] && [[ -n "$2" ]]; then
    PARALLEL=$2
fi

# All utilities
utilities=(
    zarch zawk zb2sum zbackup zbase32 zbase64 zbasename zbasenc
    zcat zchcon zchgrp zchmod zchown zchroot zcksum zclip zcomm zcp
    zcsplit zcurl zcut zdate zdd zdf zdir zdircolors zdirname zdu
    zecho zenv zexpand zexpr zfactor zfalse zfind zfmt zfold zfree
    zgrep zgroups zgzip zhashsum zhead zhostid zhostname zid zinstall
    zjoin zjq zkill zlink zln zlogname zls zmd5sum zmkdir zmkfifo
    zmknod zmktemp zmore zmv znice znl znohup znproc znumfmt zod
    zpaste zpathchk zpgrep zping zpinky zpkill zpr zprintenv zprintf
    zps zptx zpwd zreadlink zrealpath zregex zrm zrmdir zruncon zsed
    zseq zsha1sum zsha256sum zsha512sum zshred zshuf zsleep zsort
    zsplit zstat zstdbuf zstty zsudo zsum zsync zsys ztac ztail ztar
    ztee ztest ztime ztimeout ztouch ztr ztree ztrue ztruncate ztsort
    ztty zuname zunexpand zuniq zunlink zuptime zusers zvdir zwc zwho
    zwhoami zxargs zxz zyes zzstd
)

success=0
failed=()
total=${#utilities[@]}

echo "Building $total utilities with $PARALLEL parallel jobs..."
echo ""

build_util() {
    local util=$1
    if [[ -d "$util" ]]; then
        if (cd "$util" && zig build -Doptimize=ReleaseFast 2>/dev/null); then
            echo "  [OK] $util"
            return 0
        else
            echo "  [FAIL] $util"
            return 1
        fi
    fi
    return 1
}

export -f build_util

# Build in parallel
printf '%s\n' "${utilities[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'build_util "$@"' _ {}

# Count results
for util in "${utilities[@]}"; do
    if [[ -f "${util}/zig-out/bin/${util}" ]]; then
        ((success++))
    else
        failed+=("$util")
    fi
done

echo ""
echo "========================================="
echo "Build complete: $success/$total succeeded"
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Failed: ${failed[*]}"
fi
echo "========================================="

# Calculate total size
total_size=$(du -ch */zig-out/bin/* 2>/dev/null | tail -1 | cut -f1)
echo "Total binary size: $total_size"
