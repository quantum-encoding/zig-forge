"""pypdf: read a form's fields, or fill one as an incremental update, or fill
and AES-256 encrypt it (empty user password). The fill modes also write
<out>.expected.json: what pypdf reads back from the saved file, in the reader's
value shapes (text -> string, left out when unset; checkbox -> true/false).

  pypdf_forms.py read <in.pdf>
  pypdf_forms.py incremental <in.pdf> <out.pdf>
  pypdf_forms.py encrypted <in.pdf> <out.pdf>
"""
import json
import sys

from pypdf import PdfReader, PdfWriter
from pypdf.generic import NameObject

FILLS = {
    "c3_zs": "0.51",
    "p2_note": "Filled by pypdf – £7",
    "electrician": "",
}
CHECKS = {"rcd_tested": "/Yes", "ir_ok": "/Off"}


def read(path):
    fields = PdfReader(path).get_fields() or {}
    out = {}
    for name, f in fields.items():
        out[name] = {"ft": f.get("/FT"), "v": f.get("/V")}
    print(json.dumps(out, ensure_ascii=False, default=str, indent=1))


def expected(path):
    shapes = {}
    for name, f in (PdfReader(path).get_fields() or {}).items():
        v = f.get("/V")
        if f.get("/FT") == "/Btn":
            shapes[name] = v is not None and v != "/Off"
        elif v is not None:
            shapes[name] = str(v)
    with open(path.removesuffix(".pdf") + ".expected.json", "w", encoding="utf-8") as fh:
        json.dump(shapes, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def fill(writer):
    for page in writer.pages:
        writer.update_page_form_field_values(page, {**FILLS, **CHECKS}, auto_regenerate=False)


def main():
    mode, src = sys.argv[1], sys.argv[2]
    if mode == "read":
        return read(src)
    dst = sys.argv[3]
    if mode == "incremental":
        writer = PdfWriter(src, incremental=True)
        fill(writer)
    elif mode == "encrypted":
        writer = PdfWriter(clone_from=src)
        fill(writer)
        writer.encrypt(user_password="", owner_password="owner-pw", algorithm="AES-256")
    else:
        raise SystemExit("unknown mode")
    with open(dst, "wb") as fh:
        writer.write(fh)
    read(dst)
    expected(dst)


main()
