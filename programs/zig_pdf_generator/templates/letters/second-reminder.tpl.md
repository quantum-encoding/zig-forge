{! (b) Second reminder. Legend: debt-recovery.toml. Needs PREVIOUS_LETTER_DATE and PAY_BY. }
Dear {SALUTATION},

We wrote to you on {PREVIOUS_LETTER_DATE|long} about the account below. We have not received payment{?PAYMENT_STATUS=partial} of the balance{/} or heard from you, and the account is now {DAYS_OVERDUE} days overdue.

| Invoice | Invoice date | Due date | Amount outstanding |
|---|---|---|---|
| {INVOICE_NUMBERS} | {INVOICE_DATE|long} | {DUE_DATE|long} | {AMOUNT_OUTSTANDING} |

{?PAYMENT_STATUS=partial}
We have taken into account your payment of {AMOUNT_PAID} received on {LAST_PAYMENT_DATE|long}, against invoiced charges of {INVOICE_TOTAL}.

{/}
Please pay {AMOUNT_OUTSTANDING} by **{PAY_BY|long}**:

- **Account name:** {PAYEE_NAME}
- **Sort code:** {SORT_CODE}
- **Account number:** {ACCOUNT_NUMBER}
- **Payment reference:** {PAYMENT_REFERENCE}

{?PAYMENT_STATUS=plan_offered}
Our offer to accept {PLAN_COUNT} {PLAN_FREQUENCY} payments of {PLAN_INSTALMENT}, starting on {PLAN_FIRST_DATE|long}, remains open until {PLAN_ACCEPT_BY|long}. If you would like to pay this way, please contact us before then.

{/}
{?DEBTOR_TYPE=individual}
If you are having difficulty paying, please contact us as soon as possible so that we can discuss a repayment arrangement you can afford. Free, impartial debt advice is available from organisations such as Citizens Advice (www.citizensadvice.org.uk), National Debtline (www.nationaldebtline.org) and StepChange Debt Charity (www.stepchange.org).
{:}
As this debt arises from a contract between two businesses, the Late Payment of Commercial Debts (Interest) Act 1998 may entitle us to claim statutory interest on the overdue amount and a fixed sum in compensation. We have not added these charges so far, but we reserve the right to claim them if the balance is not paid by {PAY_BY|long}.
{/}

If you dispute the invoice, or believe you have already paid, please contact {SIGNATORY} on {CREDITOR_PHONE} or at {CREDITOR_EMAIL} straight away, giving your reasons.

If we do not receive payment or hear from you by {PAY_BY|long}, we will write to you with a formal {?DEBTOR_TYPE=company}letter before action{:}Letter of Claim{/}, which is the step before court proceedings.
