#!/usr/bin/env python3
"""Render the document-system proof matrix.

One shared fictional sample (sample.json) drives every document: the five
visual styles x the quote / invoice / receipt presets, plus an "all toggles on"
invoice, a flat-rate (no qty columns) invoice and a 40-line invoice per style.

Usage (from programs/zig_pdf_generator, after `zig build`):
    python3 output/document-system/build_matrix.py

Writes payloads/*.json, pdf/*.pdf and render-<name>-<page>.png (pdftoppm,
90 dpi) next to this script.
"""
import base64
import copy
import json
import pathlib
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
ENGINE = HERE.parents[1] / "zig-out" / "bin" / "pdf-gen"
STYLES = ["classic", "squircle", "glass", "minimal", "letterhead"]


def data_url(name):
    return "data:image/png;base64," + base64.b64encode((HERE / name).read_bytes()).decode()


def build_payloads(sample):
    logo = data_url("logo.png")
    signature = data_url("signature.png")
    out = {}
    for style in STYLES:
        base = copy.deepcopy(sample)
        base["style"] = style
        base["company_logo_base64"] = logo

        quote = copy.deepcopy(base)
        quote.update(preset="quote", invoice_number="QTE-2026-0118", due_date="2026-10-26",
                     notes="This quote is valid for 30 days.\nPrices include all design rounds listed; extra rounds are billed at the day rate.",
                     payment_terms="50% deposit on acceptance, balance on completion.")
        out[f"{style}-quote"] = quote

        inv = copy.deepcopy(base)
        inv.update(preset="invoice", payment_terms="Payment due within 14 days.\nPlease quote the invoice number as your reference.")
        out[f"{style}-invoice"] = inv

        rct = copy.deepcopy(base)
        rct.update(preset="receipt", invoice_number="RCT-2026-0311", due_date="",
                   client_name="", client_address="", client_vat="",
                   items=rct["items"][:3],
                   amount_paid=None, payment_date="26 Sep 2026", payment_method="Card (Visa ending 4242)",
                   notes="Thank you, your payment has been received.")
        for k in ("subtotal", "tax_amount", "total"):
            rct.pop(k, None)
        rct["show_tax"] = False
        # Receipts are paid in full: amount_paid equals the derived total.
        rct["amount_paid"] = sum(i["quantity"] * i["unit_price"] for i in rct["items"])
        out[f"{style}-receipt"] = rct

        allon = copy.deepcopy(base)
        allon.update(
            preset="invoice", subject="Brand refresh and website — phase 1",
            items=[dict(i) for i in allon["items"]],
            adjustments=[{"label": "Print & delivery", "amount": 45.00},
                         {"label": "Returning-client credit", "amount": -120.00}],
            amount_paid=1500.00, payment_date="12 Sep 2026", payment_method="Bank transfer (deposit)",
            show_signature=True, signature_name="Morgan Ellis", signature_title="Director, Harbourline Design Studio",
            signature_image_base64=signature,
            payment_terms="Balance due within 14 days.\nLate payments may incur interest under the Late Payment of Commercial Debts Act.")
        allon["items"][4]["discount"] = 10
        allon["items"][2]["discount"] = 5
        out[f"{style}-all-toggles"] = allon

        flat = copy.deepcopy(base)
        flat.update(preset="invoice", invoice_number="INV-2026-0419", show_qty_columns=False,
                    items=[{"description": "Monthly design retainer — September 2026", "total": 1800.00},
                           {"description": "Additional landing page for the autumn campaign, including copy edits and two review rounds", "total": 650.00},
                           {"description": "Stock photography licences (3 images)", "total": 84.00}])
        out[f"{style}-flat-rate"] = flat

        long = copy.deepcopy(base)
        long.update(preset="invoice", invoice_number="INV-2026-0420",
                    items=[{"description": f"Content page {n + 1:02d}: copywriting, layout and responsive QA" + (" including image sourcing, alt text and two rounds of stakeholder review" if n % 7 == 3 else ""),
                            "quantity": 1 + (n % 3) * 0.5, "unit": "hrs" if n % 2 else "",
                            "unit_price": 65.00} for n in range(40)])
        out[f"{style}-40-lines"] = long
    return out


def main():
    sample = json.loads((HERE / "sample.json").read_text())
    payloads = build_payloads(sample)
    (HERE / "payloads").mkdir(exist_ok=True)
    (HERE / "pdf").mkdir(exist_ok=True)
    for old in HERE.glob("render-*.png"):
        old.unlink()
    for name, payload in payloads.items():
        payload = {k: v for k, v in payload.items() if v is not None}
        jp = HERE / "payloads" / f"{name}.json"
        jp.write_text(json.dumps(payload, indent=1, ensure_ascii=False))
        pdf = HERE / "pdf" / f"{name}.pdf"
        subprocess.run([str(ENGINE), str(jp), str(pdf)], check=True, capture_output=True)
        subprocess.run(["pdftoppm", "-png", "-r", "90", str(pdf), str(HERE / f"render-{name}")], check=True)
        print("ok", name)


if __name__ == "__main__":
    main()
