# Guardian Shield v9 — Installation Guide

Guardian Shield v9 is a **kernel-level containment layer for AI coding agents**,
built on BPF-LSM. Once loaded, the kernel itself — not a library, not a shell
wrapper — blocks tagged agent process trees from destroying or tampering with
the files you tell it to protect. It has been live-verified: glibc calls, raw
syscalls, `openat2`, `renameat2`, and even io_uring operations dispatched from
kernel worker threads are all denied at the LSM hooks, while every non-agent
process on the machine is completely unaffected.

It integrates with **Quantum Diary**: the app's binary (`quantum-diary`) is in
the default agent list, so the embedded GUI agent's `run_command` children get
the same kernel containment as a terminal `claude` session — the tag is applied
at exec, inherited on fork, and sticky across exec, so nothing an agent spawns
escapes it.

**What it is not:** a sandbox for humans. In its default posture it restricts
*only* processes descended from a recognized agent launcher. Your shell, your
editor, your builds are untouched. (An opt-in `hardening_mode` flips to
default-deny for a critical file set — see [Postures](#the-two-postures).)

---

## Prerequisites

The installer checks all of these and prints the exact remediation for
anything missing. Nothing is built or installed until every check passes.

| Requirement | Why | Typical package |
|---|---|---|
| Linux kernel ≥ 5.7, `CONFIG_BPF_LSM=y` | BPF-LSM hooks | any mainstream distro kernel |
| `bpf` in the **active** LSM stack (`cat /sys/kernel/security/lsm`) | hooks only attach if the bpf LSM is enabled at boot | kernel cmdline: `lsm=...,bpf` |
| `CONFIG_SECURITY_PATH=y` | the `path_*` hook family | standard on mainstream distros |
| `/sys/kernel/btf/vmlinux` (`CONFIG_DEBUG_INFO_BTF=y`) | CO-RE + `vmlinux.h` generation | standard since ~2021 |
| clang with BPF target | compiles the BPF object | `clang`, `llvm` |
| bpftool | generates `vmlinux.h`, operator inspection | `bpf` (Arch), `linux-tools-*` (Debian/Ubuntu) |
| Zig **0.16+** | builds the userspace loader | [ziglang.org/download](https://ziglang.org/download/) |
| libbpf ≥ 1.0 (headers + lib) | the loader links `-lbpf` | `libbpf` / `libbpf-dev` |
| jq **or** python3 | validates the generated config | `jq` |
| liburing (*optional*) | only for the bypass test harness | `liburing` / `liburing-dev` |

If `bpf` is missing from the LSM stack, add it to the kernel command line and
reboot:

```bash
cat /sys/kernel/security/lsm          # e.g. lockdown,capability,yama,apparmor
# /etc/default/grub:
#   GRUB_CMDLINE_LINUX="... lsm=lockdown,capability,yama,apparmor,bpf"
sudo grub-mkconfig -o /boot/grub/grub.cfg   # or: sudo update-grub
sudo reboot
```

---

## Install

```bash
cd guardian-shield-v9
./install.sh                          # default install dir: /opt/guardian-shield
# ./install.sh --prefix /some/dir     # alternate location
```

The installer:

1. verifies every prerequisite (fails loud, with remediation, otherwise);
2. regenerates `bpf/vmlinux.h` from **your** kernel's BTF — the BPF object
   embeds struct-layout offsets that are not relocatable, so it must be built
   on the machine (and kernel) it will run on;
3. builds the BPF object and loader (`zig build`);
4. renders `config.template.json` into a machine-specific `config.json`:
   `${HOME}`/`${USER}` resolve to the *invoking* user (not root), and
   `${INSTALL_DIR}` to the install location. The result is rejected unless it
   is strict JSON with zero unresolved placeholders and every path within the
   BPF 128-byte key limit;
5. installs everything **root-owned** to the install dir. (This matters: under
   `hardening_mode` the loader's own path is *trusted* — it must never live
   anywhere an unprivileged user can overwrite it. Don't install into `$HOME`
   unless you understand that tradeoff; the installer warns if you do.)

**The installer never loads anything into the kernel.** Loading pins LSM hooks
that gate filesystem operations machine-wide and *persist after the loader
exits* — that is deliberately an explicit operator action, not an installer
side effect. Review the policy first.

### Rebuild after a kernel upgrade

The BPF object is built against the running kernel's BTF. After a kernel
upgrade, re-run `./install.sh` (it always regenerates `vmlinux.h` and
rebuilds) before loading again.

---

## Review the policy, then load

```bash
sudoedit /opt/guardian-shield/config.json    # review before first load
```

Recommended first run: set `"log_only": true`. Everything is logged
(`/var/log/guardian_shield.jsonl`) but nothing is denied — you see exactly
what *would* be blocked on your machine before you enforce. Then flip it back.

Load, attach, and pin (root required):

```bash
sudo /opt/guardian-shield/guardian_shield_loader /opt/guardian-shield/config.json --verbose
# -> "Guardian Shield v9 ACTIVE: N hooks pinned under /sys/fs/bpf/guardian_shield"
```

Enforcement is now live **and survives the loader exiting** (the pins own the
LSM links). The running loader only streams the event log; you can Ctrl-C it
and protection stays up. Fail-closed: if any single hook fails to attach or
pin, everything is torn down — it never runs partially protected.

### Verify it is enforcing

```bash
ls /sys/fs/bpf/guardian_shield/            # one pin per hook
sudo bpftool link show                     # the attached LSM/tp_btf links
tail -f /var/log/guardian_shield.jsonl     # JSONL block/audit events
```

Full proof — the external-vector bypass suite (installed if liburing was
present at build time). As a **non-root** user, with the shield loaded and a
test directory added to `protected_paths`:

```bash
/opt/guardian-shield/tests/run_bypass_suite.sh "$HOME/gs_test_protected" "$HOME/gs_test_scratch"
```

It execs a real binary named `claude` (agent-tagged) and drives glibc
`unlink`, raw `SYS_unlinkat`, `openat2(O_TRUNC)`, io_uring `UNLINKAT`,
`renameat2`, and `openat2(O_CREAT)` — every destructive vector must return
EPERM/EACCES, and the non-agent control run must succeed. There is also a
config-render sanity test that needs no root at all:
`tests/test_config_template.sh`.

### Quantum Diary integration check

With the shield loaded, ask the Quantum Diary GUI agent to delete a file under
a protected path (e.g. `~/.ssh`). The `run_command` child runs as a descendant
of the `quantum-diary` binary, is agent-tagged by inheritance, and the kernel
denies it — check the JSONL log for the `BLOCKED` event with the agent tag.

---

## Unload / uninstall

```bash
# Remove enforcement (detaches + unpins every hook):
sudo /opt/guardian-shield/guardian_shield_loader /opt/guardian-shield/config.json --unpin

# Full uninstall (unpins first if live, then removes the install dir):
/opt/guardian-shield/uninstall.sh
```

Guaranteed fallback: **reboot always clears all BPF pins/links/maps.** If
teardown ever misbehaves, the shield fails *secure* (still enforcing), never
open — a reboot is the escape hatch, not a security hole.

---

## The two postures

### 1. Agent containment (default — `"hardening_mode": false`)

Only processes descended from an `agent_exes` launcher basename (`claude`,
`quantum-diary`, `cursor`, `aider`, …) are restricted, against
`protected_paths`. The default protected set: system dirs (`/etc`, `/boot`,
`/usr/bin`, `/usr/sbin`, `/usr/local/{bin,sbin}`, `/usr/lib`, `/lib`,
`/lib64`), root's and your `~/.ssh`, your `~/.claude`, and your `~/.config`.

Independent, always-on supply-chain defenses:

- **Credential-read block** — a build-tool subtree (`npm`, `pip`, `cargo`, …
  taint, inherited and sticky) or agent subtree is denied *any* open —
  including read-only — of the crown-jewel credential set (`~/.ssh`, `~/.aws`,
  `~/.config/gcloud`, `~/.kube`, …). A malicious postinstall cannot harvest
  your keys. Normal processes reading their own creds are untouched.
- **Egress guard** — tainted/agent connects to non-allowlisted public IPs are
  logged (and denied when `enforce_egress: true`). **Ships log-only
  (`false`) by default**: agents must reach their AI provider's public API to
  function, and a tainted `npm install` must reach the registry — observe the
  `tainted_connect` events, allowlist the CIDRs your traffic needs in
  `egress_allow`, then enable enforcement.

Tuning notes (deliberate defaults you may want to adjust):

- `~/.claude` in `protected_paths` means a contained agent **cannot rewrite
  its own settings/permission grants** — a real attack surface — but it also
  blocks the agent's routine session-state writes under `~/.claude/`. If that
  friction is unacceptable, remove the entry (or run `log_only` first and
  decide from the evidence). `~/.claude.json` (a file, not under the dir) is
  unaffected.
- `~/.claude` is deliberately **not** in `credential_paths`: agents must read
  their own state/credentials to run at all. Write/delete protection still
  applies via `protected_paths`.
- Agents whose launcher is literally `node`/`python` are not tagged by default
  (far too broad); add basenames to `agent_exes` for your tools.

### 2. Hardening mode (opt-in — `"hardening_mode": true`)

Default-deny for the `critical_paths` set (the shield's own pins and install
dir, `~/.ssh`, `~/.claude`, `/etc/sudoers.d`, `/boot`) against **everyone**
except `trusted_exes`, plus self-protection: the `bpf()` syscall, module
loading, mount tricks, `/dev/mem`, and ptrace-into-trusted are denied to
non-trusted processes — even root cannot detach the shield's hooks or delete
its pins at runtime (live-verified). `trusted_exes` **must** include the
installed loader path (the generated config does this for you; the loader also
trusts itself by exe inode, so `--unpin` works however it is invoked).

---

## Residual risks — read this honestly

From the engineering status doc (`V9_STATUS.md`), which is the authority:

- **Not a defense against a determined root at boot time.** A root attacker
  can reboot with `lsm=` edited to drop `bpf`, `kexec`, boot rescue media, or
  edit the disk offline. Hardening mode blocks *runtime* tamper (bpf(),
  pin deletion, module load, mount tricks — all verified blocked for root),
  not offline attack.
- **Agent classification is by launcher basename.** An agent invoked as a bare
  `node`/`python` process is not tagged unless you add those basenames. A
  symlink named `claude` is deliberately *not* tagged (dentry-leaf
  resolution = symlink-spoof resistance).
- **`exempt_exes` is an operator-declared trust hole** — an exempt binary
  inside an agent subtree escapes enforcement. Keyed on full path, not
  process name, so it is not `prctl`-forgeable.
- **Reads are allowed by design** outside the credential set; extended
  attributes and non-VFS destruction (raw writes to an already-open block
  device) are out of scope of the path hooks (mitigated separately by the
  `/dev/*` and mount hooks).
- **Path caps:** protected-path matching buffers cap at 128 bytes / 16
  directory levels for the dentry-walk hooks (truncation is counted, and the
  installer rejects over-long policy entries up front). The `file_open`/
  `truncate` hooks resolve the full canonical path with no cap.
- **Kernel-specific object.** The BPF object must be rebuilt per machine and
  per kernel upgrade (the installer handles this — never copy a prebuilt
  `.bpf.o` between machines).
- **If the logging loader dies, enforcement continues** via the pinned links;
  only event logging pauses until a loader reattaches.
- **IPv6 egress:** loopback/link-local/ULA allowed inline; global IPv6 is
  treated as public. No operator IPv6 allowlist in v1.

---

## File map (installed)

```
/opt/guardian-shield/
├── guardian_shield_loader      # userspace loader (root-owned, trusted path)
├── guardian_shield.bpf.o       # BPF object, built for THIS kernel
├── config.json                 # machine-resolved policy (from config.template.json)
├── uninstall.sh
└── tests/                      # bypass harness (if liburing was present)
    ├── gs_bypass_test
    └── run_bypass_suite.sh
```

Runtime state: pins under `/sys/fs/bpf/guardian_shield/` (one per hook),
events in `/var/log/guardian_shield.jsonl`.
