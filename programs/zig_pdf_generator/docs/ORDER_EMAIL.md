# App-aware order-confirmation email generator

Routes a Stripe `checkout.session.completed` event to the **correct per-app**
email template instead of always sending the Lutuno physical-order template.

- **Source:** `src/order_email.zig`
- **WASM export:** `zigpdf_generate_order_email(json_ptr, json_len, out_len) -> ptr`
- **TS helper:** `module.generateOrderEmail(jsonString) -> OrderEmailEnvelope`
  (`integrations/nextjs/zigpdf-loader.ts`)
- **Build:** `zig build wasm` → `zig-out/lib/zigpdf.wasm`
- **Tests:** `zig build test` (11 cases in `src/order_email.zig`)

## Why

One Stripe account (`QUANTUM ENCODING LTD`, `acct_1SOZqPEeBZaxUZah`) backs every
Quantum-Encoding app, so one webhook receives **all** events. The old generator
emitted the Lutuno template for every event — a £10 Exact credit top-up went out
Lutuno-branded with "we'll email tracking once it ships". This generator routes
by `metadata.app` and **never** falls back to Lutuno for an unknown app.

## Contract

This is a **pure, stateless** function: normalized JSON in → JSON envelope out.
It performs no Stripe API calls and keeps no state — **event-id idempotency
stays in your webhook** (dedupe before/after calling; the envelope echoes back
`event_id` and `order_ref` to help).

### Input (you normalize the Stripe event into this)

| field | from (Stripe) | notes |
|---|---|---|
| `event_id` | `event.id` | echoed back for idempotency |
| `session_id` | `session.id` | drives the deterministic `order_ref` |
| `payment_intent_id` | `session.payment_intent` | `order_ref` fallback |
| `app` | `session.metadata.app` | primary discriminator |
| `product_app` | `line_items[0].price.product` → `product.metadata.app` | fallback when session untagged — **you must expand the product** |
| `product_kind` | `product.metadata.kind` | informational (`credit_pack` / `app_unlock`) |
| `customer_email` | `session.customer_details.email` | recipient |
| `customer_name` | `session.customer_details.name` | optional greeting |
| `amount_total` | `session.amount_total` | **minor units** (e.g. 1000 = £10.00) |
| `currency` | `session.currency` | `gbp`/`eur`/`usd`/`jpy`… |
| `credits` | `session.metadata.credits` | digital apps |
| `pack` | `session.metadata.pack` | `starter`/`team`/`scale` |
| `user_id` | `session.metadata.user_id` | passthrough |
| `site` | `session.metadata.site` | Exact two-domain CTA deep-link |
| `shipping_country` | shipping address country (ISO-2) | **Lutuno entity** |
| `billing_country` | billing address country (ISO-2) | Lutuno entity fallback |
| `from_email_override` | — | force the sender (see registry TODOs) |
| `cta_url_override` | — | force the CTA target |
| `legal_entity_name` | — | override footer entity (white-label / per-tenant) |
| `legal_entity_company_number` | — | override; used with `legal_entity_name` |
| `legal_entity_address` | — | override registered office (single line) |
| `legal_entity_note` | — | override descriptor, e.g. "Private Company Limited by Shares" |
| `line_items` | expanded line items | `[{label, quantity, amount_total}]` — Lutuno |

### Output envelope (discriminated on `action`)

**send** — mail the customer:
```json
{ "action":"send", "app":"exact",
  "from_name":"Exact", "from_email":"orders@exactpdfconverter.com",
  "to":"buyer@example.com", "subject":"Your Exact credits are ready",
  "order_ref":"EXA-...", "legal_entity":"Quantum Encoding Ltd",
  "legal_entity_company_number":"16575953",
  "legal_entity_address":"33 Oxford Street, Coalville, LE67 3GS",
  "is_physical":false, "event_id":"evt_...", "html":"<!DOCTYPE html>..." }
```

**skip** — do nothing (unknown/untagged app — **never** Lutuno):
```json
{ "action":"skip",
  "reason":"unknown or untagged app for this session; no email sent",
  "app":"", "order_ref":null, "event_id":"evt_...", "html":null }
```

The function returns `null` (and sets `zigpdf_get_error`) only on a hard error
(invalid UTF-8 / malformed JSON / OOM). An unknown app is a successful `skip`.

## Routing logic

```
app = input.app  (if empty) -> input.product_app
tmpl = REGISTRY[app]  (if not found) -> { action: "skip" }   // NEVER Lutuno
render(tmpl) ; envelope = { action:"send", from, to, subject, html, ... }
```

## Registry

| app | brand | physical? | sender (`from_email`) | CTA target | order ref |
|---|---|---|---|---|---|
| `exact` | Exact | no | `orders@exactpdfconverter.com` | `…/account` (or `metadata.site`) | `EXA-` |
| `quantify` | Quantify | no | `receipts@quantumencoding.io` | `quantumencoding.io/quantify` | `QFY-` |
| `kitchenshare` | Kitchen Share | no | `receipts@quantumencoding.io` (interim) | — (TODO when live) | `KSH-` |
| `qai` | qai | no | `receipts@quantumencoding.io` | — (CLI, no account page) | `QAI-` |
| `lutuno` | Lutuno | **yes** | `orders@lutuno.com` | `app.lutuno.com` | `LUT-` |

Sender rationale (confirmed against the actual projects):
- **exact** has its own domain → `orders@exactpdfconverter.com`. Checkout already
  tags `metadata.app='exact'` (+ `credits`/`pack`/`user_id`).
- **quantify** and **qai** are products on `quantumencoding.io` (quantify = a
  sub-path; qai = a CLI), so they send from the shared
  `receipts@quantumencoding.io` identity (Quantum Encoding Ltd), not a per-app
  domain.
- **kitchenshare** has its own domain (`kitchen-share.net`) but mail is not live
  yet, so it sends from `receipts@quantumencoding.io` for now — switch to
  `orders@kitchen-share.net` once DNS/DKIM are up.
- **lutuno** has no checkout built yet; sender `orders@lutuno.com`, CTA to the
  customer dashboard `app.lutuno.com`.

Any sender or CTA can still be overridden per-call via `from_email_override` /
`cta_url_override` without a rebuild.

> Note: the existing ecosystem webhook routes by **Stripe product ID**
> (`getLicenseTypeFromProduct`), not `metadata.app`. That's fine — map the
> product to an app and pass it as `product_app`; the generator's fallback
> (`app` → `product_app` → skip) handles it.

## Legal-entity split (VAT-relevant)

- **Digital apps** (exact/quantify/kitchenshare/qai) — sold on the main English
  account → **Quantum Encoding Ltd** (always).
- **Lutuno** (dropshipping) — by ship-to country (else bill-to):
  - `GB` → **Quantum Encoding Ltd** (UK)
  - any other / unknown → **Quantum Encoding Europe Limited** (Ireland, EU default)

The footer prints the entity name, company number and registered office:

| entity | company no. | registered office |
|---|---|---|
| Quantum Encoding Ltd | 16575953 | 33 Oxford Street, Coalville, LE67 3GS |
| Quantum Encoding Europe Limited | 807205 | The Black Church, St. Mary's Place, Dublin, Ireland, D07 P4AX (Private Company Limited by Shares) |

These details are **configurable per-call**: pass `legal_entity_name` (+
`legal_entity_company_number` / `legal_entity_address` / `legal_entity_note`) in
the input to fully override the footer entity — e.g. a white-label / per-tenant
deployment supplying its own company details. When omitted, the resolved QE
entity above is used.

## Webhook usage (Next.js / edge)

```ts
import { loadZigPdf } from './integrations/nextjs/zigpdf-loader';

// after verifying the Stripe signature and deduping event.id:
const session = event.data.object; // checkout.session.completed
// expand line_items[0].price.product yourself if session.metadata.app is unset
const input = {
  event_id: event.id,
  session_id: session.id,
  payment_intent_id: session.payment_intent,
  app: session.metadata?.app ?? '',
  product_app: productMetadataApp ?? '',
  customer_email: session.customer_details?.email ?? '',
  customer_name: session.customer_details?.name ?? '',
  amount_total: session.amount_total ?? 0,
  currency: session.currency ?? 'gbp',
  credits: Number(session.metadata?.credits ?? 0),
  pack: session.metadata?.pack ?? '',
  user_id: session.metadata?.user_id ?? '',
  site: session.metadata?.site ?? '',
  shipping_country: session.shipping_details?.address?.country ?? '',
  billing_country: session.customer_details?.address?.country ?? '',
  // from_email_override: 'orders@quantify.example', // until baked in
};

const mod = await loadZigPdf();
const env = mod.generateOrderEmail(JSON.stringify(input));
if (env.action === 'send') {
  await sendMail({ from: `${env.from_name} <${env.from_email}>`, to: env.to,
                   subject: env.subject, html: env.html });
} // else: skip — log and do nothing (do NOT send a Lutuno email)
```

Each sibling app's webhook should also gate to its own `metadata.app` so it
never mis-credits another app's order (Exact already does this).
