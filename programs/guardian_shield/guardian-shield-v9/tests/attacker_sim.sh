#!/usr/bin/env bash
# attacker_sim.sh - honest measurement of Guardian Shield v9 HARDENING MODE
# against a NON-agent, NON-trusted attacker, in TWO privilege tiers:
#   (a) unprivileged user, (b) root (via sudo).
#
# This does NOT overstate. A userspace BPF-LSM cannot fully contain a determined
# root (see the "ROOT BOUNDARY" summary at the end). The goal is to raise the bar
# and MEASURE exactly how far runtime enforcement holds, truthfully.
#
# VM-ONLY. It performs (attempted) destructive ops on real critical paths and
# tries to load a kernel module / mount, so it refuses to run unless GS_VM_TEST=1.
#
# TWO PHASES (creating a file inside a critical path is itself blocked for the
# non-trusted sim once hardening is active, so victims must be seeded first):
#
#   Orchestration on the VM:
#     sudo GS_VM_TEST=1 ./guardian_shield_loader config.json --unpin   # shield off
#     sudo GS_VM_TEST=1 ./attacker_sim.sh --setup                      # seed victims
#     sudo ./guardian_shield_loader config.json    # load (hardening_mode=true)
#     GS_VM_TEST=1 ./attacker_sim.sh --attack                          # measure
#
# Env (absolute paths so setup-as-root and attack-in-both-tiers agree; defaults
# match config.json critical_paths):
#   GS_VM_TEST=1        required
#   GS_PIN_DIR          pin dir             (default /sys/fs/bpf/guardian_shield)
#   GS_SHIELD_DIR       shield install dir  (default /home/forge/v9)
#   GS_SSH_DIR          protected ssh dir   (default /home/forge/.ssh)
#   GS_CLAUDE_DIR       protected agent dir (default /home/forge/.claude)
set -uo pipefail   # NOT -e: attacks are EXPECTED to fail

if [[ "${GS_VM_TEST:-}" != "1" ]]; then
  echo "REFUSING: this harness performs destructive/tamper ops - VM ONLY." >&2
  echo "Set GS_VM_TEST=1 to run." >&2
  exit 3
fi

MODE="${1:-}"
case "$MODE" in
  --setup|setup)   MODE=setup ;;
  --attack|attack|"") MODE=attack ;;
  *) echo "usage: GS_VM_TEST=1 $0 [--setup|--attack]" >&2; exit 2 ;;
esac

PIN_DIR="${GS_PIN_DIR:-/sys/fs/bpf/guardian_shield}"
SHIELD_DIR="${GS_SHIELD_DIR:-/home/forge/v9}"
SSH_DIR="${GS_SSH_DIR:-/home/forge/.ssh}"
CLAUDE_DIR="${GS_CLAUDE_DIR:-/home/forge/.claude}"

# Victim files inside critical paths (absolute; created by --setup).
V_SSH="$SSH_DIR/gs_probe_victim"
V_CLAUDE="$CLAUDE_DIR/gs_probe_victim"
V_SHIELD="$SHIELD_DIR/gs_probe_victim"
V_SUDOERS="/etc/sudoers.d/gs_probe_victim"
V_BOOT="/boot/gs_probe_victim"

# NEW-FILE injection targets - these must NOT exist (the create test drops them
# fresh). --setup only ensures any stale ones are removed.
C_SSH="$SSH_DIR/gs_created"
C_CLAUDE="$CLAUDE_DIR/gs_created"
C_SUDOERS="/etc/sudoers.d/gs_created"

# ------------------------------------------------------------------
# --setup: seed the victim files. Run BEFORE the shield loads (or after
# --unpin), as root. Idempotent - stale victims are cleaned first.
# ------------------------------------------------------------------
if [[ "$MODE" == setup ]]; then
  echo "seeding probe victims (run this with the shield UNLOADED)..."
  seed_one() {  # <path> <content>
    local path="$1" content="$2" dir; dir="$(dirname "$path")"
    sudo mkdir -p "$dir" 2>/dev/null || true
    sudo rm -f "$path" 2>/dev/null || true
    if printf '%s\n' "$content" | sudo tee "$path" >/dev/null 2>&1; then
      echo "  seeded  $path"
    else
      echo "  FAILED  $path (is the shield still loaded? run --unpin first)"
    fi
  }
  seed_one "$V_SSH"     "guardian-shield probe victim"
  seed_one "$V_CLAUDE"  "guardian-shield probe victim"
  seed_one "$V_SHIELD"  "guardian-shield probe victim"
  seed_one "$V_SUDOERS" "# guardian-shield probe victim (valid sudoers.d comment)"
  seed_one "$V_BOOT"    "guardian-shield probe victim"
  # New-file injection targets must NOT exist for the create test.
  for cf in "$C_SSH" "$C_CLAUDE" "$C_SUDOERS"; do sudo rm -f "$cf" 2>/dev/null || true; done
  echo "  cleared new-file injection targets (create test drops them fresh)"
  echo "setup complete. Now load the shield in hardening mode, then run --attack."
  exit 0
fi

# ------------------------------------------------------------------
# --attack
# ------------------------------------------------------------------
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
CC="${CC:-cc}"

cat > "$WORK/fs_probe.c" <<'EOF'
// fs_probe <unlink-glibc|unlink-syscall|overwrite|create> <path>
// exit: 10 = blocked (EPERM/EACCES), 0 = op succeeded, 11 = other errno.
// `create` injects a NEW file (O_CREAT|O_EXCL) - the target must NOT pre-exist;
// this is the new-file-injection vector (drop a new authorized_keys/sudoers.d).
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s MODE PATH\n", argv[0]); return 2; }
    const char *m = argv[1], *p = argv[2];
    int rc = -1; errno = 0;
    if (!strcmp(m, "unlink-glibc"))        rc = unlink(p);
    else if (!strcmp(m, "unlink-syscall")) rc = (int)syscall(SYS_unlinkat, AT_FDCWD, p, 0);
    else if (!strcmp(m, "overwrite")) {
        int fd = open(p, O_WRONLY);              // no trunc/create: pure overwrite
        if (fd >= 0) { ssize_t w = write(fd, "TAMPER\n", 7); (void)w; close(fd); rc = 0; }
        else rc = -1;
    } else if (!strcmp(m, "create")) {
        int fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0644);   // fresh new file
        if (fd >= 0) { ssize_t w = write(fd, "INJECTED\n", 9); (void)w; close(fd); rc = 0; }
        else rc = -1;
    } else { fprintf(stderr, "bad mode\n"); return 2; }
    if (rc == 0) { printf("SUCCEEDED\n"); return 0; }
    int e = errno;
    printf("failed errno=%d (%s)\n", e, strerror(e));
    return (e == EPERM || e == EACCES) ? 10 : 11;
}
EOF

cat > "$WORK/bpf_probe.c" <<'EOF'
// bpf_probe <pin_path> : BPF_OBJ_GET the pinned link, then BPF_LINK_DETACH it.
// The gs_bpf hook blocks bpf() for non-trusted callers, so BPF_OBJ_GET itself
// should fail. exit: 10 = blocked (EPERM/EACCES), 0 = TAMPER SUCCEEDED, 11 = other.
#define _GNU_SOURCE
#include <errno.h>
#include <linux/bpf.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static int sys_bpf(int cmd, union bpf_attr *a) { return (int)syscall(SYS_bpf, cmd, a, sizeof(*a)); }
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s PIN\n", argv[0]); return 2; }
    union bpf_attr a; memset(&a, 0, sizeof(a));
    a.pathname = (unsigned long long)(unsigned long)argv[1];
    int fd = sys_bpf(BPF_OBJ_GET, &a);
    if (fd < 0) {
        int e = errno;
        printf("BPF_OBJ_GET failed errno=%d (%s)\n", e, strerror(e));
        return (e == EPERM || e == EACCES) ? 10 : 11;
    }
    union bpf_attr d; memset(&d, 0, sizeof(d));
    d.link_detach.link_fd = fd;
    int r = sys_bpf(BPF_LINK_DETACH, &d);
    if (r < 0) {
        int e = errno;
        printf("BPF_LINK_DETACH failed errno=%d (%s)\n", e, strerror(e));
        return (e == EPERM || e == EACCES) ? 10 : 11;
    }
    printf("BPF_LINK_DETACH SUCCEEDED - shield link detached!\n");
    return 0;
}
EOF

"$CC" -O2 -o "$WORK/fs_probe"  "$WORK/fs_probe.c"  || { echo "compile fs_probe failed"; exit 4; }
"$CC" -O2 -o "$WORK/bpf_probe" "$WORK/bpf_probe.c" || { echo "compile bpf_probe failed"; exit 4; }

# ------------------------------------------------------------------
# Result accounting.
# ------------------------------------------------------------------
N_BLOCKED=0 N_ALLOWED=0 N_NA=0
# Run a probe in a tier; classify by exit code (10=blocked, 0=allowed, else N/A).
# A target that was never seeded shows errno=2 (ENOENT) -> N/A, not a real result.
attack() {
  local desc="$1" tier="$2"; shift 2
  local out rc
  if [[ "$tier" == root ]]; then out="$(sudo -n "$@" 2>&1)"; rc=$?
  else out="$("$@" 2>&1)"; rc=$?; fi
  local verdict
  case $rc in
    10) verdict="BLOCKED"; ((N_BLOCKED++)) ;;
    0)  verdict="ALLOWED (!!)"; ((N_ALLOWED++)) ;;
    *)  verdict="N/A"; ((N_NA++)) ;;
  esac
  printf "  [%-4s] %-40s -> %-14s %s\n" "$tier" "$desc" "$verdict" "$out"
}

# Raw shell attack (module/mount): classify by errno text.
attack_shell() {
  local desc="$1" tier="$2"; shift 2
  local out rc
  if [[ "$tier" == root ]]; then out="$(sudo -n "$@" 2>&1)"; rc=$?
  else out="$("$@" 2>&1)"; rc=$?; fi
  local verdict
  if [[ $rc -eq 0 ]]; then verdict="ALLOWED (!!)"; ((N_ALLOWED++))
  elif echo "$out" | grep -qiE "operation not permitted|permission denied|EPERM|EACCES"; then
    verdict="BLOCKED"; ((N_BLOCKED++))
  else verdict="N/A"; ((N_NA++)); fi
  printf "  [%-4s] %-40s -> %-14s %s\n" "$tier" "$desc" "$verdict" "$(echo "$out" | head -1)"
}

echo "=============================================================="
echo "Guardian Shield v9 - HARDENING attacker simulation (--attack)"
echo "pin_dir=$PIN_DIR shield_dir=$SHIELD_DIR user=$(id -un) uid=$EUID"
echo "(victims must have been seeded via --setup with the shield unloaded)"
echo "=============================================================="

for tier in user root; do
  echo
  echo "### Tier: $tier ###"

  echo "-- credential / shield-file tamper: DELETE/OVERWRITE existing (expect BLOCKED) --"
  attack "unlink-glibc   .ssh victim"      "$tier" "$WORK/fs_probe" unlink-glibc   "$V_SSH"
  attack "unlink-syscall .claude victim"   "$tier" "$WORK/fs_probe" unlink-syscall "$V_CLAUDE"
  attack "overwrite      shield-dir victim" "$tier" "$WORK/fs_probe" overwrite      "$V_SHIELD"
  attack "unlink-syscall sudoers.d victim" "$tier" "$WORK/fs_probe" unlink-syscall "$V_SUDOERS"
  attack "unlink-syscall /boot victim"     "$tier" "$WORK/fs_probe" unlink-syscall "$V_BOOT"

  echo "-- NEW-FILE injection: create fresh file in a protected dir (expect BLOCKED) --"
  attack "create-new     .ssh (authorized_keys drop)" "$tier" "$WORK/fs_probe" create "$C_SSH"
  attack "create-new     .claude config drop"         "$tier" "$WORK/fs_probe" create "$C_CLAUDE"
  attack "create-new     sudoers.d (root persistence)" "$tier" "$WORK/fs_probe" create "$C_SUDOERS"
  # If any create slipped through (a gap), remove the injected file (best effort).
  for cf in "$C_SSH" "$C_CLAUDE" "$C_SUDOERS"; do
    [[ "$tier" == root ]] && sudo rm -f "$cf" 2>/dev/null || rm -f "$cf" 2>/dev/null || true
  done

  echo "-- shield-tamper (the interesting part) --"
  attack "unlink-syscall a BPF pin file"   "$tier" "$WORK/fs_probe" unlink-syscall "$PIN_DIR/gs_path_unlink"
  attack "bpf() BPF_OBJ_GET+LINK_DETACH"   "$tier" "$WORK/bpf_probe" "$PIN_DIR/gs_path_unlink"

  if [[ "$tier" == root ]]; then
    echo "-- root-only escalation probes --"
    attack_shell "kernel module load (modprobe dummy)"  root modprobe dummy
    sudo rmmod dummy 2>/dev/null || true
    attack_shell "mount tmpfs at /mnt/gs_probe"         root sh -c 'mkdir -p /mnt/gs_probe && mount -t tmpfs none /mnt/gs_probe'
    sudo umount /mnt/gs_probe 2>/dev/null || true
  fi
done

# Persistence: kill the loader, then re-attempt a pin removal. The loader's comm
# is truncated to 15 chars ("guardian_shield"), so match that exact comm.
echo
echo "### Persistence: kill loader, then attempt pin removal (must persist via pins) ###"
LOADER_PID="$(pgrep -x guardian_shield | head -1 || true)"
if [[ -n "${LOADER_PID:-}" ]]; then
  echo "  killing loader pid $LOADER_PID ..."
  sudo kill -9 "$LOADER_PID" 2>/dev/null || true
  sleep 1
  if [[ -e "$PIN_DIR/gs_path_unlink" ]]; then
    echo "  pins still present after loader death (links persist) - good."
  else
    echo "  WARNING: pins vanished after loader death!"
  fi
  attack "unlink pin after loader death"   root "$WORK/fs_probe" unlink-syscall "$PIN_DIR/gs_path_unlink"
else
  echo "  (loader process 'guardian_shield' not found - skipping; pins should still hold links)"
fi

echo
echo "=============================================================="
echo "SUMMARY (--attack): blocked=$N_BLOCKED  allowed=$N_ALLOWED  n/a=$N_NA"
[[ $N_ALLOWED -gt 0 ]] && echo ">>> $N_ALLOWED ALLOWED(!!) result(s) - real gap(s), see lines above."
[[ $N_NA -gt 0 ]] && echo ">>> $N_NA N/A result(s) - target likely not seeded (run --setup first)."
echo "=============================================================="
cat <<'BOUND'

ROOT BOUNDARY (honest - do NOT claim root is fully contained):
A userspace-loaded BPF-LSM raises the bar but cannot stop a determined root who
can change the kernel's boot path or has hypervisor/physical access. Even with
every probe above BLOCKED at runtime, root can still:
  * Reboot with a modified kernel cmdline (drop `lsm=...,bpf`) -> the shield
    never loads next boot. (If /boot is a critical path, editing grub is blocked
    at runtime, but root can kexec or alter the disk offline.)
  * kexec into a new kernel, or boot single-user / rescue media.
  * Modify the shield's config/binary offline (VM disk edit) while it is not
    loaded.
  * Anything gated on caps we deliberately DON'T deny (only CAP_SYS_MODULE and
    CAP_BPF are denied narrowly; CAP_SYS_ADMIN is NOT blanket-denied).
What hardening DOES buy against a LIVE (already-booted) attacker, incl. root:
  * No bpf()/bpftool tamper of the shield's links/maps (gs_bpf).
  * No fs deletion/overwrite of the pins or the critical set (fs hooks).
  * No runtime kernel-module load or mount tricks (module/mount hooks).
  * No ptrace injection into trusted processes.
Any line above marked "ALLOWED (!!)" is a real gap - report it verbatim.
BOUND

[[ $N_ALLOWED -eq 0 ]] && exit 0 || exit 1
