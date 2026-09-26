{! (d) Statutory late-payment interest claim, business to business only. }
{! Legend: statutory-interest.toml, whose DEBTOR_TYPE has no "individual" value. }
Dear {SALUTATION},

Our invoice {INVOICE_NUMBER}, dated {INVOICE_DATE|long}, for {GOODS_OR_SERVICES}, was due for payment by {DUE_DATE|long}. {?PAYMENT_STATUS=paid_late}Thank you for your payment of {PRINCIPAL}, which we received on {PAID_DATE|long}, after the date it was due.{:}The invoice remains unpaid.{/}

Our contract with {DEBTOR_NAME} was made between two businesses, each acting in the course of business. The Late Payment of Commercial Debts (Interest) Act 1998 therefore entitles us to simple interest on the late payment from the day after it was due, and to a fixed sum as compensation. We now claim both.

**Statutory interest.** The rate of statutory interest is 8% a year above the Bank of England's official dealing rate (Bank Rate) in force on {REFERENCE_DATE|long}, the 30 June or 31 December immediately before interest started to run. That rate was {REFERENCE_RATE}%, so statutory interest runs at {STATUTORY_RATE}% a year.

Interest runs from {INTEREST_START|long} to {INTEREST_TO|long}, {DAYS} days: {PRINCIPAL} × {STATUTORY_RATE}% × {DAYS} ÷ 365 = {INTEREST_AMOUNT}, or {DAILY_INTEREST} a day.

**Amount claimed.**

| Item | Amount |
|---|---|
{?PAYMENT_STATUS=unpaid}
| Invoice {INVOICE_NUMBER}, unpaid | {PRINCIPAL} |
{/}
| Statutory interest, {DAYS} days at {STATUTORY_RATE}% a year | {INTEREST_AMOUNT} |
| Fixed-sum compensation (debt of {BAND_TEXT}) | {COMPENSATION} |
{?RECOVERY_COSTS_CLAIMED}
| Further reasonable costs of recovery | {RECOVERY_COSTS} |
{/}
| **Total now due** | **{TOTAL_CLAIMED}** |

The fixed sum of {COMPENSATION} is set by section 5A of the Act for a debt of {BAND_TEXT}.
{?RECOVERY_COSTS_CLAIMED}
Our reasonable costs of recovering this debt, {RECOVERY_COSTS_DETAILS}, came to {RECOVERY_COSTS_TOTAL}. As the fixed sum does not meet them, section 5A(2A) of the Act entitles us to the difference of {RECOVERY_COSTS} as well.
{/}
{?PAYMENT_STATUS=unpaid}

Interest continues to accrue at {DAILY_INTEREST} a day from {INTEREST_TO|long} until the invoice is paid.
{/}

Please pay {TOTAL_CLAIMED} by **{PAY_BY|long}** to:

- **Account name:** {PAYEE_NAME}
- **Sort code:** {SORT_CODE}
- **Account number:** {ACCOUNT_NUMBER}
- **Payment reference:** {PAYMENT_REFERENCE}

If you believe any part of this claim is wrong, please contact {SIGNATORY} on {CREDITOR_PHONE} or at {CREDITOR_EMAIL} by {PAY_BY|long}, giving your reasons.

{?DEBTOR_TYPE=sole_trader}
If this sum is not paid and we decide to start court proceedings, we will first send you a Letter of Claim under the Pre-Action Protocol for Debt Claims.
{:}
If this sum is not paid, we may include it in a claim against {DEBTOR_NAME} in the County Court.
{/}
