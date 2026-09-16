# zig_legend

Renders text templates by substituting `{VARIABLE}` placeholders from a typed legend, choosing each variable's value by scenario, by round-robin sequence, or by full matrix.

A **legend** (TOML) declares every variable: its type (`string`, `enum`, `int`, `money`, `date`, `bool`), candidate values, default, whether it is required, and optionally that its value follows from another variable (`by` + `map`). It also names **scenarios**, each a set of bindings such as the outcome a letter reports. A **template** is plain text with `{NAME}` placeholders, filters, and `{?VAR=value}…{:}…{/}` blocks. The legend is parsed with the promoted in-tree `zig_toml`; JSON output goes through `std.json`.

## Build

```sh
zig build            # zig-out/bin/zig_legend + libzig_legend.a, module "zig_legend"
zig build test       # unit tests + golden renders of examples/
```

## Example: a decision letter

`examples/letter/letter.txt`:

```
{COMPANY}
{DATE|long}

Dear {APPLICANT},

Re: application {REF}

Thank you for your application to {COMPANY}. We have now completed our review.
{?OUTCOME=approved}

We are pleased to tell you that your application has been approved, with a
facility of {AMOUNT}. {NEXT_STEP}
{/}
{?OUTCOME=declined}

We regret that we are unable to approve your application on this occasion.
{NEXT_STEP} If you would like the reasons for this decision, reply to this
letter quoting reference {REF}.
{/}
…
{SIGNATORY}
{ROLE}, {COMPANY}
```

`examples/letter/legend.toml` (abridged):

```toml
[[var]]
name = "OUTCOME"
type = "enum"
values = ["approved", "declined", "deferred"]
required = true

[[var]]
name = "AMOUNT"
type = "money"
currency = "GBP"        # "12500" renders as £12,500.00
value = "0"

[[var]]
name = "DATE"
type = "date"           # YYYY-MM-DD, validated; {DATE|long} → 16 September 2026
required = true

[[var]]
name = "ROLE"
by = "OUTCOME"          # value follows the outcome
[var.map]
approved = "Head of Onboarding"
declined = "Applications Team"
deferred = "Applications Team"

[[scenario]]
name = "approved"
[scenario.set]
OUTCOME = "approved"
APPLICANT = "Ada Lovelace"
REF = "QE-2026-0417"
DATE = "2026-09-16"
AMOUNT = "12500"
```

```sh
zig_legend render -l legend.toml -t letter.txt -s approved
zig_legend render -l legend.toml -t letter.txt -s declined --set DATE=2026-10-01
zig_legend render -l legend.toml -t letter.txt --each-scenario --out-dir out/   # approved.txt, declined.txt, deferred.txt
zig_legend check  -l legend.toml -t letter.txt        # lint every scenario; exit 3 on problems
zig_legend vars   -t letter.txt -l legend.toml        # placeholders with their legend entry
```

The three rendered letters are checked in under `examples/letter/expected/` and locked by `zig build test`.

## Example: a prompt matrix

`examples/modguard/` is the Vertex AI Studio "ModGuard" demo's prompt with its category and severity lists as enums. `matrix` renders all 21 category × severity prompts:

```sh
zig_legend matrix -l legend.toml -t prompt.txt --json > prompts.json
```

Each JSON element is `{"variant": "0001", "bindings": {...}, "text": "..."}`, ready for an eval harness.

## Substitution plans

| Plan | Value of a list variable in variant *i* |
|---|---|
| `render` | the scenario / `--set` / default; nothing varies |
| `sequence -n N [--seed S]` | `values[i mod len]`; with a seed, each list is first shuffled deterministically |
| `matrix [--max N]` | every combination, first declared variable slowest; refused above the cap |

A variable takes part in a plan when it has a `values` list and is not pinned by `-s` or `--set`. Binding precedence, highest first: `--set`, plan pick, scenario, default. Dependent (`by`) variables are then filled from their map unless already bound.

## Template syntax

| Form | Meaning |
|---|---|
| `{NAME}` | substitute; money and date types format themselves (`£1,234.50`, `2026-09-16`) |
| `{NAME\|upper}` `lower` `title` `trim` | text filters, chainable left to right |
| `{DATE\|long}` `us` `uk` | `16 September 2026`, `September 16, 2026`, `16/09/2026` |
| `{AMOUNT\|plain}` `raw` | money without the currency; the untouched bound text |
| `{?VAR=value}…{:}…{/}` | block on equality, with optional else; `!=` and bare `{?FLAG}` (truthy) also work; nests |
| `{! comment }` | removed |
| `{{` `}}` | literal braces |

A block tag or comment alone on its line is removed with the line, so untaken branches leave no blank lines. `[legend] open = "<<"` / `close = ">>"` changes the delimiters.

## Validation

Every value, whether from the legend, a scenario or `--set`, is checked against its type: enum membership, integer bounds, decimal places for money, real calendar dates, boolean spellings. `--set` of a variable the legend does not declare is an error. Scenario names must be filesystem-safe. `check` reports unknown placeholders, unused legend variables, unbound required variables and type errors in one pass.

## Library

```zig
const lib = @import("zig_legend");
var diag = lib.Diag{};
var legend = try lib.Legend.load(gpa, toml_src, &diag);
var tpl = try lib.template.parse(gpa, text, legend.delims, &diag);
var b = try lib.render.resolve(gpa, &legend, "approved", &.{}, &.{}, &diag);
const out = try lib.render.renderAlloc(gpa, &tpl, &legend, &b, &diag);
```

`diag.text()` and `diag.line` carry the message for any error.

## Status

Not promoted (see the repo `CLAUDE.md`): the goldens under `examples/` are drift locks of this tool's own output, not external anchors.
