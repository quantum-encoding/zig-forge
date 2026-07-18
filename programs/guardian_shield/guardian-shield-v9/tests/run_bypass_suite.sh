#!/usr/bin/env bash
# run_bypass_suite.sh - drive the Guardian Shield v9 external-vector bypass test.
#
# Proves the kernel LSM blocks the direct-syscall bypasses that defeat userspace
# libwarden. Confirmed live on kernel 6.18 (BPF-LSM): every destructive vector
# (glibc unlink, raw syscall unlinkat, openat2+O_TRUNC, io_uring UNLINKAT,
# renameat2, openat2 create) returns EPERM/EACCES for an agent-tagged process,
# while a non-agent process is unaffected.
#
# Preconditions:
#   - CONFIG_BPF_LSM on, `bpf` in /sys/kernel/security/lsm.
#   - guardian_shield_loader is RUNNING with $PROTECTED_DIR covered by its
#     protected_paths, and the agent basename (default "claude") present in
#     config.json agent_exes.
#   - Run as an UNPRIVILEGED user. Enforcement is agent-only, and running
#     setup + attack as the same non-root user keeps the victim files owned by
#     the test user (the delete/rename/truncate vectors need existing,
#     user-owned targets - otherwise a failure would be ENOENT/EPERM-on-owner,
#     not the LSM).
#
# Agent tagging is by the RESOLVED exe's dentry leaf name, so a symlink named
# "claude" would NOT tag the process (its dentry leaf is still gs_bypass_test) -
# that symlink-spoof resistance is a feature, not a limitation. To run "as an
# agent" we therefore exec a REAL FILE whose basename is a configured agent (a
# plain copy of the harness binary).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${GS_BYPASS_BIN:-$HERE/../zig-out/bin/gs_bypass_test}"
PROTECTED_DIR="${1:-$HOME/gs_test_protected}"   # MUST be covered by loader protected_paths
SCRATCH_DIR="${2:-$HOME/gs_test_scratch}"       # must NOT be protected
AGENT_NAME="${GS_AGENT_NAME:-claude}"           # must be in config.json agent_exes

if [[ ${EUID} -eq 0 ]]; then
  echo "ERROR: run as an unprivileged user, not root." >&2
  echo "       Enforcement is agent-only, and setup/attack must share ownership" >&2
  echo "       of the victim files." >&2
  exit 2
fi
if [[ ! -x "$BIN" ]]; then
  echo "harness not built: $BIN (run: zig build test-harness)" >&2
  exit 1
fi

# Agent launcher = a real file whose basename matches a configured agent.
AGENT_DIR="$(mktemp -d)"
AGENT_BIN="$AGENT_DIR/$AGENT_NAME"
cp "$BIN" "$AGENT_BIN"
cleanup() { rm -rf "$AGENT_DIR"; }
trap cleanup EXIT

# Reset to fresh, user-owned dirs so no stale or wrong-owner state can skew the
# result.
rm -rf "$PROTECTED_DIR" "$SCRATCH_DIR"
mkdir -p "$PROTECTED_DIR" "$SCRATCH_DIR"

echo "=== 1. NEGATIVE: agent context vs protected dir '$PROTECTED_DIR' (expect ALL BLOCKED) ==="
# Victims created by THIS (non-agent) shell: they exist and are user-owned, the
# explicit precondition for the delete/rename/truncate vectors.
"$BIN" --dir "$PROTECTED_DIR" --mode setup
set +e
"$AGENT_BIN" --dir "$PROTECTED_DIR" --mode attack --expect blocked
NEG_RC=$?
set -e

echo
echo "=== 2. POSITIVE control: non-agent context vs scratch dir '$SCRATCH_DIR' (expect ALL ALLOWED) ==="
"$BIN" --dir "$SCRATCH_DIR" --mode setup
set +e
"$BIN" --dir "$SCRATCH_DIR" --mode attack --expect allowed
POS_RC=$?
set -e

echo
echo "=== RESULT ==="
if [[ $NEG_RC -eq 0 && $POS_RC -eq 0 ]]; then
  echo "PASS: kernel LSM blocked every bypass vector for the agent subtree, and"
  echo "      allowed the non-agent control."
  exit 0
else
  echo "FAIL: negative_rc=$NEG_RC positive_rc=$POS_RC (see per-vector output above)"
  echo "      (the negative test requires \$PROTECTED_DIR to be in the loader's"
  echo "       protected_paths and the loader to be running)"
  exit 1
fi
