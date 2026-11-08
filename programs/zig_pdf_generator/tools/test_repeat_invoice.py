"""Witnesses for repeat_invoice.py: what "a repeat invoice was made correctly" means.

Run: python3 -m unittest tools/test_repeat_invoice.py   (from programs/zig_pdf_generator)
"""
import datetime as dt
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import repeat_invoice as ri

D = dt.date
HERE = Path(__file__).resolve().parent
PDF_GEN = HERE.parent / "zig-out" / "bin" / "pdf-gen"


def schedule(**over):
    s = {
        "every": "month",
        "day": 30,
        "start": "2026-11-30",
        "end": {"until": None, "count": None},
        "number": {"prefix": "INV-", "width": 4, "next": 18},
        "due_days": 30,
        "file_name": "{number}-Example.pdf",
    }
    s.update(over)
    return s


TEMPLATE = {
    "preset": "invoice",
    "theme": "glass",
    "company_name": "Example Ltd",
    "client_name": "Client Ltd",
    "items": [{"description": "Support", "quantity": 1, "unit_price": 2000, "total": 2000}],
    "total": 2000,
    "currency_symbol": "£",
    "show_tax": False,
    "bank_details": {"account_name": "Example Ltd", "sort_code": "00-00-00", "account_number": "00000000"},
}


class Dates(unittest.TestCase):
    def test_a_day_past_the_month_end_falls_on_its_last_day(self):
        self.assertEqual(ri.occurrence(2027, 2, 30), D(2027, 2, 28))
        self.assertEqual(ri.occurrence(2028, 2, 30), D(2028, 2, 29))
        self.assertEqual(ri.occurrence(2027, 4, 31), D(2027, 4, 30))
        self.assertEqual(ri.occurrence(2026, 12, 30), D(2026, 12, 30))

    def test_nothing_is_due_before_the_day(self):
        self.assertEqual(ri.due_periods(schedule(), set(), D(2026, 11, 29)), [])

    def test_the_period_is_due_on_its_day(self):
        self.assertEqual(ri.due_periods(schedule(), set(), D(2026, 11, 30)), [("2026-11", D(2026, 11, 30))])

    def test_missed_periods_are_each_made_once_in_order(self):
        self.assertEqual(
            ri.due_periods(schedule(), set(), D(2027, 2, 28)),
            [("2026-11", D(2026, 11, 30)), ("2026-12", D(2026, 12, 30)),
             ("2027-01", D(2027, 1, 30)), ("2027-02", D(2027, 2, 28))],
        )

    def test_a_period_already_made_is_not_made_again(self):
        self.assertEqual(
            ri.due_periods(schedule(), {"2026-11", "2026-12"}, D(2027, 1, 30)),
            [("2027-01", D(2027, 1, 30))],
        )

    def test_an_end_date_stops_it(self):
        s = schedule(end={"until": "2026-12-31", "count": None})
        self.assertEqual([p for p, _ in ri.due_periods(s, set(), D(2027, 3, 30))], ["2026-11", "2026-12"])

    def test_a_count_stops_it_counting_what_was_already_made(self):
        s = schedule(end={"until": None, "count": 3})
        self.assertEqual([p for p, _ in ri.due_periods(s, {"2026-11"}, D(2027, 3, 30))], ["2026-12", "2027-01"])


class Numbers(unittest.TestCase):
    def test_the_next_number_is_the_highest_seen_plus_one(self):
        s = schedule()
        self.assertEqual(ri.next_number(s, made_numbers=[], existing_names=[]), 18)
        self.assertEqual(ri.next_number(s, made_numbers=[18], existing_names=[]), 19)
        # an invoice already on disk with a higher number (made by hand) is never reused
        self.assertEqual(ri.next_number(s, made_numbers=[18], existing_names=["INV-0021-Other.pdf"]), 22)
        self.assertEqual(ri.format_number(s, 18), "INV-0018")

    def test_the_invoice_takes_its_number_dates_and_reference_and_the_template_is_untouched(self):
        before = json.dumps(TEMPLATE, sort_keys=True)
        out = ri.invoice_json(TEMPLATE, "INV-0018", D(2026, 11, 30), 30, logo_data_url=None)
        self.assertEqual(out["invoice_number"], "INV-0018")
        self.assertEqual(out["invoice_date"], "2026-11-30")
        self.assertEqual(out["due_date"], "2026-12-30")
        self.assertEqual(out["bank_details"]["reference"], "INV-0018")
        self.assertEqual(out["items"], TEMPLATE["items"])
        self.assertEqual(json.dumps(TEMPLATE, sort_keys=True), before)


class Run(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.out = self.dir / "out"
        s = schedule(out_dir=str(self.out))
        (self.dir / "schedule.json").write_text(json.dumps(s))
        (self.dir / "invoice.json").write_text(json.dumps(TEMPLATE))
        self.rendered = []

    def tearDown(self):
        shutil.rmtree(self.dir)

    def render(self, data, path):
        self.rendered.append(data["invoice_number"])
        Path(path).write_bytes(b"%PDF-1.4 " + data["invoice_number"].encode())

    def made(self):
        f = self.dir / "made.jsonl"
        return [json.loads(l) for l in f.read_text().splitlines()] if f.exists() else []

    def test_it_makes_each_due_invoice_records_it_and_a_second_run_makes_nothing(self):
        first = ri.run(self.dir, D(2026, 12, 30), render=self.render)
        self.assertEqual([m["number"] for m in first], ["INV-0018", "INV-0019"])
        self.assertTrue((self.out / "INV-0018-Example.pdf").exists())
        self.assertTrue((self.out / "INV-0019-Example.pdf").exists())
        self.assertEqual([m["period"] for m in self.made()], ["2026-11", "2026-12"])
        self.assertEqual(ri.run(self.dir, D(2026, 12, 30), render=self.render), [])
        self.assertEqual(self.rendered, ["INV-0018", "INV-0019"])

    def test_a_failed_render_burns_no_number_and_records_nothing(self):
        def broken(data, path):
            raise RuntimeError("pdf-gen failed")
        with self.assertRaises(RuntimeError):
            ri.run(self.dir, D(2026, 11, 30), render=broken)
        self.assertEqual(self.made(), [])
        self.assertFalse(any(self.out.glob("*.pdf")) if self.out.exists() else False)
        self.assertEqual([m["number"] for m in ri.run(self.dir, D(2026, 11, 30), render=self.render)], ["INV-0018"])

    def test_an_existing_file_is_never_overwritten(self):
        self.out.mkdir()
        (self.out / "INV-0018-Example.pdf").write_bytes(b"someone else's")
        made = ri.run(self.dir, D(2026, 11, 30), render=self.render)
        # the number on disk is taken, so the invoice gets the next one
        self.assertEqual([m["number"] for m in made], ["INV-0019"])
        self.assertEqual((self.out / "INV-0018-Example.pdf").read_bytes(), b"someone else's")

    def test_a_dry_run_says_what_it_would_make_and_writes_nothing(self):
        plan = ri.run(self.dir, D(2026, 11, 30), render=self.render, dry_run=True)
        self.assertEqual([m["number"] for m in plan], ["INV-0018"])
        self.assertEqual(self.made(), [])
        self.assertEqual(self.rendered, [])


@unittest.skipUnless(PDF_GEN.exists() and shutil.which("pdftotext"), "needs zig-out/bin/pdf-gen and pdftotext")
class RealPdf(unittest.TestCase):
    def test_the_real_generator_renders_the_number_dates_and_total(self):
        d = Path(tempfile.mkdtemp())
        try:
            pdf = d / "x.pdf"
            ri.render_with(str(PDF_GEN))(ri.invoice_json(TEMPLATE, "INV-0018", D(2026, 11, 30), 30, None), pdf)
            text = subprocess.run(["pdftotext", str(pdf), "-"], capture_output=True, text=True).stdout
            for want in ("INV-0018", "2026-11-30", "2026-12-30", "£2,000.00"):
                self.assertIn(want, text)
        finally:
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main()
