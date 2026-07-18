# Guardian Shield — Audit & Upgrade Plan

_Audit date: 2026-07-18. Scope: the Linux `guardian_shield` component (LD_PRELOAD
`libwarden` enforcement core, the `zig_sentinel` eBPF detection engine, the
`guardian-shield-v9` BPF-LSM prototype) and its relationship to the macOS
product (Metatron Security)._

This document is the actionable source of truth. It records what the audit found,
what has already been fixed, and the phased plan. Companion documents:
`THREAT_MODELS.md` (the consolidated threat models, defensive postures, live-kernel
proof, macOS/supply-chain comparison, and roadmap — read this for the "what defends
against what and where it stops" picture), `CONVERGENCE.md` (cross-platform
policy/event schema and porting plan), and `guardian-shield-v9/V9_STATUS.md` (the
BPF-LSM rewrite status, now including hardening mode).

---

## 1. Verdict

Guardian Shield is **well-written code on an enforcement model that cannot meet
its stated threat**. The code is clean of the six anti-pattern classes tracked in
`zig-forge/CLAUDE.md` (one JSON-in-format-string in `zig_http_sentinel` was the
lone exception — now fixed). But the primary enforcement layer, `libwarden`, is a
userspace `LD_PRELOAD` shim, and that architecture cannot constrain a hostile —
or even just a *modern* — local process.

Three layers, three very different states:

| Layer | Role | State |
|---|---|---|
| `libwarden` (LD_PRELOAD) | filesystem/exec syscall interposition | Guardrail, not a boundary. Keep as an accident-prevention UX layer; do not rely on it against adversaries. |
| `guardian-shield-v9` (BPF-LSM) | kernel-level enforcement | Correct architecture, ~60% built, shelved with a fatal path bug + the forgeable-identity flaw. **This is the real upgrade path.** |
| `zig_sentinel` (eBPF detection) | behavioral threat detection | Ambitious but largely hollow; core detectors were statistically meaningless or dead. Substantially repaired (Phase 2). |

### 1.1 Why `libwarden` cannot be a security boundary

These are properties of userspace syscall interposition, not bugs to patch:

- **Uninterposed equivalents**: `io_uring`, `openat2`, `renameat2`, `creat`, raw
  `syscall()`, and statically-linked / non-glibc binaries all reach the kernel
  without passing through the interposed libc wrappers. Modern Go/Rust/Node
  tooling uses these routinely, so protection silently does not apply even to
  honest programs.
- **`*at` interceptors ignore `dirfd`**: a dirfd-relative path is matched against
  a bare relative string and dodges every protected-prefix rule — a correctness
  hole that hits ordinary tools, not just attackers.
- **Self-service off switches** available to the untrusted process itself:
  `WARDEN_DISABLE=1` (and `GUARDIAN_SHIELD_DISABLE` / `LIBWARDEN_DISABLE`), the
  world-writable `/tmp/.warden_emergency_disable` magic file, and `SIGUSR2`.
- **Forgeable identity**: "untrusted agent" is decided by `/proc/self/comm`, a
  15-char label any process rewrites with `prctl(PR_SET_NAME, ...)`.
- **No path canonicalization**: the `canonicalize_paths = true` config default is
  never read; `..`, symlinks, and `//` all evade prefix matches. TOCTOU exists
  between the string check and the real syscall.
- **Fails open**: on config-load failure the shield degrades to permissive
  defaults (agent restrictions off; `/tmp` and `~/.claude` whitelisted).

The honest role of `libwarden` is "stop an *honest* tool's fat-fingered
`rm -rf $HOME`." Its README and CLAUDE.md guidance should say exactly that.

### 1.2 Why v9 (BPF-LSM) is the right pivot

LSM hooks sit at the VFS layer, **after** path resolution, so `io_uring`,
`openat2`, raw `syscall()`, and static binaries all pass through them, and the
path the kernel hands the hook is already canonical (closing the `..`/symlink and
TOCTOU gaps in one move). The prototype was shelved with:

1. **A fatal path bug** — `get_dentry_path()` read only `dentry->d_name.name` (the
   leaf filename), then compared a *full-path* prefix rule against a bare leaf.
   Prefix matching could never match. (Fix: `bpf_d_path()` on hooks that expose a
   `struct path`/`struct file`, or a bounded dentry parent-walk.)
2. **The forgeable-`comm` identity carried into the kernel** — must be replaced by
   a BPF-maintained agent-process-tree map keyed on exec/fork tracking.
3. **Loader API misuse** — `bpf_object__attach_skeleton` on a non-skeleton object;
   no link pinning (protection dies with the loader → fail-open); a non-existent
   `lsm.s/init` hook.

Rebuilding v9 correctly is Phase 1 and is delegated to a focused work-stream; its
status lands in `guardian-shield-v9/V9_STATUS.md`.

---

## 2. Operational findings (independent of code)

- **Activation gap**: `/etc/ld.so.preload` is empty; the shield is active only via
  a shell-rc `LD_PRELOAD` export in `~/.zshrc`. **systemd, cron, and non-login
  processes are unprotected.** `deploy.sh` is designed to populate
  `/etc/ld.so.preload`, but the shield was hand-deployed via `cp`, so that step
  never ran. Decide the posture (system-wide vs shell-only) and make the docs
  match reality.
- **No CI** existed — every gate (`zig build`, `zig build test`,
  `zig-lens --strict`) was manual. Added in Phase 0.
- **No committed provenance** for the deployed `libwarden.so` (`*.so` is
  gitignored). A checked-in SHA manifest now records the expected hash.
- **`claude` runs outside the shield** (`~/.zshrc` strips `LD_PRELOAD` for it) — a
  deliberate guard against a separate SIGTRAP issue in the Bun-bundled installer,
  but worth a conscious decision now that the TLS/pthread bug is fixed.
- **Doc sprawl**: `docs/` holds 74 files including loose `.txt` test captures and
  misfiled `.zig`. Prune to maintainable specs.

---

## 3. What has been done (Phase 0 + Phase 2)

All of the following are committed and pass `zig build && zig build test` (0
errors) on Zig 0.16.0.

**Phase 0 — honesty & hygiene**
- Fixed the one real injection: `zig_http_sentinel/filter_engine.zig` `logBlock`
  now serializes via `std.json.Stringify` instead of a printf-style JSON template
  with unescaped attacker-controlled `url`/`method`/`reason`.
- Retired the two stale `grimoire` tests (raised the `pattern struct size` bound
  to match the comptime assertion; rewrote the reverse-shell test to the current
  6-step pattern). Full suite is green.
- Added `.github/workflows/guardian_shield.yml`: build + test + ReleaseSafe +
  `zig-lens --strict` on every change touching the component.
- Added a SHA manifest for the deployed artifact (`DEPLOYED_ARTIFACT.sha256`).
- README threat-model honesty note (accident-prevention vs adversarial
  containment).

**Phase 2 — detection engine**
- **Grimoire `openat` path-index bug**: string/path constraints now resolve the
  pointer's argument index from the actual syscall (`open`→arg0, `openat`→arg1)
  via `pathArgIndex`, instead of a hardcoded literal. The `/etc/shadow`, `~/.ssh`,
  and rootkit(`.ko`) patterns can now actually fire (modern code opens almost
  exclusively via `openat`).
- **Grimoire whitelist TOCTOU**: a vanished PID (process exited between the eBPF
  event and the `/proc` lookup) no longer aborts detection for the whole event
  and no longer grants an implicit pass; unresolved binaries fall through to
  continued matching.
- **Anomaly detector rate fix**: the Z-score now consumes a per-poll **delta**
  (`deriveRate`) instead of the ever-growing cumulative counter, so it measures
  anomalies rather than monotonic drift. Rate derivation is a single self-
  contained pass (no double-advance).
- **Unicode Tag-block steganography detection**: `emoji_sanitizer` now flags
  U+E0000–E007F invisible-ASCII smuggling (with a false-positive guard for
  legitimate 🏴 regional-flag tag sequences) and carries a `tag_smuggling`
  verdict + tests using canonical tag-smuggling byte sequences.
- **Correlation engine honesty gate**: `--enable-correlation` now prints an
  explicit "not yet wired — needs sys_exit return-value capture" warning instead
  of silently recording zero correlations. See the follow-up below.

---

## 4. Remaining plan

### Phase 1 — Correct v9 BPF-LSM (delegated, in progress)
Deliverables tracked in `guardian-shield-v9/V9_STATUS.md`:
- Full absolute-path reconstruction (`bpf_d_path` / bounded dentry walk).
- Process-tree identity via `sched_process_exec`/`fork`/`exit` + a BPF `agent_pids`
  map, replacing `comm`. Mirrors Metatron's `KERN_PROCARGS2` + parent-walk model.
- `BPF_MAP_TYPE_LPM_TRIE` for verifier-friendly longest-prefix path matching.
- Loader: per-program `attach_lsm`, **link pinning** (survives loader restart,
  fail-closed), kernel-prereq checks (`CONFIG_BPF_LSM`, `lsm=...,bpf`).
- Root-gate or remove the self-service off switches.
- **External-vector bypass harness**: prove `openat2`/`io_uring`/raw-`syscall()`/
  `renameat2` deletes of a protected path all return EPERM under the LSM (the
  golden-rule anchor for the enforcement claim).

### Phase 2 follow-up — correlation return-value capture
Add a `raw_syscalls/sys_exit` (or per-syscall fexit) eBPF program that captures
return values, and route socket/connect/open fds into the correlation engine's
`onSocket`/`onConnect`/`onOpen`. Until then the engine stays gated (§3). Also
consider re-keying anomaly baselines on executable identity rather than the
ephemeral PID (noted by the audit; deferred as it needs per-key exe resolution).

### Phase 3 — Consolidation & convergence (delegated, complete)
See `CONVERGENCE.md`. Retire the three dead macOS ES/NE prototypes in the Linux
tree (`guardian-esd/`, `network-filter/`, `libmacwarden/`), preserving
`input_sovereignty` (the unique USB-HID work `libmacwarden/build.zig` currently
builds — decouple first). Define one shared policy schema + event schema for both
OSes. Port Linux's unique wins to macOS (fork-bomb limit, unicode-stego
sanitizer, USB-HID) and Metatron's network stack to Linux (DNS proxy/DoH, network
approval popup). Deletion of the prototypes requires sudo (the shield blocks
unprivileged deletes) — see the operator command list in the Phase 3 report.

---

## 5. If you do only one thing

Finish Phase 1: fix v9's path reconstruction and replace `comm` identity with the
BPF process-tree map. That single change converts Guardian Shield from a guardrail
into an actual boundary and is what the whole product hinges on.
