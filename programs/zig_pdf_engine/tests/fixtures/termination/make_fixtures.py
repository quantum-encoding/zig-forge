#!/usr/bin/env python3
"""Builds the synthetic PDFs behind src/tests/termination_tests.zig.

Each file isolates one construct that made pdf-text spin forever on real
documents (see docs/pdf-text-hang-classification.md). They are synthetic on
purpose: the documents the hangs were found in are a client's accounts.

The expected text is not taken from this engine. After writing each file the
script runs poppler's `pdftotext` over it and fails unless poppler reads the
same words, so the expectations in the Zig tests are anchored on an independent
implementation. Compression and ASCII85 come from CPython (zlib, base64).

    python3 make_fixtures.py        # rewrites the PDFs next to this script
"""
import base64, os, subprocess, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))


def build(objects, root=1):
    """objects: {num: bytes body}. Returns a PDF with a classic xref table."""
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for num in sorted(objects):
        offsets[num] = len(out)
        out += b"%d 0 obj\n" % num + objects[num] + b"\nendobj\n"
    xref_at = len(out)
    size = max(objects) + 1
    out += b"xref\n0 %d\n" % size
    out += b"0000000000 65535 f \n"
    for num in range(1, size):
        if num in offsets:
            out += b"%010d 00000 n \n" % offsets[num]
        else:
            out += b"0000000000 65535 f \n"
    out += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (size, root, xref_at)
    return bytes(out)


def stream(dict_body, data, eol=b"\n"):
    return b"<< " + dict_body + b" /Length %d >>\nstream\n" % len(data) + data + eol + b"endstream"


def helvetica_page(contents, parent=2):
    return (b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] "
            b"/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> "
            b"/Contents " % parent + contents + b" >>")


def cmap_bfrange_array():
    """A ToUnicode CMap whose bfrange array holds exactly one entry per code:
    what Qt, Skia and wkhtmltopdf write. Stored unfiltered, as Qt does."""
    text = "BFRANGE ARRAY TERMINATES"
    glyphs = sorted(set(text))
    code = {ch: i + 1 for i, ch in enumerate(glyphs)}
    array = " ".join("<%04X>" % ord(ch) for ch in glyphs)
    cmap = ("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
            "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
            "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
            "2 beginbfrange\n<0000> <0000> <0000>\n<0001> <%04X> [%s]\nendbfrange\n"
            "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
            % (len(glyphs), array)).encode()
    shown = "".join("%04X" % code[ch] for ch in text).encode()
    content = b"BT /F1 12 Tf 72 720 Td <" + shown + b"> Tj ET"
    return text, build({
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
           b"/Resources << /Font << /F1 4 0 R >> >> /Contents 8 0 R >>",
        4: b"<< /Type /Font /Subtype /Type0 /BaseFont /Fixture /Encoding /Identity-H "
           b"/DescendantFonts [5 0 R] /ToUnicode 7 0 R >>",
        5: b"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Fixture "
           b"/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
           b"/FontDescriptor 6 0 R /DW 600 >>",
        6: b"<< /Type /FontDescriptor /FontName /Fixture /Flags 4 /FontBBox [0 -200 1000 800] "
           b"/ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>",
        7: stream(b"", cmap),
        8: stream(b"", content),
    })


def stalls_a_lexer(encoded):
    """True when the still-encoded bytes, read as PDF syntax, hold a ')' that
    closes nothing: the byte a lexer must consume rather than return forever.
    This is what turned an unapplied filter into a hang instead of an empty
    page."""
    return b")" in encoded and b"(" not in encoded and b"%" not in encoded


def flate_ending_in(byte, template):
    """A content stream, and its zlib form chosen to END in `byte`. The last
    byte of a zlib stream is the low byte of the Adler-32 byte sum, so padding
    with spaces walks it through every value."""
    for a in range(65 * 26, 91 * 26):
        for pad in range(0, 256):
            text = template % (65 + a % 26, 65 + a // 26 % 26) + b" " * pad + b"\n"
            z = zlib.compress(text)
            if z[-1] == byte and stalls_a_lexer(z):
                return text, z
    raise SystemExit("no variant found")


def filter_array():
    """iText's shape: /Contents is an array, the body's /Filter is written as
    a one-element ARRAY, and the body's compressed bytes end in 0x0D so that a
    reader trimming EOLs off stream data destroys the zlib checksum."""
    body, z = flate_ending_in(0x0D, b"BT /F1 12 Tf 72 720 Td (FILTER ARRAY BODY %c%c) Tj ET")
    assert z[-1] == 0x0D
    words = body[body.index(b"(") + 1:body.index(b")")].decode()
    return words, build({
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        3: helvetica_page(b"[4 0 R 5 0 R 6 0 R]"),
        4: stream(b"/Filter /FlateDecode", zlib.compress(b"q\n")),
        5: b"<< /Filter [/FlateDecode] /Length %d >>\nstream\n" % len(z) + z + b"\nendstream",
        6: stream(b"/Filter /FlateDecode", zlib.compress(b"Q\n")),
    })


def filter_chain():
    """Oracle's PDF driver and ReportLab: [/ASCII85Decode /FlateDecode]."""
    words = "FILTER CHAIN ASCII85 THEN FLATE"
    for pad in range(0, 2000):
        # Varying the head of the stream varies every ASCII85 group after it.
        content = b"%d w\n" % pad + b"BT /F1 12 Tf 72 720 Td (" + words.encode() + b") Tj ET"
        a85 = base64.a85encode(zlib.compress(content), adobe=True)[2:]  # PDF has no leading <~
        if stalls_a_lexer(a85[:-2]):
            break
    else:
        raise SystemExit("no variant found")
    return words, build({
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        3: helvetica_page(b"4 0 R"),
        4: stream(b"/Filter [ /ASCII85Decode /FlateDecode ]", a85),
    })


def page_tree_lies():
    """/Count claims four billion pages and /Kids loops back to the root. One
    real page. A reader must neither loop /Count times nor follow the cycle."""
    words = "ONE REAL PAGE"
    content = b"BT /F1 12 Tf 72 720 Td (" + words.encode() + b") Tj ET"
    return words, build({
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: b"<< /Type /Pages /Kids [3 0 R 2 0 R 5 0 R] /Count 4000000000 >>",
        3: helvetica_page(b"4 0 R"),
        4: stream(b"", content),
        5: b"<< /Type /Pages /Parent 2 0 R /Kids [2 0 R 5 0 R] /Count 4000000000 >>",
    })


def xref_stream_zero_width():
    """A cross-reference STREAM whose /W is [0 0 0]: entries of no bytes, so
    the data never runs out and only /Index (four billion here) bounds the
    entry loop. There is no text to read; the file must be refused."""
    head = b"%PDF-1.5\n"
    body = b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
    at = len(head) + len(body)
    xref = (b"3 0 obj\n<< /Type /XRef /Size 4 /Root 1 0 R /W [0 0 0] /Index [0 4000000000] /Length 0 >>\n"
            b"stream\n\nendstream\nendobj\n")
    return None, head + body + xref + b"startxref\n%d\n%%%%EOF\n" % at


FIXTURES = {
    "cmap_bfrange_array.pdf": cmap_bfrange_array,
    "filter_array.pdf": filter_array,
    "filter_chain_a85_flate.pdf": filter_chain,
    "page_tree_lies.pdf": page_tree_lies,
    "xref_stream_zero_width.pdf": xref_stream_zero_width,
}

# poppler refuses to walk the cyclic page tree the same way twice; it is a
# termination fixture, and its words are checked by the engine test alone.
NOT_ANCHORED = {"page_tree_lies.pdf", "xref_stream_zero_width.pdf"}

if __name__ == "__main__":
    for name, make in FIXTURES.items():
        words, pdf = make()
        path = os.path.join(HERE, name)
        with open(path, "wb") as f:
            f.write(pdf)
        got = subprocess.run(["pdftotext", "-q", path, "-"], capture_output=True, timeout=30).stdout.decode()
        anchored = words is not None and " ".join(got.split()) == words
        if not anchored and name not in NOT_ANCHORED:
            sys.exit("%s: poppler read %r, expected %r" % (name, got, words))
        print("%-28s %5d bytes  %r  poppler:%s" % (name, len(pdf), words, "agrees" if anchored else "n/a"))
