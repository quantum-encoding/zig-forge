#!/usr/bin/env bash
# supplychain_sim.sh - prove Guardian Shield v9's credential-harvest block against
# the 2025-26 npm/PyPI supply-chain threat (Shai-Hulud / s1ngularity shape):
# a malicious postinstall runs as a build-tool DESCENDANT and READS credential
# files (~/.aws, ~/.ssh, tokens) to exfiltrate them.
#
# The deny is SCOPED to build-tool-tainted subtrees (and AI-agent subtrees), so a
# NORMAL process/user reading their OWN creds is unaffected - that's the whole
# point (no false positives on legitimate ssh/git/aws use).
#
# VM-ONLY (reads throwaway seeded creds). Refuses unless GS_VM_TEST=1.
#
# TWO PHASES (a tainted process can't seed into a protected dir; seed with the
# credential guard's targets pre-created):
#   sudo? no - run as the TEST USER (creds live in the user's home):
#     GS_VM_TEST=1 ./supplychain_sim.sh --setup    # shield down OR up; seeds ~/.aws etc.
#     <load the shield with credential_paths + build_exes configured>
#     GS_VM_TEST=1 ./supplychain_sim.sh --attack
#
# Expected --attack result:
#   NORMAL (untainted) reader        -> crown jewels ALLOWED (no false positive)
#   TAINTED (npm-named) reader       -> crown jewels DENIED (EPERM)  <-- the block
#   TAINTED-INHERITED (yarn->child)  -> crown jewels DENIED (sticky taint proof)
#   TAINTED reader of ~/.npmrc       -> ALLOWED (tiering: build-tool self-secret,
#                                       not a crown jewel)
set -uo pipefail

if [[ "${GS_VM_TEST:-}" != "1" ]]; then
  echo "REFUSING: reads throwaway seeded credentials - VM ONLY. Set GS_VM_TEST=1." >&2
  exit 3
fi
if [[ ${EUID} -eq 0 ]]; then
  echo "ERROR: run as the unprivileged TEST USER (creds live in \$HOME, and a" >&2
  echo "       user reading its own creds is the no-false-positive control)." >&2
  exit 2
fi

MODE="${1:-}"
case "$MODE" in
  --setup|setup)   MODE=setup ;;
  --attack|attack|"") MODE=attack ;;
  *) echo "usage: GS_VM_TEST=1 $0 [--setup|--attack]" >&2; exit 2 ;;
esac

# Crown-jewel targets (must match the loader's credential_paths for this user).
J_AWS="$HOME/.aws/credentials"
J_SSH="$HOME/.ssh/id_ed25519"
J_GH="$HOME/.config/gh/hosts.yml"
J_GIT="$HOME/.git-credentials"
# Benign build-tool self-secret - deliberately NOT a crown jewel (tiering).
B_NPMRC="$HOME/.npmrc"
CROWN=("$J_AWS" "$J_SSH" "$J_GH" "$J_GIT")

if [[ "$MODE" == setup ]]; then
  echo "seeding throwaway credentials in $HOME ..."
  mkdir -p "$HOME/.aws" "$HOME/.ssh" "$HOME/.config/gh"
  printf '[default]\naws_access_key_id=AKIAFAKE\naws_secret_access_key=fake\n' > "$J_AWS"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nFAKEKEYMATERIAL\n-----END OPENSSH PRIVATE KEY-----\n' > "$J_SSH"
  chmod 600 "$J_SSH"
  printf 'github.com:\n  oauth_token: ghp_FAKE\n' > "$J_GH"
  printf 'https://user:ghp_FAKE@github.com\n' > "$J_GIT"
  printf 'registry=https://registry.npmjs.org/\n_authToken=npm_FAKE\n' > "$B_NPMRC"
  mkdir -p "$HOME/gs_fake_project"
  echo "seeded: $J_AWS $J_SSH $J_GH $J_GIT (crown) + $B_NPMRC (benign)"
  echo "setup complete. Load the shield (credential_paths+build_exes), then --attack."
  exit 0
fi

# ------------------------------------------------------------------ --attack
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
CC="${CC:-cc}"

# Reader: open+read ONE path. exit 10=denied (EPERM/EACCES), 0=read ok, 11=other.
cat > "$WORK/cred_reader.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s PATH\n", argv[0]); return 2; }
    errno = 0;
    int fd = open(argv[1], O_RDONLY);              // the harvest: read-only open
    if (fd < 0) {
        int e = errno;
        printf("open denied errno=%d (%s)\n", e, strerror(e));
        return (e == EPERM || e == EACCES) ? 10 : 11;
    }
    char b[64];
    ssize_t n = read(fd, b, sizeof b);
    int e = errno; close(fd);
    if (n < 0) { printf("read denied errno=%d (%s)\n", e, strerror(e)); return (e == EPERM || e == EACCES) ? 10 : 11; }
    printf("HARVESTED %zd bytes\n", n);
    return 0;
}
EOF

# Launcher: fork + exec a child (to prove taint INHERITANCE across fork+exec).
cat > "$WORK/launcher.c" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s PROG [args...]\n", argv[0]); return 2; }
    pid_t p = fork();
    if (p == 0) { execv(argv[1], &argv[1]); perror("execv"); _exit(127); }
    int st; waitpid(p, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
EOF

"$CC" -O2 -o "$WORK/cred_reader" "$WORK/cred_reader.c" || { echo "compile cred_reader failed"; exit 4; }
"$CC" -O2 -o "$WORK/launcher"    "$WORK/launcher.c"    || { echo "compile launcher failed"; exit 4; }
# Build-tool-named copies: gs_exec tags by the resolved exe's dentry leaf, so the
# binary must literally be named `npm`/`yarn` (a shell script would leaf as bash).
cp "$WORK/cred_reader" "$WORK/npm"          # tainted-direct reader
cp "$WORK/cred_reader" "$WORK/harvester"    # inherited child (non-build basename)
cp "$WORK/launcher"    "$WORK/yarn"         # tainted launcher -> forks harvester

N_OK=0 N_FAIL=0
# expect BLOCKED|ALLOWED ; classify by exit code (10=blocked, else allowed/na).
check() {
  local desc="$1" expect="$2"; shift 2
  local out rc; out="$("$@" 2>&1)"; rc=$?
  local got verdict
  if [[ $rc -eq 10 ]]; then got=BLOCKED; else got=ALLOWED; fi
  if [[ "$got" == "$expect" ]]; then verdict=PASS; ((N_OK++)); else verdict="FAIL(!!)"; ((N_FAIL++)); fi
  printf "  %-42s expect=%-8s got=%-8s %-8s %s\n" "$desc" "$expect" "$got" "$verdict" "$out"
}

echo "=============================================================="
echo "Guardian Shield v9 - supply-chain credential-harvest simulation"
echo "user=$(id -un) home=$HOME"
echo "=============================================================="

echo
echo "### 1. NORMAL (untainted) reader - crown jewels must be ALLOWED (no false positive) ###"
for j in "${CROWN[@]}"; do check "normal read $(basename "$(dirname "$j")")/$(basename "$j")" ALLOWED "$WORK/cred_reader" "$j"; done
check "normal read .npmrc" ALLOWED "$WORK/cred_reader" "$B_NPMRC"

echo
echo "### 2. TAINTED (exe named 'npm') reader - crown jewels must be DENIED (the harvest block) ###"
for j in "${CROWN[@]}"; do check "npm read $(basename "$(dirname "$j")")/$(basename "$j")" BLOCKED "$WORK/npm" "$j"; done
echo "### 2b. TAINTED reader of ~/.npmrc must be ALLOWED (tiering: build-tool self-secret) ###"
check "npm read .npmrc (tiering)" ALLOWED "$WORK/npm" "$B_NPMRC"

echo
echo "### 3. TAINTED-INHERITED ('yarn' forks+execs 'harvester') - crown jewels DENIED (sticky taint) ###"
for j in "${CROWN[@]}"; do check "yarn->harvester read $(basename "$j")" BLOCKED "$WORK/yarn" "$WORK/harvester" "$j"; done

echo
echo "=============================================================="
echo "SUMMARY: pass=$N_OK  fail=$N_FAIL"
[[ $N_FAIL -gt 0 ]] && echo ">>> $N_FAIL FAIL(!!) - a real gap (harvest allowed, or false-positive on normal read)."
echo "=============================================================="
cat <<'NOTE'

TIERING (documented): only the crown-jewel AssetMap (~/.aws, ~/.ssh, gcloud/gh
tokens, git-credentials, ~/.claude, /root/.ssh) is read-denied for tainted/agent
subtrees. Build-tool self-secrets (~/.npmrc, ~/.pypirc, ~/.cargo/credentials) are
DELIBERATELY excluded - tools legitimately read them during install, and no build
tool legitimately reads your AWS/SSH keys. This is high-value + low-false-positive
for v1; a later version can add Metatron-style isBuildToolSecret handling.
This block is always-on for tainted/agent subtrees, independent of agent-
containment / hardening posture. It breaks the endpoint step of the harvest.
NOTE

[[ $N_FAIL -eq 0 ]] && exit 0 || exit 1
