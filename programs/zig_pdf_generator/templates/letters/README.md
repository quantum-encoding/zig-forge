# Debt-recovery letter pack

Four pre-constructed letters for chasing an unpaid invoice, written for **England and Wales**, rendered by `zigpdf_generate_legend_letter` (or `pdf-gen --legend-letter`). Each letter is a [zig_legend](../../../zig_legend/README.md) template with a typed legend, so every value is type-checked and a letter with a missing value is refused rather than printed with a gap.

> **Not legal advice. Review before use.** These templates are a starting point written against the sources listed below as retrieved on 26 September 2026. They are not a substitute for advice on a particular debt. The law, the Civil Procedure Rules and the Bank of England rate change; check the sources, and have the wording reviewed for your business, before sending any of these letters. All names, addresses, bank details and figures in the scenarios are fictional, and the 4.00% reference rate in them is illustrative, not the actual Bank Rate on any date.

## The letters

| Letter | Template | Frame | Legend | Sent when |
|---|---|---|---|---|
| (a) Payment reminder | `reminder.tpl.md` | `reminder.letter.json` | `debt-recovery.toml` | shortly after the due date |
| (b) Second reminder | `second-reminder.tpl.md` | `second-reminder.letter.json` | `debt-recovery.toml` | the first reminder went unanswered |
| (c) Final demand | `final-demand.tpl.md` | `final-demand.letter.json` | `debt-recovery.toml` | before starting court proceedings |
| (d) Statutory interest claim | `statutory-interest.tpl.md` | `statutory-interest.letter.json` | `statutory-interest.toml` | business debtor; claim interest and compensation under the Late Payment Act |

The *template* is the body. The *frame* is the `letter` object (letterhead, date, reference, recipient, subject, closing, signature, accent colour); its text fields hold placeholders too. `stages.json` holds the fictional creditor and the per-letter dates used by the proofs.

### Outcomes the templates branch on

| Variable | Values | Effect |
|---|---|---|
| `DEBTOR_TYPE` | `company`, `sole_trader`, `individual` | (c): a **company** (or LLP) gets a *letter before action* under the Practice Direction on Pre-Action Conduct; a **sole trader** or **individual** gets a *Letter of Claim* under the Pre-Action Protocol for Debt Claims, with its enclosures and 30-day reply period. (b): the Late Payment Act is mentioned only when the debtor is a business. (d): `statutory-interest.toml` has no `individual` value, so a consumer debtor is refused. |
| `PAYMENT_STATUS` | `unpaid`, `partial`, `plan_offered` | `partial` acknowledges the part payment and shows it in the amounts table; `plan_offered` offers the debtor instalments. (d) has `unpaid` and `paid_late` (interest on an invoice already paid late). |
| `CLAIM_STATUTORY_INTEREST` | bool | (c) to a company or sole trader: adds statutory interest and fixed-sum compensation rows. |
| `AGREEMENT_TYPE` | `written`, `oral` | Letter of Claim: states the agreement as the Protocol requires for each kind. |
| `INSTALMENTS_OFFERED` | bool | Letter of Claim: the debtor is offering instalments; the letter explains why the offer is not accepted, as the Protocol requires. |
| `INTEREST_CONTINUING` | bool | Letter of Claim without statutory interest: whether contractual interest or charges are still being added. |
| `RECOVERY_COSTS_CLAIMED` | bool | (d): claims reasonable recovery costs beyond the fixed sum. |

Scenarios in the legends: `company-unpaid`, `company-partial`, `sole-trader-plan`, `individual-unpaid`, `individual-instalments` (letters a–c) and `company-unpaid`, `company-paid-late`, `sole-trader-unpaid` (letter d).

A variable with no default that is not marked `required` is needed only by a letter or branch that uses it (`PAY_BY` by the reminders, `RESPONSE_DEADLINE` by the letter before action, `ORAL_AGREEMENT` by a Letter of Claim for an oral agreement, and so on). A letter that reaches one unbound is refused with `'NAME' is not bound`.

## What the app computes

The engine formats and checks values; it does not do arithmetic. Bind these already calculated:

- `AMOUNT_OUTSTANDING` = invoice total − payments received.
- Statutory interest (Late Payment Act): simple interest from the day after the agreed payment date. `STATUTORY_RATE` = 8 + the Bank of England official dealing rate (Bank Rate) in force on the **30 June** (for interest that starts to run between 1 July and 31 December) or **31 December** (for interest that starts between 1 January and 30 June) immediately before interest starts to run. `INTEREST_AMOUNT` = principal × `STATUTORY_RATE`/100 × days ÷ 365; `DAILY_INTEREST` = principal × `STATUTORY_RATE`/100 ÷ 365.
- `DEBT_BAND` (`under_1000`, `1000_to_9999`, `10000_or_more`): the legend maps it to the fixed compensation of £40, £70 or £100. `COMPENSATION` itself cannot be bound.
- `TOTAL_CLAIMED`, and `RECOVERY_COSTS` = reasonable recovery costs − the fixed sum.
- For a company letter before action, `RESPONSE_DEADLINE`: the Practice Direction gives 14 days as a reasonable time in a straightforward case.

## Legal points the letters rely on, and their sources

Retrieved 26 September 2026.

**Late Payment of Commercial Debts (Interest) Act 1998** ([legislation.gov.uk/ukpga/1998/20](https://www.legislation.gov.uk/ukpga/1998/20))

- s.1(1): a qualifying debt carries **simple** interest by an implied term. [s.1](https://www.legislation.gov.uk/ukpga/1998/20/section/1)
- s.2(1): the Act applies to a contract for the supply of goods or services **where the purchaser and the supplier are each acting in the course of a business**; s.2(5) excepts consumer credit agreements and contracts operating by way of mortgage, pledge, charge or other security. So letters (b)–(d) invoke it only for company and sole-trader debtors. [s.2](https://www.legislation.gov.uk/ukpga/1998/20/section/2)
- s.4: statutory interest starts to run on the day after the relevant day (the agreed payment date, subject to the limits in s.4; otherwise the last day of the 30-day period after performance or notice of the debt), at the rate prevailing at the end of the relevant day. [s.4](https://www.legislation.gov.uk/ukpga/1998/20/section/4)
- s.5A(1)–(2): once statutory interest begins to run, the supplier is entitled to a fixed sum: **£40** for a debt less than £1,000; **£70** for £1,000 or more but less than £10,000; **£100** for £10,000 or more. s.5A(2A): if the fixed sum does not meet the supplier's reasonable costs of recovering the debt, the supplier is also entitled to the difference. [s.5A](https://www.legislation.gov.uk/ukpga/1998/20/section/5A)
- s.6: the rate is set by order. [s.6](https://www.legislation.gov.uk/ukpga/1998/20/section/6)

**Late Payment of Commercial Debts (Rate of Interest) (No. 3) Order 2002, SI 2002/1675**, art. 4: the rate is **8% per annum over the official dealing rate** in force on the 30th June (for interest which starts to run between 1st July and 31st December) or the 31st December (for interest which starts to run between 1st January and 30th June) immediately before the day on which statutory interest starts to run. Art. 3 defines the official dealing rate as the rate announced by the Bank of England's Monetary Policy Committee. The Order extends to England, Wales and Northern Ireland. [art. 4](https://www.legislation.gov.uk/uksi/2002/1675/article/4/made)

**GOV.UK, "Late commercial payments: charging interest and debt recovery"**: statutory interest is "8% plus the Bank of England base rate for business to business transactions"; worked example dividing the annual interest by 365 for a daily figure; statutory interest cannot be claimed where the contract specifies a different interest rate. [gov.uk guide](https://www.gov.uk/late-commercial-payments-interest-debt-recovery/charging-interest-commercial-debt)

**Pre-Action Protocol for Debt Claims** (Civil Procedure Rules; in force 1 October 2017; [PDF at justice.gov.uk](https://www.justice.gov.uk/courts/procedure-rules/civil/pdf/protocols/debt-pap.pdf), linked from the [Pre-Action Protocols page](https://www.justice.gov.uk/courts/procedure-rules/civil/protocol))

- 1.1: applies to any business (including sole traders and public bodies) claiming payment of a debt from an **individual (including a sole trader)**; it **does not apply to business-to-business debts unless the debtor is a sole trader**. Hence the company variant of letter (c) does not claim to follow it.
- 3.1(a): the Letter of Claim contains (i) the amount of the debt; (ii) whether interest or other charges are continuing; (iii) for an oral agreement, who made it, what was agreed (as far as possible the words used), and when and where; (iv) for a written agreement, its date, the parties, and that a copy can be requested; (v) for an assigned debt, the original debt and creditor and when and to whom it was assigned; (vi) if instalments are being offered or paid, why the offer is not acceptable and why a claim is still being considered; (vii) how the debt can be paid and how to proceed to discuss payment options; (viii) the address for the completed Reply Form.
- 3.1(b)–(d): enclose an up-to-date statement of account (or one of the alternatives in 3.1(b)), the **Information Sheet and Reply Form** (Annex 1), and a **Financial Statement** form (Annex 2).
- 3.2–3.3: date the letter clearly towards the top of the first page; post it that day or the next; send it by post (and optionally by other known means).
- 3.4: if the debtor does not reply **within 30 days of the date at the top of the letter**, the creditor may start proceedings.
- 4.2–4.3: if the debtor says they are seeking debt advice, allow a reasonable period; do not start proceedings less than 30 days from receipt of the completed Reply Form or from providing requested documents, whichever is later.

**Practice Direction – Pre-Action Conduct and Protocols** ([justice.gov.uk](https://www.justice.gov.uk/courts/procedure-rules/civil/rules/pd_pre-action_conduct)), for debts owed by a company: para 6(a) the claimant writes with concise details of the claim (basis, summary of facts, what is sought and how any sum is calculated); 6(b) the defendant responds within a reasonable time, **14 days in a straightforward case** and no more than 3 months in a very complex one; 6(c) the parties disclose key documents. Paras 13–16: the court may take non-compliance into account.

### Left out, or not verified

- **Scotland and Northern Ireland court procedure.** The Protocol and Practice Direction are Civil Procedure Rules for England and Wales; the letters are written for that jurisdiction only. Scotland has its own rate order under the Late Payment Act, which was not checked.
- **Assigned debts** (Protocol 3.1(a)(v)) and **debts regulated by the Consumer Credit Act 1974 / FCA rules**: not covered. Do not use the Letter of Claim for them without adding what those rules require.
- **Whether statutory interest may be claimed** depends on the contract: where the contract provides its own remedy for late payment, statutory interest may be excluded (Act Part II; GOV.UK). The templates do not decide this; set `CLAIM_STATUTORY_INTEREST` accordingly.
- **The Annex 1 Information Sheet and Reply Form and the Annex 2 Financial Statement** are not generated. The Letter of Claim lists them as enclosures; the app must attach the current versions from the Protocol.
- **Debt-advice phone numbers** are not printed: the Information Sheet carries them, and numbers change. The second reminder names Citizens Advice, National Debtline and StepChange by website only (all three are listed in the Protocol's Information Sheet).
- **Court fees and fixed costs** are not quantified; the letters say only that the court may be asked to order the court fee and any interest and costs it allows.

## Rendering

```sh
templates/letters/render-proofs.sh            # every letter x scenario -> output/legend-letters/
zig-out/bin/pdf-gen --legend-describe input.json   # variables + scenarios as JSON, for a form
```

A CLI input can name files instead of inlining them; paths are relative to the input file:

```json
{
  "legend_file": "../../../templates/letters/debt-recovery.toml",
  "template_file": "../../../templates/letters/final-demand.tpl.md",
  "letter_file": "../../../templates/letters/final-demand.letter.json",
  "scenario": "individual-unpaid",
  "bindings": {"CREDITOR_NAME": "…", "LETTER_DATE": "2026-09-15", "DAYS_OVERDUE": 46}
}
```

Through the C API, inline them as `legend_toml`, `template` and `letter`; see `ZIG_PDF_SCHEMA.md`.
