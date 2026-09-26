{! (a) Friendly payment reminder. Legend: debt-recovery.toml. Needs PAY_BY. }
Dear {SALUTATION},

{?PAYMENT_STATUS=partial}
Thank you for your payment of {AMOUNT_PAID}, which we received on {LAST_PAYMENT_DATE|long}. Our records show that a balance of {AMOUNT_OUTSTANDING} remains on the account below, which was due for payment on {DUE_DATE|long}.
{:}
We are writing as a friendly reminder that the account below, which was due for payment on {DUE_DATE|long}, has not yet been paid. It is now {DAYS_OVERDUE} days overdue.
{/}

| Invoice | Invoice date | Due date | Amount outstanding |
|---|---|---|---|
| {INVOICE_NUMBERS} | {INVOICE_DATE|long} | {DUE_DATE|long} | {AMOUNT_OUTSTANDING} |

If you have already paid, thank you, and please disregard this letter. Otherwise, we would be grateful if you could pay {AMOUNT_OUTSTANDING} by **{PAY_BY|long}**, using the details below.

- **Account name:** {PAYEE_NAME}
- **Sort code:** {SORT_CODE}
- **Account number:** {ACCOUNT_NUMBER}
- **Payment reference:** {PAYMENT_REFERENCE}

{?PAYMENT_STATUS=plan_offered}
If paying the full balance at once is difficult, we are happy to accept {PLAN_COUNT} {PLAN_FREQUENCY} payments of {PLAN_INSTALMENT}, starting on {PLAN_FIRST_DATE|long}. Please let us know by {PLAN_ACCEPT_BY|long} if you would like to pay this way.

{/}
If there is a problem with the invoice, or with {GOODS_OR_SERVICES}, please contact {SIGNATORY} on {CREDITOR_PHONE} or at {CREDITOR_EMAIL} so that we can put it right.

Thank you for your business.
