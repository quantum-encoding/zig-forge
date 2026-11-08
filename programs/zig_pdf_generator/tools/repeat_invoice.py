#!/usr/bin/env python3
"""repeat_invoice.py — make the invoices a schedule says are due, as PDFs, exactly once.

A repeat-invoice folder holds everything private to one customer's repeat:

  schedule.json   when it repeats and how it is numbered (see below)
  invoice.json    the pdf-gen invoice template: everything but number, dates and reference
  logo.png        optional; embedded as company_logo_base64
  made.jsonl      written here: one line per invoice made (period, number, date, file, sha256)

Usage:
  repeat_invoice.py run <folder> [--today YYYY-MM-DD] [--dry-run]
  repeat_invoice.py status <folder>

`run` is safe to call as often as you like (a daily or near-month-end cron is the intent):
it works out which periods are due from the schedule and made.jsonl, makes each missed
period's invoice once, in order, and does nothing when nothing is due. It never overwrites
a file, never reuses a number (the next number is the highest in made.jsonl, on disk, or the
schedule's `next`, plus one), and a render that fails records nothing, so no number is burned.
It makes PDFs only; sending one stays with a person.

schedule.json:
  {"every": "month", "day": 30, "start": "2026-11-30",
   "end": {"until": null, "count": null},
   "number": {"prefix": "INV-", "width": 4, "next": 18},
   "due_days": 30,
   "out_dir": "~/Documents/Invoices",
   "also_scan": ["~/Downloads"],
   "file_name": "{number}-Client.pdf",
   "pdf_gen": "~/work/zig-forge/programs/zig_pdf_generator/zig-out/bin/pdf-gen",
   "logo": "logo.png"}

`day` past a month's end falls on its last day (30 → 28 or 29 February). An invoice is dated
its scheduled day, even when it is made later.
"""
import argparse
import base64
import calendar
import copy
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def occurrence(year: int, month: int, day: int) -> dt.date:
    """The scheduled day in that month, or the month's last day when it has fewer."""
    return dt.date(year, month, min(day, calendar.monthrange(year, month)[1]))


def _months(start: dt.date):
    y, m = start.year, start.month
    while True:
        yield y, m
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def due_periods(schedule: dict, made_periods: set, today: dt.date) -> list:
    """Every period whose day has come and that has not been made, oldest first, within
    the schedule's start and end. A period is "YYYY-MM"."""
    if schedule.get("every", "month") != "month":
        raise ValueError(f"every={schedule.get('every')!r}: only 'month' repeats are supported")
    day = int(schedule["day"])
    start = dt.date.fromisoformat(schedule["start"])
    end = schedule.get("end") or {}
    until = dt.date.fromisoformat(end["until"]) if end.get("until") else None
    count = end.get("count")
    out = []
    budget = None if count is None else int(count) - len(made_periods)
    for y, m in _months(start.replace(day=1)):
        when = occurrence(y, m, day)
        if when > today or (until and when > until):
            break
        if when < start:
            continue
        period = f"{y:04d}-{m:02d}"
        if period in made_periods:
            continue
        if budget is not None and len(out) >= budget:
            break
        out.append((period, when))
    return out


def format_number(schedule: dict, n: int) -> str:
    num = schedule["number"]
    return f"{num.get('prefix', 'INV-')}{n:0{int(num.get('width', 4))}d}"


def next_number(schedule: dict, made_numbers: list, existing_names: list) -> int:
    """One past the highest number seen anywhere: made here, on disk, or the schedule's floor."""
    num = schedule["number"]
    rx = re.compile(re.escape(num.get("prefix", "INV-")) + r"(\d+)")
    seen = [int(num.get("next", 1)) - 1] + [int(n) for n in made_numbers]
    for name in existing_names:
        m = rx.match(name)
        if m:
            seen.append(int(m.group(1)))
    return max(seen) + 1


def invoice_json(template: dict, number: str, date: dt.date, due_days: int, logo_data_url) -> dict:
    """The template with this invoice's number, dates and payment reference. The template
    itself is not changed."""
    out = copy.deepcopy(template)
    out["invoice_number"] = number
    out["invoice_date"] = date.isoformat()
    out["due_date"] = (date + dt.timedelta(days=int(due_days))).isoformat()
    bank = dict(out.get("bank_details") or {})
    if bank:
        bank["reference"] = number
        out["bank_details"] = bank
    if logo_data_url:
        out["company_logo_base64"] = logo_data_url
    return out


def render_with(pdf_gen: str):
    """A renderer that runs pdf-gen on the JSON, writing the PDF to `path`."""
    def render(data: dict, path):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            src = f.name
        try:
            r = subprocess.run([pdf_gen, src, str(path)], capture_output=True, timeout=120)
        finally:
            os.unlink(src)
        if r.returncode != 0 or not Path(path).exists() or Path(path).stat().st_size == 0:
            raise RuntimeError(f"pdf-gen exited {r.returncode}: {r.stderr.decode(errors='replace').strip()}")
    return render


def _expand(p: str) -> Path:
    return Path(os.path.expanduser(p))


def _load(folder: Path):
    schedule = json.loads((folder / "schedule.json").read_text())
    template = json.loads((folder / "invoice.json").read_text())
    made_file = folder / "made.jsonl"
    made = [json.loads(l) for l in made_file.read_text().splitlines() if l.strip()] if made_file.exists() else []
    return schedule, template, made


def _logo(folder: Path, schedule: dict):
    name = schedule.get("logo")
    if not name:
        return None
    data = (folder / name).read_bytes()
    return "data:image/png;base64," + base64.b64encode(data).decode()


def _names_in(dirs) -> list:
    """File names in each folder that exists and may be read. A folder the OS refuses
    (macOS keeps a background job out of Downloads and Documents) is skipped with a
    warning: the scan only guards against numbers issued by hand."""
    names = []
    for d in dirs:
        if not d.exists():
            continue
        try:
            names.extend(p.name for p in d.iterdir())
        except PermissionError as e:
            print(f"warning: cannot read {d} ({e.strerror}); its invoice numbers are not checked",
                  file=sys.stderr)
    return names


def _number_of(schedule: dict, number: str) -> int:
    return int(number[len(schedule["number"].get("prefix", "INV-")):])


def run(folder, today: dt.date, render=None, dry_run: bool = False) -> list:
    """Make every due invoice; return what was made (or, with dry_run, what would be)."""
    folder = Path(folder)
    schedule, template, made = _load(folder)
    out_dir = _expand(schedule.get("out_dir", "."))
    scan = [out_dir] + [_expand(p) for p in schedule.get("also_scan", [])]
    if render is None:
        render = render_with(str(_expand(schedule["pdf_gen"])))
    logo = _logo(folder, schedule)
    due = due_periods(schedule, {m["period"] for m in made}, today)
    results = []
    made_numbers = [_number_of(schedule, m["number"]) for m in made]
    for period, when in due:
        existing = _names_in(scan)
        n = next_number(schedule, made_numbers, existing)
        number = format_number(schedule, n)
        target = out_dir / schedule["file_name"].format(number=number, period=period)
        record = {"period": period, "number": number, "date": when.isoformat(), "file": str(target)}
        if dry_run:
            results.append(record)
            made_numbers.append(n)
            continue
        if target.exists():
            raise FileExistsError(f"{target} exists; refusing to overwrite an invoice")
        out_dir.mkdir(parents=True, exist_ok=True)
        data = invoice_json(template, number, when, schedule.get("due_days", 30), logo)
        fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".repeat-", suffix=".pdf")
        os.close(fd)
        try:
            render(data, tmp)
            # link, not rename: fails if the name appeared meanwhile, so nothing is overwritten
            os.link(tmp, target)
        finally:
            os.unlink(tmp)
        record["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
        record["made_at"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        with open(folder / "made.jsonl", "a") as f:
            f.write(json.dumps(record) + "\n")
            f.flush()
            os.fsync(f.fileno())
        made_numbers.append(n)
        results.append(record)
    return results


def status(folder) -> str:
    folder = Path(folder)
    schedule, template, made = _load(folder)
    total = template.get("total")
    sym = template.get("currency_symbol", "")
    lines = [f"{len(made)} made" + (f", {sym}{total:,.2f} each" if isinstance(total, (int, float)) else "")]
    for m in made[-3:]:
        lines.append(f"  {m['number']}  {m['date']}  {m['file']}")
    nxt = due_periods(schedule, {m["period"] for m in made}, dt.date.max - dt.timedelta(days=400))[:1]
    if nxt:
        lines.append(f"next: {nxt[0][1].isoformat()} ({nxt[0][0]})")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("folder")
    r.add_argument("--today", help="YYYY-MM-DD (default: today, local time)")
    r.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("status")
    s.add_argument("folder")
    a = ap.parse_args(argv)
    if a.cmd == "status":
        print(status(a.folder))
        return 0
    today = dt.date.fromisoformat(a.today) if a.today else dt.date.today()
    made = run(a.folder, today, dry_run=a.dry_run)
    if not made:
        print(f"nothing due on {today.isoformat()}")
    for m in made:
        verb = "would make" if a.dry_run else "made"
        print(f"{verb} {m['number']} for {m['period']}, dated {m['date']}: {m['file']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
