# StreamEvent fixtures

JSONL fixtures replayed by `FakeProvider` (`src/fake_provider.zig`) to
drive the agent loop's streaming bridge without real HTTP. Each
fixture is one provider turn's worth of events.

## Line format

One JSON object per line. The `kind` field discriminates; remaining
fields populate the matching `StreamEvent` variant from
`http_sentinel/src/ai/common.zig:782`.

```
{"kind":"text_delta",       "index":<u32>, "text":"..."}
{"kind":"tool_use_start",   "index":<u32>, "id":"...", "name":"..."}
{"kind":"tool_input_delta", "index":<u32>, "partial_json":"..."}
{"kind":"block_stop",       "index":<u32>}
{"kind":"message_stop",     "stop_reason":"end_turn"|"tool_use"|null,
                            "input_tokens":<u32>, "output_tokens":<u32>}
```

Blank lines and lines starting with `#` are ignored — handy for
comments inside a fixture.

## Authoring rules

- One event per line. Use `\n` escapes for newlines inside text.
- `index` is the content-block index (0-based). Text blocks and
  tool_use blocks share the same index namespace.
- `message_stop` terminates the turn. `FakeProvider` does not
  synthesise a `Done` event — that's the agent-loop's job, exactly
  as it is for real providers.
- A fixture with no `tool_use_*` events represents a single-turn
  conversation: agent loop returns after persisting the assistant
  message. A fixture with tool_use events would loop back into a
  follow-up turn (which currently requires multiple fixtures
  chained — see "Multi-turn" below).

## Multi-turn

Not in v1. The substrate proves one turn at a time. Chained fixtures
(one file per turn, harness loads them in sequence) are a follow-up
once the agent loop's per-provider dispatch is generalized to accept
a `FakeProvider` instance.

## Faithful replay is deliberate

`FakeProvider` does **not** validate event ordering, block-index
hygiene, or whether `message_stop` arrives last — it replays the
fixture verbatim. This is by design, not a gap: adversarial fixtures
that script contract violations (a `block_stop` for an unopened
index, a `message_stop` mid-stream, a `tool_input_delta` with no
preceding `tool_use_start`) are how the agent loop and MessageLog
get tested against the kinds of misbehavior real providers
occasionally produce. A fake that refuses to misbehave can't test
your handling of a misbehaving real one. Field-level *type*
mismatches (e.g. `"input_tokens": 8.0` where an integer is expected)
**do** hard-fail at parse time with a line number — that's a fixture
authoring bug, not an adversarial script.
