{! (c) Final demand. Legend: debt-recovery.toml. }
{! company: letter before action (Practice Direction - Pre-Action Conduct and Protocols, para 6). }
{!   Needs RESPONSE_DEADLINE (14 days is a reasonable time in a straightforward case) and TOTAL_CLAIMED. }
{! sole_trader / individual: Letter of Claim (Pre-Action Protocol for Debt Claims, para 3). }
{!   The reply period is 30 days from the date at the top of the letter, stated in words, not computed. }
{!   Send it by post with the enclosures listed at the end (para 3.1(b)-(d), 3.3). }
Dear {SALUTATION},

{?DEBTOR_TYPE=company}
We write about the sum of {TOTAL_CLAIMED} owed by {DEBTOR_NAME} to {CREDITOR_NAME}, which remains unpaid despite our earlier reminders. This letter before action sets out our claim so that you can consider it before we start court proceedings.

**Basis of the claim.** Under a contract between our companies, we supplied {GOODS_OR_SERVICES}. We invoiced you on {INVOICE_DATE|long} (invoice {INVOICE_NUMBERS}) for {INVOICE_TOTAL}, payable by {DUE_DATE|long}. Payment is now {DAYS_OVERDUE} days overdue.

**How the amount is calculated.**

| Item | Amount |
|---|---|
| Invoice {INVOICE_NUMBERS} | {INVOICE_TOTAL} |
{?PAYMENT_STATUS=partial}
| Less payment received {LAST_PAYMENT_DATE|long} | ({AMOUNT_PAID}) |
{/}
| Principal outstanding | {AMOUNT_OUTSTANDING} |
{?CLAIM_STATUTORY_INTEREST}
| Statutory interest at {INTEREST_RATE}% a year to {LETTER_DATE|long} | {INTEREST_TO_DATE} |
| Fixed-sum compensation for late payment | {COMPENSATION} |
{/}
| **Total now due** | **{TOTAL_CLAIMED}** |

{?CLAIM_STATUTORY_INTEREST}
Interest and compensation are claimed under the Late Payment of Commercial Debts (Interest) Act 1998. Statutory interest is simple interest and continues to accrue at {DAILY_INTEREST} a day until payment.

{/}
**What we require.** Please pay {TOTAL_CLAIMED}{?CLAIM_STATUTORY_INTEREST}, together with further interest of {DAILY_INTEREST} for each day after {LETTER_DATE|long},{/} by **{RESPONSE_DEADLINE|long}**, to:

- **Account name:** {PAYEE_NAME}
- **Sort code:** {SORT_CODE}
- **Account number:** {ACCOUNT_NUMBER}
- **Payment reference:** {PAYMENT_REFERENCE}

{?PAYMENT_STATUS=plan_offered}
Alternatively, we will accept {PLAN_COUNT} {PLAN_FREQUENCY} payments of {PLAN_INSTALMENT}, starting on {PLAN_FIRST_DATE|long}, if you confirm in writing by {RESPONSE_DEADLINE|long} that you will pay this way.

{/}
If you dispute the claim, in whole or in part, please tell us in writing by {RESPONSE_DEADLINE|long}, giving your reasons and enclosing copies of any documents you rely on. A copy of the invoice is enclosed.

If we receive neither payment nor a response by {RESPONSE_DEADLINE|long}, we intend to issue a claim against {DEBTOR_NAME} in the County Court without further notice, and to ask the court to order you to pay the court fee and any interest and costs it allows. We would much prefer to settle this without going to court, and we will consider any reasonable proposal for payment, or any form of alternative dispute resolution such as mediation, that you put to us.

Please note that the court expects parties to follow the Practice Direction on Pre-Action Conduct and Protocols, and may take into account whether you have responded to this letter.

Enclosure: copy invoice {INVOICE_NUMBERS}.
{:}
This is a Letter of Claim under the Pre-Action Protocol for Debt Claims. Please read it, and the enclosed Information Sheet, carefully.

**The debt.** You owe {CREDITOR_NAME} {AMOUNT_OUTSTANDING} for {GOODS_OR_SERVICES}. We invoiced you on {INVOICE_DATE|long} (invoice {INVOICE_NUMBERS}), and payment was due by {DUE_DATE|long}.

| Item | Amount |
|---|---|
| Invoice {INVOICE_NUMBERS} | {INVOICE_TOTAL} |
{?PAYMENT_STATUS=partial}
| Less payment received {LAST_PAYMENT_DATE|long} | ({AMOUNT_PAID}) |
{/}
| Amount of the debt | {AMOUNT_OUTSTANDING} |
{?DEBTOR_TYPE=sole_trader}
{?CLAIM_STATUTORY_INTEREST}
| Statutory interest at {INTEREST_RATE}% a year to {LETTER_DATE|long} | {INTEREST_TO_DATE} |
| Fixed-sum compensation for late payment | {COMPENSATION} |
| **Total now due** | **{TOTAL_CLAIMED}** |
{/}
{/}

**Interest and charges.** {?DEBTOR_TYPE=sole_trader}{?CLAIM_STATUTORY_INTEREST}Because this contract was made in the course of your business, we claim statutory interest and fixed-sum compensation under the Late Payment of Commercial Debts (Interest) Act 1998. Statutory interest is simple interest and is continuing at {DAILY_INTEREST} a day until payment.{:}{?INTEREST_CONTINUING}{INTEREST_DETAILS}{:}No interest or other charges are being added to this debt.{/}{/}{:}{?INTEREST_CONTINUING}{INTEREST_DETAILS}{:}No interest or other charges are being added to this debt.{/}{/} An up-to-date statement of account for the debt, showing any interest and charges added, is enclosed.

**The agreement.** {?AGREEMENT_TYPE=written}The debt arises from a written agreement dated {AGREEMENT_DATE|long} between {CREDITOR_NAME} and {DEBTOR_NAME}: {AGREEMENT_DESCRIPTION}. You can ask us for a copy of the agreement.{:}The debt arises from an oral agreement. {ORAL_AGREEMENT}{/}

{?INSTALMENTS_OFFERED}
**Your offer of instalments.** You have offered to pay {INSTALMENT_OFFER}. We are unable to accept this offer because {OFFER_REJECTION_REASON}. For that reason we are still considering a court claim, but we remain willing to discuss an arrangement based on your income and outgoings, which you can set out on the enclosed Financial Statement.

{/}
**How to pay.** You can pay by bank transfer to:

- **Account name:** {PAYEE_NAME}
- **Sort code:** {SORT_CODE}
- **Account number:** {ACCOUNT_NUMBER}
- **Payment reference:** {PAYMENT_REFERENCE}

{?PAYMENT_STATUS=plan_offered}
We are willing to accept {PLAN_COUNT} {PLAN_FREQUENCY} payments of {PLAN_INSTALMENT}, starting on {PLAN_FIRST_DATE|long}. If you would like to pay this way, please say so on the Reply Form.

{/}
If you would like to discuss how to pay, including paying by instalments, please contact {SIGNATORY} on {CREDITOR_PHONE} or at {CREDITOR_EMAIL}.

**What you need to do.** Please complete the enclosed Reply Form and send it to us at {CREDITOR_ADDRESS}. If you do not reply within 30 days of the date at the top of this letter, we may start court proceedings against you.

If you return the Reply Form, we will not start court proceedings until at least 30 days after we receive it, or 30 days after we send you any documents you ask for, whichever is later. If you tell us on the Reply Form that you are seeking debt advice, we will allow you a reasonable period to obtain it. Free, impartial debt advice is available from the organisations listed in the Information Sheet.

**Enclosures**

- Up-to-date statement of account
- Information Sheet and Reply Form (Annex 1 to the Pre-Action Protocol for Debt Claims)
- Financial Statement form (Annex 2 to the Protocol)
{/}
