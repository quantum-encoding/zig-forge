#!/usr/bin/env python3
"""Regenerate the PNG fixtures src/stego_hostile_test.zig embeds.

Both come from Python's zlib (CPython links the reference zlib), so they are produced by
an implementation the Zig decoder's author did not write:

  zlib-bomb-64mib.zlib             64 MiB of zeros deflated at level 9 (~65 KB, ~1030:1).
                                   The campaign's finding #8 / E-2 input: before the decode
                                   budget, a PNG wrapping it cost 131 MB of allocations.
  png-gradient-64x64-filtered.png  64x64 RGB, pixel (x, y) = (x*4, y*4, (x+y)) mod 256,
                                   each row filtered with type y % 5 (None, Sub, Up,
                                   Average, Paeth), the stream compressed by zlib, chunk
                                   CRCs by zlib.crc32. The test recomputes the pixels from
                                   the formula, so it checks the unfilter against this
                                   encoder, not against itself.

Run from this directory:  python3 -I make_png_fixtures.py
"""
import struct
import zlib

open("zlib-bomb-64mib.zlib", "wb").write(zlib.compress(b"\0" * (64 << 20), 9))

W = H = 64
BPP = 3


def px(x, y):
    return bytes(((x * 4) & 0xFF, (y * 4) & 0xFF, (x + y) & 0xFF))


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)


rows = [b"".join(px(x, y) for x in range(W)) for y in range(H)]
raw = b""
for y in range(H):
    cur = rows[y]
    prev = rows[y - 1] if y > 0 else bytes(W * BPP)
    ft = y % 5
    out = bytearray()
    for i in range(W * BPP):
        a = cur[i - BPP] if i >= BPP else 0
        b = prev[i]
        c = prev[i - BPP] if i >= BPP else 0
        r = cur[i]
        if ft == 0:
            v = r
        elif ft == 1:
            v = r - a
        elif ft == 2:
            v = r - b
        elif ft == 3:
            v = r - ((a + b) >> 1)
        else:
            v = r - paeth(a, b, c)
        out.append(v & 0xFF)
    raw += bytes([ft]) + bytes(out)


def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))


png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b"")
)
open("png-gradient-64x64-filtered.png", "wb").write(png)
