# Provider Quirks — Tool Calling

Hard-won lessons from client-side tool execution in the Tauri app.
These WILL bite you when implementing `/qai/v1/agent` with stateless round-trips.

---

## Anthropic

### 1. `additionalProperties: false` required recursively
The API rejects tool definitions unless **every** object in the JSON Schema has
`"additionalProperties": false` set. Not just the top level — recursively in
`properties`, `items`, and `anyOf`/`oneOf`/`allOf`.

**Fix:** Walk the schema tree before sending and inject the field at every object node.

### 2. `thinking` and `tool_choice: any` are mutually exclusive
If `tool_choice.type == "any"` (or `"tool"`), you cannot enable extended thinking.
Error: *"Thinking may not be enabled when tool_choice forces tool use"*.

**Fix:** Check `tool_choice.type` before setting thinking config. If forcing tool use,
disable thinking for that turn.

### 3. `strict: true` has a 20-tool limit
With 89 tools marked `strict: true`, the API returns *"Too many strict tools (89, max 20)"*.

**Fix:** Drop `strict: true` entirely. The recursive `additionalProperties` fix already
gives schema compliance. `strict` is opt-in, not required.

---

## Gemini

### 1. `cachedContent` conflicts with `tools` and `system_instruction`
If you pass `cachedContent` in the request, you **cannot** also pass `tools` or
`system_instruction` — they must be baked into the cache at creation time.

**Fix:** When building the cache, include tools (and `google_search` if using grounding).
When sending requests with the cache, strip `tools`/`system_instruction` from the body.

### 2. `includeServerSideToolInvocations: true` for mixed tools
When you mix `google_search`/`code_execution` (built-in) with custom function declarations,
you must set `toolConfig.includeServerSideToolInvocations: true` or the API rejects it.

### 3. `thought_signature` must be preserved verbatim
When Gemini returns thinking-enabled responses, the `parts` array contains opaque
`thought_signature` blobs. On the next turn, you MUST echo back the **exact raw parts**
from the previous model turn. Do not reconstruct a `functionCall` part from parsed fields.

**Fix:** Store `raw_model_parts` and pass them through unchanged on the next request.

---

## Implementation Notes for Zig

When implementing the stateless agent round-trip in stream.zig / agent.zig:

- **Anthropic tools:** Run `ensureNoAdditionalProperties()` on every tool schema before
  sending. Never set `strict: true` if tool count > 20.
- **Gemini turns:** Store the raw JSON `parts` array from each model response. When the
  client sends the next turn with tool results, the previous model turn's parts must be
  included verbatim (not reconstructed from parsed content).
- **Tool choice:** When `tool_choice` forces tool use (`.required`), skip any thinking/
  reasoning config on that turn.

---

*Source: Vibing with Grok Tauri app debugging, April 2026.*
