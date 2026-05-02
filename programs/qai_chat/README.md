# qai

A pure-Zig terminal chat client and agent for Anthropic, OpenAI, Grok,
Gemini, and DeepSeek. Streams every turn, executes tools locally with
explicit approval, tracks token cost per session, and saves a markdown
transcript of every conversation grouped by project.

```
$ qai "What is Zig in one sentence?"
qai · provider=anthropic · model=claude-sonnet-4-6 · base_url=https://api.anthropic.com
Zig is a low-level, statically-typed systems language designed as a
modern replacement for C — no hidden control flow, manual memory, and
compile-time metaprogramming.
[turn 1: 14 in / 49 out · $0.0008]
```

## Why

Built primarily as a Claude Code-style CLI that doesn't drag a Node
runtime around. Concrete numbers from the same machine:

| Tool                  | Binary | RSS during streaming agent loop |
|-----------------------|--------|-----|
| Claude Code (Node/Ink)| n/a    | ~400 MB / worker (10 workers ≈ 4 GB) |
| **qai**               | **1.4 MB ReleaseFast** | **~10 MB** |

Same UX, ~40× lighter per process. All five providers, six tools, and
the agent loop go through one streaming event surface.

## Quick start

Requires Zig 0.16.0.

```sh
# build
cd programs/qai_chat
zig build -Doptimize=ReleaseFast

# point an API key at the matching env var
export ANTHROPIC_API_KEY=sk-ant-...
# or OPENAI_API_KEY, XAI_API_KEY, GEMINI_API_KEY, DEEPSEEK_API_KEY

# one-shot
./zig-out/bin/qai "Hello"

# REPL
./zig-out/bin/qai

# agent mode with tool calling
./zig-out/bin/qai --tools "List the files in src/ and tell me what they do"
```

## Providers

All five accept a `--provider=NAME` override and per-provider config in
`qai.toml`. Defaults shown:

| Name        | Default model                  | Default endpoint                                  |
|-------------|--------------------------------|----------------------------------------------------|
| `anthropic` | `claude-sonnet-4-6`            | `https://api.anthropic.com`                       |
| `openai`    | `gpt-5.4`                      | `https://api.openai.com/v1`                        |
| `grok`      | `grok-4-1-fast-non-reasoning`  | `https://api.x.ai/v1`                              |
| `gemini`    | `gemini-2.5-flash`             | `https://generativelanguage.googleapis.com/v1beta` |
| `deepseek`  | `deepseek-chat`                | `https://api.deepseek.com/anthropic`               |

Switch mid-session with `/provider NAME`. The API key is re-resolved
per turn so different providers can use different keys without restart.

## Tools

Six tools, three read-only (no prompt) and three writable (gated):

| Tool         | Approval | What it does                                            |
|--------------|----------|---------------------------------------------------------|
| `read_file`  | auto     | Read a file (capped at 16 KB)                           |
| `ls`         | auto     | List a directory (capped at 200 entries)                |
| `grep`       | auto     | Recursive substring search with optional file glob       |
| `write_file` | y/a/N    | Create or overwrite a file (1 MB cap)                   |
| `edit_file`  | y/a/N    | Exact-string replacement; refuses non-unique matches    |
| `bash`       | y/a/r/N  | Run via `/bin/sh -c`; cwd + danger badge before approval|

### Approval flow

When the model invokes a writable tool, qai prints a preview and prompts:

```
[bash] $ rm -rf /tmp/foo    (cwd: /Users/director/work/zig-forge)
[!DANGER] recursive force-delete
Proceed? [y]es / [a]lways exact / [r]ule "rm *" / [N]o:
```

- `y` — allow this one call.
- `a` — allow + remember this exact path / command for the rest of the session.
- `r` (bash only) — install a prefix rule on the first whole token, e.g. `r`
  on `git status -s` auto-approves any future `git ...` command but not `github`.
- `N` (or empty / EOF) — deny. The model gets a "user declined" tool result
  and adapts.

Approvals persist between runs at `.qai/approvals` (project-local). Use
`/forget` to clear.

`--yes / -y` auto-approves all writable tool calls — use only for trusted
scripted runs. Each auto-approved call still prints an `[auto-approve]` trace.

The danger badge flags `rm -rf`, `sudo`, `curl|sh`, `git push --force`,
`chmod -R 777`, `dd if=`, `kill -9`, fork bombs, and similar foot-guns.

## Slash commands

Inside the REPL:

| Command                | Effect                                                          |
|------------------------|-----------------------------------------------------------------|
| `/help`                | List slash commands                                             |
| `/quit`, `/exit`       | Exit (auto-save fires)                                          |
| `/clear`, `/reset`     | Start a new conversation (history + usage reset)                |
| `/history`             | Show turn count + last 6 message previews                       |
| `/tools`               | List all available tools with descriptions                      |
| `/model [ID]`          | Show current model, or switch to ID                             |
| `/provider [NAME]`     | Show or switch provider; default model swaps too                |
| `/approvals`           | List session approvals (paths, exact commands, prefix rules)    |
| `/forget`              | Clear all approvals (in-memory and on-disk)                     |
| `/save [PATH]`         | Save transcript; default path is the auto-save location         |
| `/load PATH`           | Replace history with the transcript at PATH (`~/` expanded)     |
| `/sessions`            | List past transcripts for this project, newest first            |
| `/usage`               | Show running tokens + cost; per-provider breakdown if mixed     |

## CLI

```
qai [flags] [prompt]
qai usage [--project=PATH] [--since=YYYYMMDD] [--by-provider]
```

Flags:

| Flag              | Effect                                                         |
|-------------------|----------------------------------------------------------------|
| `--config=PATH`   | Use the given config file (default `./qai.toml`, then `~/.config/qai/config.toml`) |
| `--provider=NAME` | Override provider (also swaps default model unless `--model` set) |
| `--model=ID`      | Override model id                                              |
| `--max-tokens=N`  | Override max output tokens                                     |
| `--reasoning=LVL` | OpenAI/Grok reasoning effort: `minimal` / `low` / `medium` / `high` / `xhigh` |
| `--tools`         | Enable tool calling                                            |
| `--yes`, `-y`     | Auto-approve all writable tool calls                           |

If `[prompt]` is given, qai answers once and exits. Otherwise it enters
the REPL.

### `qai usage`

Aggregates `~/.qai/usage/*.csv` into a cost table. Skips chat mode
entirely — works without any API keys configured.

```
$ qai usage
PROJECT                                    TURNS   IN_TOKENS  OUT_TOKENS         COST
─────────────────────────────────────────  ─────  ──────────  ──────────   ──────────
-Users-director-work-poly-repo-zig-forge      87        12450         3024  $   1.2400
-tmp-qai_layout                                 3          196            5  $   0.0001
─────────────────────────────────────────  ─────  ──────────  ──────────   ──────────
TOTAL                                          90        12646         3029  $   1.2401

$ qai usage --by-provider
PROVIDER/MODEL                    TURNS   IN_TOKENS  OUT_TOKENS         COST
────────────────────────────────  ─────  ──────────  ──────────   ──────────
anthropic/claude-sonnet-4-6           70         9800         2200  $   1.1200
openai/gpt-5.4                        15         2200          700  $   0.1100
grok/grok-4-1-fast-non-reasoning       5          646          129  $   0.0101
────────────────────────────────  ─────  ──────────  ──────────   ──────────
TOTAL                                 90        12646         3029  $   1.2401
```

`--since=YYYYMMDD` filters by the session timestamp prefix. `--project=PATH`
narrows to one project — accepts either an absolute path (sanitized for
you) or the raw key as it appears under `~/.qai/usage/`.

## On-disk layout

```
$PROJECT/
  .qai/
    approvals               # per-project tool approvals (writable-tool y/a/r records)

~/.qai/
  projects/
    -Users-director-work-poly-repo-zig-forge/
      20260501-103418-anthropic.md
      20260501-103552-grok.md
      ...
  usage/
    -Users-director-work-poly-repo-zig-forge.csv
    ...
```

`.qai/approvals` is project-local because the trust decisions are
per-repo. Conversations and cost logs go in `~/.qai/` keyed by the
sanitized cwd path (mirrors the `~/.claude/projects/` layout — `/`
becomes `-`, the macOS `/private` prefix is stripped).

The usage CSV is grep / awk friendly:

```sh
# total $ spent in this repo, ever
awk -F, 'NR>1 {sum+=$7} END {printf "$%.4f\n", sum}' \
  ~/.qai/usage/-Users-director-work-poly-repo-zig-forge.csv

# sessions per provider this month
awk -F, 'NR>1 && $1 ~ /^202605/ {p[$2]++} END {for(k in p) print k, p[k]}' \
  ~/.qai/usage/*.csv
```

One row is appended per `(provider, model)` bucket per session, so a
`/provider`-switch mid-session attributes spend correctly.

## Config

See [`qai.example.toml`](qai.example.toml) for the full annotated
template. Every field is optional — the defaults match what you'd get
without a config file. Common tweaks:

```toml
provider = "openai"
reasoning_effort = "medium"

[deepseek]
# DeepSeek mirrors input language; force English here if you want it
# even when prompts arrive in another language.
system_prompt = "Always respond in English. Be concise."

# Route Anthropic traffic through your own backend without changing
# anything else. The backend must speak Anthropic's v1 wire format.
# [anthropic]
# base_url = "https://api.quantumencoding.ai/qai/v1/proxy/anthropic"
# api_key_env = "QAI_TOKEN"
```

Resolution order for a per-turn `system_prompt`:
per-provider override → global → default agent prompt (only when `--tools`).

## Architecture

`qai_chat` is glue between two libraries already in this monorepo:

- **[`http_sentinel`](../http_sentinel)** — pure-Zig HTTP/2 + TLS client
  with provider-specific AI clients (Anthropic, OpenAI, Grok, Gemini,
  DeepSeek). Each client exposes `sendMessageStreamingWithEvents` that
  emits a unified `StreamEvent` (`text_delta`, `tool_use_start`,
  `tool_input_delta`, `block_stop`, `message_stop` with usage). The
  agent loop in `src/agent.zig` consumes those events the same way for
  every provider — only the per-turn HTTP call differs.

- The Zig stdlib's I/O — `std.Io.Threaded` for the event loop, `std.Io.File`
  for stdin / stdout / stderr, `std.Io.Dir` for filesystem, `std.json` for
  parsing the SSE event bodies.

There's no `link_libc`, no extern C, no FFI shim. One static binary,
no runtime dependencies.

### Source map

```
src/
  main.zig       # CLI parsing, REPL loop, slash commands, save/load,
                 # qai usage subcommand, project paths
  config.zig     # tiny TOML-ish parser + per-provider settings
  agent.zig     # streaming agent loop + tools dispatch + approvals
                 # + UsageStats (per-provider cost buckets)
  tools.zig     # 6 tools (read_file, ls, grep, write_file, edit_file, bash)
                 # + danger heuristics + glob matcher
  pricing.zig   # inlined model price table for cost estimation
```

## Roadmap

The CLI is feature-complete for direct-provider use. One known
follow-up:

- **Backend mode** for `https://api.quantumencoding.ai/qai/v1/agent` — a
  unified server-side endpoint that consolidates billing + capability
  gating + tool-spec normalization across all providers. The `base_url`
  switch already routes individual providers through a backend that
  speaks the upstream wire format; this would add a single normalized
  agent-loop endpoint with auth via per-user QAI tokens.

## License

Same as the surrounding monorepo.
