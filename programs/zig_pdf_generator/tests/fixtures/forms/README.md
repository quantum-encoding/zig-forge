# Form-field fixtures

External anchors for `src/pdf_form_reader.zig`: PDFs whose bytes were written
by software this package did not write, each with the values that software
set in `<name>.expected.json`. `src/pdf_form_tests.zig` reads each PDF and
compares the result, in any order, with its expected file.

| Fixture | Written by | What it exercises |
|---|---|---|
| `pdfkit-filled.pdf` | Apple PDFKit (macOS 27.2, build 26B123), the framework Preview is built on, filling `review.pdf` through its widget API and saving | A full rewrite; text values as UTF-16BE inside literal strings; a ticked checkbox stored as `/V (Yes)` (a string, not a name); an unticked one stored by removing `/V` while its `/AS` stays `/Yes` |
| `pypdf-incremental.pdf` | pypdf 7.1.1, `PdfWriter(review.pdf, incremental=True)` | An incremental update: `review.pdf` byte for byte, then a revision that replaces the field objects (the test checks both); PDFDocEncoding text (`\205` en dash, `\243` pound) and octal escapes |
| `pypdf-aes256.pdf` | pypdf 7.1.1 with cryptography 50.0.2, `encrypt(user_password="", algorithm="AES-256")` | AES-256 (/V 5 /R 6) strings and streams, opened with the empty user password |
| `pdflib-form.pdf` | pdf-lib 1.17.1, a form built and filled entirely by pdf-lib, saved with object streams | Cross-reference and object streams; a nested name (`inspection.date`); a radio group whose states are positions mapped through `/Opt`; a dropdown; a multi-select list; UTF-16BE text |

`review.json` / `review.pdf` are the input the PDFKit and pypdf fixtures were
made from: `pdf-gen --presentation review.json review.pdf`. `review.pdf` is
this package's own output, so it is not an anchor.

## How the expected values were set

- PDFKit: the values `make/pdfkit-fill.swift` typed and ticked. A rendering of
  the saved file (poppler `pdftoppm`) shows exactly these, ticks included.
  PDFKit's own re-read of its file reports `ir_ok` as ticked, from the stale
  `/AS`; the PDF specification makes `/V` the value, and with no `/V` the box
  is off, which is also what the saved appearance draws.
- pypdf: what `PdfReader.get_fields()` reads back from the saved file
  (`make/pypdf_forms.py` writes it).
- pdf-lib: what pdf-lib reads back from the saved bytes through its form API
  (`make/pdflib-make.js` writes it).

## Remaking them

```sh
pdf-gen --presentation review.json review.pdf
swift make/pdfkit-fill.swift review.pdf pdfkit-filled.pdf
python3 -I make/pypdf_forms.py incremental review.pdf pypdf-incremental.pdf   # pip install pypdf cryptography
python3 -I make/pypdf_forms.py encrypted review.pdf pypdf-aes256.pdf
PDF_LIB=/path/to/node_modules/pdf-lib node make/pdflib-make.js pdflib-form.pdf pdflib-form.expected.json
```

A remade `pypdf-aes256.pdf` differs byte for byte (fresh random key) but
carries the same values.

## The writer, read by other software

`review.pdf` (as `pdf-gen --presentation` writes it, compressed) was read by:

- pdf-lib 1.17.1 (`getForm().getFields()`): all 7 fields, with their types and
  values;
- pypdf 7.1.1 (`get_fields()`): all 7, with `/FT` and `/V`;
- PDFKit: all 7 as widgets with their field names, types and values, and it
  filled and saved them (`pdfkit-filled.pdf`);
- PDFium 159 (the engine in Chrome and Edge, through pypdfium2): all 7 with
  their names, types, values and tick states, and a forms-enabled render
  draws them;
- poppler 26.10 (`pdfinfo`: `Form: AcroForm`; `pdftotext` and `pdftoppm` draw the
  appearance streams: values, the tick, wrapped multi-line text).

On `pdfkit-filled.pdf` the readers disagree about the two checkboxes: PDFKit
reports both ticked (it trusts the stale `/AS`), pdf-lib and PDFium report
both unticked (they accept only a name in `/V`, not PDFKit's string). This
reader reports `rcd_tested` ticked and `ir_ok` unticked, which is what was set
and what the saved page draws.
