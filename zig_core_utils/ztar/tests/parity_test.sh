#!/usr/bin/env bash
#
# GNU/POSIX tar parity harness for ztar.
#
# EXTERNAL ANCHOR: every check below diffs ztar against the *system* tar
# (libarchive/bsdtar on macOS, GNU tar on Linux) or against documented
# GNU tar / libarchive behavior — never against ztar's own prior output.
# This is the cross-implementation anchor required by zig-forge/CLAUDE.md:
# an archive ztar creates must be readable by a foreign tar, and an archive a
# foreign tar creates must be readable by ztar, byte-for-byte on content.
#
# Run by `zig build test`. Argument $1 is the freshly-built ztar binary.
#
set -u

ZTAR="${1:?usage: parity_test.sh <path-to-ztar>}"
# The build passes a path relative to the project root; resolve it to an
# absolute path now, because we cd into a temp dir below.
case "$ZTAR" in
    /*) : ;;
    *)  ZTAR="$(cd "$(dirname "$ZTAR")" && pwd)/$(basename "$ZTAR")" ;;
esac
if [ ! -x "$ZTAR" ]; then echo "ztar binary not found/executable: $ZTAR"; exit 1; fi
# System tar: prefer GNU tar / gtar if present, else the platform tar (bsdtar).
SYSTAR=""
for cand in gtar /opt/homebrew/opt/coreutils/libexec/gnubin/tar /opt/homebrew/bin/gtar /usr/bin/tar tar; do
    if command -v "$cand" >/dev/null 2>&1; then SYSTAR="$(command -v "$cand")"; break; fi
done
if [ -z "$SYSTAR" ]; then echo "SKIP: no system tar found"; exit 0; fi

echo "ztar   = $ZTAR"
echo "systar = $SYSTAR  ($("$SYSTAR" --version 2>&1 | head -1))"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ztar-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

fail=0
pass=0
note() { printf '  %s\n' "$*"; }
ok()   { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. ztar CREATE (uncompressed) must be readable + correct via the system tar.
#    This is the regression test for the macOS struct-stat ABI bug: a corrupt
#    size/mode field made the system tar reject the archive ("Truncated input").
# ---------------------------------------------------------------------------
mkdir -p src1/sub
printf 'hello world!' > src1/a.txt
printf 'second file\nwith two lines\n' > src1/sub/b.txt
"$ZTAR" -cf t1.tar src1
if [ $? -ne 0 ]; then bad "create uncompressed (exit)"; else
    mkdir -p out1
    if (cd out1 && "$SYSTAR" -xf ../t1.tar) 2>err1.txt; then
        if cmp -s src1/a.txt out1/src1/a.txt && cmp -s src1/sub/b.txt out1/src1/sub/b.txt; then
            ok "ztar create -> system tar extract: content matches"
        else
            bad "ztar create -> system tar extract: content DIFFERS"
        fi
    else
        bad "system tar could not extract ztar's archive"; note "$(cat err1.txt)"
    fi
fi

# ---------------------------------------------------------------------------
# 2. ztar GZIP create must be a valid gzip stream (RFC 1952) — regression test
#    for the unfinalized deflate stream. Validate with the system gzip AND the
#    system tar's own gzip reader.
# ---------------------------------------------------------------------------
"$ZTAR" -czf t2.tar.gz src1
if [ $? -ne 0 ]; then bad "gzip create (exit)"; else
    if gzip -t t2.tar.gz 2>gzerr.txt; then ok "ztar gzip output passes 'gzip -t'"
    else bad "ztar gzip output fails 'gzip -t' (truncated stream)"; note "$(cat gzerr.txt)"; fi
    mkdir -p out2
    if (cd out2 && "$SYSTAR" -xzf ../t2.tar.gz) 2>err2.txt; then
        if cmp -s src1/a.txt out2/src1/a.txt; then ok "system tar reads ztar's .tar.gz: content matches"
        else bad "system tar reads ztar's .tar.gz: content DIFFERS"; fi
    else
        bad "system tar could not extract ztar's .tar.gz"; note "$(cat err2.txt)"
    fi
fi

# ---------------------------------------------------------------------------
# 3. ztar must EXTRACT a gzip archive produced by the system tar (read side).
# ---------------------------------------------------------------------------
"$SYSTAR" -czf sys.tar.gz src1
mkdir -p out3
if (cd out3 && "$ZTAR" -xzf ../sys.tar.gz) 2>err3.txt; then
    if cmp -s src1/sub/b.txt out3/src1/sub/b.txt; then ok "ztar extracts system tar's .tar.gz: content matches"
    else bad "ztar extracts system tar's .tar.gz: content DIFFERS"; fi
else
    bad "ztar could not extract system tar's .tar.gz"; note "$(cat err3.txt)"
fi

# ---------------------------------------------------------------------------
# 4. Unsupported compression must HARD-ERROR, not silently write an
#    uncompressed tar under a compressed name (documented degradation bug).
# ---------------------------------------------------------------------------
if "$ZTAR" -cjf t4.tar.bz2 src1 2>bzerr.txt; then
    bad "ztar -cjf should have failed but exited 0"
else
    # Must not have produced a readable/mislabeled archive that 'file' calls a plain tar.
    if [ -f t4.tar.bz2 ] && file t4.tar.bz2 | grep -qi 'tar archive'; then
        bad "ztar -cjf produced a mislabeled uncompressed tar"
    else
        ok "ztar refuses unsupported bzip2 compression (no mislabeled output)"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Path traversal: a member named "../escaped" must be refused and MUST NOT
#    be written outside the extraction directory. Anchor: GNU tar / libarchive
#    refuse "Path contains '..'" by default (verified: the system tar here also
#    refuses the exact same crafted archive).
# ---------------------------------------------------------------------------
python3 - <<'PY'
def hdr(name, size, typ=b'0', link=''):
    h=bytearray(512); nb=name.encode(); h[0:len(nb)]=nb
    def octf(off,ln,val): h[off:off+ln]=("%0*o"%(ln-1,val)).encode()+b'\0'
    octf(100,8,0o644); octf(108,8,0); octf(116,8,0); octf(124,12,size); octf(136,12,0)
    h[156]=typ[0]
    if link:
        lb=link.encode(); h[157:157+len(lb)]=lb
    h[257:263]=b'ustar\0'; h[263:265]=b'00'
    for i in range(148,156): h[i]=0x20
    h[148:156]=("%06o"%sum(h)).encode()+b'\0 '
    return bytes(h)
def pad(d):
    r=len(d)%512; return d+(b'\0'*(512-r) if r else b'')
body=b'PWNED\n'
open('evil.tar','wb').write(hdr('../ztar_escaped.txt',len(body))+pad(body)+b'\0'*1024)
# symlink to an absolute target, then a member that would write through it
sym=hdr('link', 0, b'2', '/tmp/ztar_should_not_write')
sbody=b'through\n'
open('symevil.tar','wb').write(sym+hdr('link/x',len(sbody))+pad(sbody)+b'\0'*1024)
PY
if [ ! -f evil.tar ]; then
    note "python3 unavailable; skipping crafted-archive security checks"
else
    mkdir -p out5 && rm -f "$WORK/ztar_escaped.txt"
    (cd out5 && "$ZTAR" -xf ../evil.tar) >/dev/null 2>&1
    rc=$?
    # A successful traversal writes ../ztar_escaped.txt, i.e. into $WORK (the
    # parent of out5). That file existing is the smoking gun.
    if [ -e "$WORK/ztar_escaped.txt" ]; then
        bad "path traversal: ../ztar_escaped.txt escaped the extraction dir!"
        rm -f "$WORK/ztar_escaped.txt"
    elif [ "$rc" -eq 0 ]; then
        bad "path traversal: ztar exited 0 (should refuse with non-zero)"
    else
        ok "path traversal '..' refused, nothing written outside dest (exit $rc)"
    fi

    # 6. Symlink safety: absolute symlink target must be refused; the target
    #    file must never be created.
    rm -f /tmp/ztar_should_not_write
    mkdir -p out6
    (cd out6 && "$ZTAR" -xf ../symevil.tar) >/dev/null 2>&1
    rc=$?
    if [ -e /tmp/ztar_should_not_write ]; then
        bad "symlink attack: wrote through symlink to /tmp/ztar_should_not_write!"
        rm -f /tmp/ztar_should_not_write
    else
        ok "symlink with absolute target refused, no out-of-tree write (exit $rc)"
    fi
fi

# ---------------------------------------------------------------------------
# 7. USTAR name/prefix split, both directions, anchored to the system tar:
#    (a) system tar creates a >100-byte path in ustar format; ztar must list
#        the FULL path (prefix+name join on read).
#    (b) ztar creates the same long path; the system tar must list the full
#        path (prefix split on write).
# ---------------------------------------------------------------------------
LONG="aaaaaaaaaa/bbbbbbbbbb/cccccccccc/dddddddddd/eeeeeeeeee/ffffffffff/gggggggggg/hhhhhhhhhh/iiiiiiiiii/jjjjjjjjjj/kkkkkkkkkk/leaf.txt"
mkdir -p "$(dirname "$LONG")"; printf 'deep' > "$LONG"
"$SYSTAR" --format=ustar -cf ustar_sys.tar "$LONG" 2>/dev/null
if [ -f ustar_sys.tar ]; then
    got="$("$ZTAR" -tf ustar_sys.tar 2>/dev/null | tr -d '\r')"
    if [ "$got" = "$LONG" ]; then ok "ztar reads USTAR prefix-split long path from system tar"
    else bad "ztar mis-read USTAR long path: got '$got'"; fi
else
    note "system tar would not emit ustar long path; skipping read-side check"
fi

"$ZTAR" -cf ustar_ztar.tar "$LONG" 2>/dev/null
gotb="$("$SYSTAR" -tf ustar_ztar.tar 2>/dev/null | sed 's:/$::' | tr -d '\r')"
if [ "$gotb" = "$LONG" ]; then ok "system tar reads ztar's USTAR prefix-split long path"
else bad "system tar mis-read ztar's long path: got '$gotb'"; fi

# ---------------------------------------------------------------------------
# 8. Corrupt / non-tar input to -t must error, not print garbage member names.
# ---------------------------------------------------------------------------
head -c 4096 /dev/urandom > garbage.bin
if "$ZTAR" -tf garbage.bin >garbage.out 2>/dev/null; then
    bad "ztar -tf on garbage exited 0 (should error)"
else
    if [ -s garbage.out ]; then bad "ztar -tf on garbage printed member names"
    else ok "ztar -tf on garbage errors cleanly, no bogus listing"; fi
fi

echo "-------------------------------------------------"
echo "parity: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
