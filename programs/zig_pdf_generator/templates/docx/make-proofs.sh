#!/usr/bin/env bash
# Proofs for the Word bridges, written to output/docx-bridge/ (or $1).
#
#   1. statement-letter.html -> statement-letter.docx with macOS textutil (an
#      independent DOCX writer), then `pdf-gen docx-template` -> template JSON,
#      then a legend letter from it for two outcomes -> PDF + PNG.
#   2. A Word-style template built by hand (placeholders split across runs,
#      half of one in bold, curly quotes, a full-width brace, a zero-width
#      space, a tracked deletion, a transparent PNG logo) -> template JSON ->
#      legend letter PDF + PNG.
#   3. A Word-style plain letter (words split mid-run, space-only runs, a
#      list, a table, a link, the logo) -> `pdf-gen docx-letter` -> PDF + PNG.
#   4. The debt-recovery final demand (individual) -> .docx with a letterhead
#      image via --legend-letter-docx, checked with unzip -t, xmllint and
#      textutil (text extraction) and previewed with Quick Look.
#
# Needs macOS (textutil, qlmanage, swift for rasterising), python3, zig.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:-$root/output/docx-bridge}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
(cd "$root" && zig build -Doptimize=ReleaseSafe)
gen="$root/zig-out/bin/pdf-gen"
png() { swift "$root/templates/letters/pdf2png.swift" "$1" "$2" 120; }

# --- assets: a 360x96 logo with a transparent background (python, no deps) ---
python3 - "$out" <<'PY'
import sys, zlib, struct, zipfile, json
out = sys.argv[1]
def png(w, h, px):
    raw = b"".join(b"\x00" + bytes(px[y*w*4:(y+1)*w*4]) for y in range(h))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
w, h = 360, 96
px = bytearray(w*h*4)
for y in range(h):
    for x in range(w):
        i = (y*w + x)*4
        inside_bar = 8 <= y < 88 and 8 <= x < 88
        stripe = 100 <= x < 352 and (28 <= y < 40 or 52 <= y < 60 or 68 <= y < 74)
        if inside_bar:
            px[i:i+4] = bytes((31, 78, 121, 255))
        elif stripe:
            px[i:i+4] = bytes((31, 78, 121, 200 if y < 40 else 120))
        else:
            px[i:i+4] = bytes((255, 255, 255, 0))
logo = png(w, h, px)
open(f"{out}/logo.png", "wb").write(logo)

W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"'
body = """
<w:p><w:r><w:drawing><wp:inline><wp:extent cx="3429000" cy="914400"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rIdImg1"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
<w:p w:rsidR="00A1"><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Account statement</w:t></w:r></w:p>
<w:p w:rsidR="00A1"><w:r w:rsidRPr="00B2"><w:rPr><w:lang w:val="en-GB"/></w:rPr><w:t>Dear</w:t></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r><w:r><w:t>{CLI</w:t></w:r><w:proofErr w:type="spellStart"/><w:r w:rsidR="00C3"><w:rPr><w:b/></w:rPr><w:t>ENT_NA</w:t></w:r><w:proofErr w:type="spellEnd"/><w:bookmarkStart w:id="0" w:name="_GoBack"/><w:bookmarkEnd w:id="0"/><w:r><w:t>ME},</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">Invoice </w:t></w:r><w:r><w:t xml:space="preserve">{ INVOICE_NO }</w:t></w:r><w:r><w:t xml:space="preserve"> for the joinery at your home is </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>overdue</w:t></w:r><w:del w:id="1" w:author="A. Clerk"><w:r><w:delText> by a long way</w:delText></w:r></w:del><w:r><w:t>.</w:t></w:r></w:p>
<w:p><w:r><w:t>{?STATUS=</w:t></w:r><w:r><w:t>“part_paid”}</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">Thank you for your part payment. The balance now due is </w:t></w:r><w:r><w:t>{BALANCE|pl</w:t></w:r><w:r><w:t>ain}</w:t></w:r><w:r><w:t xml:space="preserve"> pounds.</w:t></w:r></w:p>
<w:p><w:r><w:t>{:}</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">Please pay the full amount by </w:t></w:r><w:r><w:t>｛PAY_​BY|long｝</w:t></w:r><w:r><w:t>.</w:t></w:r></w:p>
<w:p><w:r><w:t>{/}</w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Amount</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>Invoice {INVOICE_NO}</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>{BALANCE}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:r><w:t>If anything here looks wrong, call us on 07700 900123.</w:t></w:r></w:p>
"""
plain = """
<w:p><w:r><w:drawing><wp:inline><wp:extent cx="3429000" cy="914400"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rIdImg1"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
<w:p><w:r><w:t>Dear</w:t></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r><w:r><w:t>Ms Mor</w:t></w:r><w:proofErr w:type="spellStart"/><w:r w:rsidR="00D4"><w:t>gan,</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">Thank you for asking us to fit your wardrobes. We have now </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>finished the work</w:t></w:r><w:r><w:t xml:space="preserve">, and this letter confirms what was done and what happens next. The work was carried out by Har</w:t></w:r><w:r w:rsidR="00E5"><w:t>bourlight Joinery staff between 22 and 26 June 2026.</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Two double wardrobes with soft-close doors</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t xml:space="preserve">Internal shelving and a </w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>shoe rack</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Removal of all packaging</w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Amount</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>Wardrobes and fitting</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>£840.00</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>Shelving</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>£120.00</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:r><w:t xml:space="preserve">Our 12-month workmanship guarantee starts today. If anything needs adjusting, call us on 07700 900123 or see </w:t></w:r><w:hyperlink r:id="rIdLink1"><w:r><w:t>our aftercare page</w:t></w:r></w:hyperlink><w:r><w:t>.</w:t></w:r></w:p>
"""
def write_docx(path, body):
    doc = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:document ' + W + '><w:body>' + body + '<w:sectPr/></w:body></w:document>'
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        z.writestr("word/_rels/document.xml.rels", '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdImg1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/><Relationship Id="rIdLink1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://harbourlight.example/aftercare" TargetMode="External"/></Relationships>')
        z.writestr("word/media/image1.png", logo)
        z.writestr("word/document.xml", doc)
write_docx(f"{out}/word-letter.docx", plain)
write_docx(f"{out}/word-style-split-runs.docx", body)

frame = {"company_name": "Harbourlight Joinery Ltd", "company_address": "Unit 4, Example Trading Estate|Anytown|ZZ9 9ZZ",
         "sender_contact": "accounts@harbourlight.example · 07700 900123", "date": "15 September 2026", "reference": "HJ-ST-0421",
         "recipient_name": "Ms Alex Morgan", "recipient_address": "9 Linden Road|Southgate Vale|ZZ7 1GH",
         "subject": "Your account", "closing": "Yours sincerely,", "signature_name": "Sam Hollis",
         "signature_title": "Director, Harbourlight Joinery Ltd", "accent_hex": "#1f4e79"}
json.dump(frame, open(f"{out}/frame.json", "w"), indent=2, ensure_ascii=False)
PY

# --- 1. textutil-written Word template -> template -> legend letters ----------
textutil -convert docx -output "$out/statement-letter.docx" "$here/statement-letter.html"
"$gen" docx-template "$out/statement-letter.docx" -o "$out/statement-letter.template.json"
for status in paid unpaid; do
  python3 - "$out" "$status" <<'PY'
import sys, json
out, status = sys.argv[1], sys.argv[2]
t = json.load(open(f"{out}/statement-letter.template.json"))
legend = t["legend_toml"].replace('values = ["paid"]', 'values = ["paid", "unpaid"]')
frame = json.load(open(f"{out}/frame.json"))
frame["subject"] = "Account statement: invoice {INVOICE_NO}"
frame["recipient_name"] = "{CLIENT_NAME}"
frame["images"] = t["images"]
inp = {"legend_toml": legend, "template": t["template"], "letter": frame, "bindings": {
    "CLIENT_NAME": "Ms Alex Morgan", "PROJECT": "your fitted wardrobes", "STATEMENT_DATE": "2026-09-15",
    "INVOICE_NO": "INV-1043", "DUE_DATE": "2026-07-31", "BALANCE": "0.00" if status == "paid" else "960.00",
    "STATUS": status, "PAY_BY": "2026-09-29"}}
json.dump(inp, open(f"{out}/statement-letter--{status}.input.json", "w"), indent=2, ensure_ascii=False)
PY
  "$gen" --legend-letter "$out/statement-letter--$status.input.json" "$out/statement-letter--$status.pdf"
  png "$out/statement-letter--$status.pdf" "$out/render-statement-letter--$status"
done

# --- 2. hand-built Word-style template -> template JSON -> legend letter -------
"$gen" docx-template "$out/word-style-split-runs.docx" -o "$out/word-style-split-runs.template.json"
python3 - "$out" <<'PY'
import sys, json
out = sys.argv[1]
t = json.load(open(f"{out}/word-style-split-runs.template.json"))
frame = json.load(open(f"{out}/frame.json"))
frame["subject"] = "Invoice {INVOICE_NO}"
frame["images"] = t["images"]
inp = {"legend_toml": t["legend_toml"], "template": t["template"], "letter": frame, "bindings": {
    "CLIENT_NAME": "Ms Morgan", "INVOICE_NO": "INV-1043", "STATUS": "part_paid", "BALANCE": "480.00", "PAY_BY": "2026-09-29"}}
json.dump(inp, open(f"{out}/word-style-split-runs--part_paid.input.json", "w"), indent=2, ensure_ascii=False)
PY
"$gen" --legend-letter "$out/word-style-split-runs--part_paid.input.json" "$out/word-style-split-runs--part_paid.pdf"
png "$out/word-style-split-runs--part_paid.pdf" "$out/render-word-style-split-runs--part_paid"

# --- 3. plain Word-style letter -> letter PDF -----------------------------------
"$gen" docx-letter "$out/word-letter.docx" "$out/frame.json" -o "$out/word-letter.pdf"
png "$out/word-letter.pdf" "$out/render-word-letter"

# --- 4. legend letter -> .docx -------------------------------------------------
python3 - "$out" "$root" <<'PY'
import sys, json, base64
out, root = sys.argv[1], sys.argv[2]
pack = f"{root}/templates/letters"
stages = json.load(open(f"{pack}/stages.json"))
frame = json.load(open(f"{pack}/final-demand.letter.json"))
frame["letterhead_image"] = "data:image/png;base64," + base64.b64encode(open(f"{out}/logo.png", "rb").read()).decode()
inp = {"legend_toml": open(f"{pack}/debt-recovery.toml").read(), "template": open(f"{pack}/final-demand.tpl.md").read(),
       "scenario": "individual-unpaid", "bindings": {**stages["creditor"], **stages["stages"]["final-demand"]}, "letter": frame}
json.dump(inp, open(f"{out}/final-demand--individual-unpaid.input.json", "w"), indent=2, ensure_ascii=False)
PY
d="$out/final-demand--individual-unpaid.docx"
"$gen" --legend-letter-docx "$out/final-demand--individual-unpaid.input.json" "$d"
{
  echo "== unzip -t"; unzip -t "$d"
  echo "== xmllint (every XML part)"
  tmp="$(mktemp -d)"; unzip -q -o "$d" -d "$tmp"
  find "$tmp" -name "*.xml" -o -name "*.rels" | sort | while read -r f; do xmllint --noout "$f" && echo "ok ${f#$tmp/}"; done
  echo "== textutil -convert txt"; textutil -convert txt -stdout "$d"
} > "$out/final-demand--individual-unpaid.docx-check.txt" 2>&1
qlmanage -t -s 1200 -o "$out" "$d" >/dev/null 2>&1 && mv -f "$out/$(basename "$d").png" "$out/render-final-demand--individual-unpaid.docx-quicklook.png" || echo "Quick Look preview unavailable"
echo "proofs in $out"
