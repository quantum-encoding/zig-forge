#!/bin/sh
# Throwaway hook to capture a CLI's tool-event stdin payload, so chronos-hook's
# field extraction can be matched to that CLI's schema.
#
# Usage: register this as a PostToolUse hook (Gemini: PostToolUse or
# PostInvocation; Codex: PostToolUse) in that CLI's hook config, trigger ONE tool
# call (e.g. read a file / run a command), then inspect $CHRONOS_DUMP_OUT.
# Remove the hook afterwards — this is for discovery only.
#
# Each invocation appends the raw stdin payload + a separator, so multiple tool
# calls accumulate for comparison.
out="${CHRONOS_DUMP_OUT:-/tmp/chronos-hook-payload.jsonl}"
cat >> "$out"
printf '\n----8<----\n' >> "$out"
exit 0
