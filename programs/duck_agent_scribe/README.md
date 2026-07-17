# duck-agent-scribe

A command-line tool that maintains an append-only "eternal log" for spawned
agents, recording each agent's lifecycle as JSON manifests and plain-text logs
on disk under `~/eternal-logs/agents-crucible/<batch-id>/`.

## What it does

`duckagent-scribe` is a CLI (single executable, no library/FFI surface). Each
command reads/writes files beneath `$HOME/eternal-logs/agents-crucible/`:

| Command | Effect |
|---|---|
| `init` | Create an agent log directory + `manifest.json` (status `RUNNING`) and `init.log`. Supports retries via `--retry-number`. |
| `log` | Append a turn message to `turn-NNN.log` for an existing agent. |
| `complete` | Write `result.log` and update the agent's `manifest.json` `execution.status` to `SUCCESS`/`FAILED` with a `completed_at` timestamp. |
| `batch-complete` | Write a batch-level `manifest.json` with total/succeeded/failed counts and a computed success rate. |
| `query` | Scan all (or one) batch, filter by agent id / status, and print a table of matching manifests. |
| `lineage` | Print the retry chain (Initial, Retry-1, …) for one agent, sorted by retry number. |
| `version` | Print the tool version. |

Timestamps are UTC ISO-8601 (`YYYY-MM-DDTHH:MM:SS.mmmZ`) derived from the wall
clock via `clock_gettime(REALTIME)` and the standard-library proleptic
Gregorian calendar. A per-invocation `TICK-NNNNNNNNNN` identifier is derived
from the same clock and used in the agent directory name.

All JSON is emitted with `std.json.Stringify`, so caller-controlled strings
(task descriptions, ids, paths) are escaped rather than interpolated into a
format string.

## Build

Requires Zig 0.16.0.

```sh
zig build            # build the executable
zig build run -- version
zig build test       # run the test suite
```

The binary is named `duckagent-scribe`.

## Example

```sh
duckagent-scribe init --agent-id 001 --batch-id batch-20251024-140812 \
  --task "Write blog post" --provider grok --max-turns 50 \
  --retry-number 0 --pid 12345

duckagent-scribe log --agent-id 001 --batch-id batch-20251024-140812 \
  --turn 1 --message "Started task"

duckagent-scribe complete --agent-id 001 --batch-id batch-20251024-140812 \
  --status SUCCESS --turns-taken 1 --tokens-used 3986

duckagent-scribe query --batch-id batch-20251024-140812 --status FAILED
duckagent-scribe lineage --agent-id 001 --batch-id batch-20251024-140812
```
