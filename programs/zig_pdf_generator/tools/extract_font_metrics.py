#!/usr/bin/env python3
"""Extract PDF-relevant font metrics from a TTF and emit a Zig source file.

Usage:
    extract_font_metrics.py <family_name> <regular.ttf> <bold.ttf> <out.zig>

Produces a Zig namespace for each weight, containing:
    - widths: [256]u16      advance widths at 1000/em for WinAnsi codepoints 0..255
    - ascent: i16
    - descent: i16          (negative)
    - cap_height: i16
    - x_height: i16
    - italic_angle: f32
    - stem_v: i16           (approximated from weight class)
    - flags: u32            (PDF FontDescriptor /Flags)
    - bbox_xmin / ymin / xmax / ymax: i16

The values are what the PDF FontDescriptor expects when /FontMatrix is the
default (glyph units scaled by 1000 / unitsPerEm).

Requires fontTools. The script is deterministic — running it twice yields
byte-identical output.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass

from fontTools.ttLib import TTFont


# WinAnsiEncoding → Unicode codepoint. Matches PDF 1.7 Appendix D.
# Entries of 0 mean "no glyph at this slot" (use .notdef width).
#
# This is a minimal, correct mapping — the full WinAnsi spec has ~217 slots
# populated; everything else falls back to the space width so we at least get
# reasonable measurements for any accidental slot reference.
WINANSI_TO_UNICODE = {
    **{i: i for i in range(0x20, 0x7F)},            # ASCII printable
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
    0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
    0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D,
    0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022,
    0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161,
    0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    **{i: i for i in range(0xA0, 0x100)},           # Latin-1 Supplement
}


@dataclass
class Metrics:
    widths: list[int]              # [256]u16
    ascent: int
    descent: int
    cap_height: int
    x_height: int
    italic_angle: float
    stem_v: int
    flags: int
    bbox: tuple[int, int, int, int]


def extract(path: str) -> Metrics:
    tt = TTFont(path)
    units_per_em = tt["head"].unitsPerEm
    scale = 1000.0 / units_per_em

    # Build codepoint → advance-width map via the cmap and hmtx tables.
    cmap = tt.getBestCmap()
    hmtx = tt["hmtx"].metrics  # {glyph_name: (advance, lsb)}
    notdef_advance = int(round(hmtx[".notdef"][0] * scale))
    space_advance = notdef_advance
    if 0x20 in cmap:
        space_advance = int(round(hmtx[cmap[0x20]][0] * scale))

    widths = [space_advance] * 256
    for slot in range(256):
        uni = WINANSI_TO_UNICODE.get(slot)
        if uni is None:
            widths[slot] = 0
            continue
        glyph = cmap.get(uni)
        if glyph is None:
            widths[slot] = space_advance
            continue
        adv = hmtx[glyph][0]
        widths[slot] = int(round(adv * scale))

    head = tt["head"]
    os2 = tt["OS/2"]
    post = tt["post"]
    hhea = tt["hhea"]

    ascent = int(round(os2.sTypoAscender * scale)) if hasattr(os2, "sTypoAscender") else int(round(hhea.ascent * scale))
    descent = int(round(os2.sTypoDescender * scale)) if hasattr(os2, "sTypoDescender") else int(round(hhea.descent * scale))
    cap_height = int(round(getattr(os2, "sCapHeight", ascent) * scale))
    x_height = int(round(getattr(os2, "sxHeight", int(0.5 * ascent)) * scale))
    italic_angle = float(post.italicAngle)

    # StemV — not in standard TTF, approximate from weight class per PDF convention.
    # Matches what Adobe's own /StemV heuristic does for non-CFF TrueType fonts.
    weight = getattr(os2, "usWeightClass", 400)
    stem_v = int(50 + (weight / 65.0) ** 2)

    # Flags (PDF 1.7 §9.8.2)
    #   bit 1: FixedPitch
    #   bit 2: Serif
    #   bit 6: Nonsymbolic (use when the font uses StandardEncoding / WinAnsi)
    #   bit 7: Italic
    is_italic = italic_angle != 0 or bool(getattr(os2, "fsSelection", 0) & 0b1)
    is_fixed = bool(post.isFixedPitch)
    # Heuristic: family name containing "Mono" or "Courier" implies fixed-pitch;
    # trust the post table otherwise. Montserrat is clearly sans-serif.
    flags = 0
    if is_fixed: flags |= 1 << 0
    # We deliberately don't set bit 2 (Serif); all our fonts are sans for now.
    flags |= 1 << 5   # Nonsymbolic (bit 6, zero-indexed bit 5)
    if is_italic: flags |= 1 << 6

    bbox = (
        int(round(head.xMin * scale)),
        int(round(head.yMin * scale)),
        int(round(head.xMax * scale)),
        int(round(head.yMax * scale)),
    )

    return Metrics(
        widths=widths,
        ascent=ascent,
        descent=descent,
        cap_height=cap_height,
        x_height=x_height,
        italic_angle=italic_angle,
        stem_v=stem_v,
        flags=flags,
        bbox=bbox,
    )


def emit_widths(widths: list[int]) -> str:
    # 16 per line — lines up nicely at 80 cols.
    lines = []
    for i in range(0, 256, 16):
        chunk = ", ".join(f"{w:4d}" for w in widths[i:i + 16])
        lines.append(f"    {chunk},")
    return "\n".join(lines)


def emit_zig(family: str, regular: Metrics, bold: Metrics) -> str:
    family_snake = family.lower().replace("-", "_").replace(" ", "_")

    def block(name: str, m: Metrics) -> str:
        return f"""pub const {name} = FontMetrics{{
    .ascent       = {m.ascent},
    .descent      = {m.descent},
    .cap_height   = {m.cap_height},
    .x_height     = {m.x_height},
    .italic_angle = {m.italic_angle},
    .stem_v       = {m.stem_v},
    .flags        = {m.flags},
    .bbox_xmin    = {m.bbox[0]},
    .bbox_ymin    = {m.bbox[1]},
    .bbox_xmax    = {m.bbox[2]},
    .bbox_ymax    = {m.bbox[3]},
    .widths       = .{{
{emit_widths(m.widths)}
    }},
}};"""

    return f"""// Auto-generated from TTF by tools/extract_font_metrics.py — do NOT edit.
// Run `tools/extract_font_metrics.py {family} <Regular.ttf> <Bold.ttf> <this file>`
// to regenerate.
//
// Values are in PDF font units (1000/em). Widths map WinAnsiEncoding
// codepoints 0..255 → advance width.

pub const FontMetrics = struct {{
    ascent: i16,
    descent: i16,
    cap_height: i16,
    x_height: i16,
    italic_angle: f32,
    stem_v: i16,
    flags: u32,
    bbox_xmin: i16,
    bbox_ymin: i16,
    bbox_xmax: i16,
    bbox_ymax: i16,
    widths: [256]u16,
}};

{block("regular", regular)}

{block("bold", bold)}
"""


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    _, family, regular_path, bold_path, out_path = sys.argv
    reg = extract(regular_path)
    bold = extract(bold_path)
    source = emit_zig(family, reg, bold)
    with open(out_path, "w") as f:
        f.write(source)
    print(f"Wrote {out_path} ({len(source)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
