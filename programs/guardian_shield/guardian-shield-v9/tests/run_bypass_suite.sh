#!/usr/bin/env bash
# run_bypass_suite.sh - drive the Guardian Shield v9 external-vector bypass test.
#
# This proves the kernel LSM layer blocks the direct-syscall bypasses that
# defeat the userspace libwarden. It must run on a host where:
#   - CONFIG_BPF_LSM is on and `bpf` is in /sys/kernel/security/lsm
#   - the guardian_shield_loader is running with the test dir protected AND the
#     harness basename listed in agent_exes (so THIS process tree is tagged).
#
# Because tagging is by exe basename, the simplest way to run the harness "as an
# agent" is to invoke it through a symlink named like a configured agent (e.g.
# `claude`). This script does that automatically.
#
# It does NOT modify the running kernel by itself and refuses to run bare `rm`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${GS_BYPASS_BIN:-$HERE/../zig-out/bin/gs_bypass_test}"
PROTECTED_DIR="${1:-/home/founder/Documents/gs_test}"
SCRATCH_DIR="${2:-/tmp/gs_scratch}"
AGENT_NAME="${GS_AGENT_NAME:-claude}"   # must be present in config.json agent_exes

if [[ ! -x "$BIN" ]]; then
  echo "harness not built: $BIN (run: zig build test-harness)" >&2
  exit 1
fi

# Agent-context launcher: a symlink whose basename matches a configured agent.
AGENT_LINK="$(mktemp -d)/$AGENT_NAME"
ln -sf "$BIN" "$AGENT_LINK"

echo "=== 1. NEGATIVE test: agent context against protected dir (expect ALL BLOCKED) ==="
mkdir -p "$PROTECTED_DIR"
# Victims must be created by a NON-agent context (this shell is not tagged).
"$BIN" --dir "$PROTECTED_DIR" --mode setup
# Attack via the agent-named symlink -> the loader tags this subtree AGENT.
set +e
"$AGENT_LINK" --dir "$PROTECTED_DIR" --mode attack --expect blocked
NEG_RC=$?
set -e

echo
echo "=== 2. POSITIVE control: non-agent context against scratch dir (expect ALL ALLOWED) ==="
mkdir -p "$SCRATCH_DIR"
"$BIN" --dir "$SCRATCH_DIR" --mode setup
set +e
"$BIN" --dir "$SCRATCH_DIR" --mode attack --expect allowed
POS_RC=$?
set -e

echo
echo "=== RESULT ==="
if [[ $NEG_RC -eq 0 && $POS_RC -eq 0 ]]; then
  echo "PASS: kernel LSM blocked every bypass vector for agents, and allowed the non-agent control."
  exit 0
else
  echo "FAIL: negative_rc=$NEG_RC positive_rc=$POS_RC (see per-vector output above)"
  exit 1
fi
