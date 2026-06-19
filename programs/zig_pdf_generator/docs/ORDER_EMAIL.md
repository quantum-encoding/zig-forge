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
| `line_items` | expanded line items | `[{label, quantity, amount_total}]` — Lutuno |

### Output envelope (discriminated on `action`)

**send** — mail the customer:
```json
{ "action":"send", "app":"exact",
  "from_name":"Exact", "from_email":"orders@exactpdfconverter.com",
  "to":"buyer@example.com", "subject":"Your Exact credits are ready",
  "order_ref":"EXA-...", "legal_entity":"Quantum Encoding Ltd",
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

| app | brand | physical? | sender (`from_email`) | order ref |
|---|---|---|---|---|
| `exact` | Exact | no | `orders@exactpdfconverter.com` | `EXA-` |
| `quantify` | Quantify | no | ⚠️ `orders@CONFIGURE-ME.invalid` | `QFY-` |
| `kitchenshare` | Kitchen Share | no | ⚠️ `orders@CONFIGURE-ME.invalid` | `KSH-` |
| `qai` | qai | no | ⚠️ `orders@CONFIGURE-ME.invalid` | `QAI-` |
| `lutuno` | Lutuno | **yes** | `orders@lutuno.com` | `LUT-` |

⚠️ The three digital apps whose sender domains are not yet confirmed point at a
`.invalid` placeholder **on purpose** — an un-overridden send will fail loudly at
the mail layer rather than send from a real-but-wrong domain. Until the real
domains are baked into `src/order_email.zig`, pass `from_email_override` from the
webhook. (Decided: per-app domain senders; digital apps must **not** send as
`orders@lutuno.com`.)

## Legal-entity split (VAT-relevant)

- **Digital apps** (exact/quantify/kitchenshare/qai) — sold on the main English
  account → **Quantum Encoding Ltd** (always).
- **Lutuno** (dropshipping) — by ship-to country (else bill-to):
  - `GB` → **Quantum Encoding Ltd** (UK)
  - any other / unknown → **Quantum Encoding Europe Limited** (Ireland, EU default)

> TODO: add each entity's registered office address + company number to the
> email footer (`renderHtml` footer in `src/order_email.zig`).

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
