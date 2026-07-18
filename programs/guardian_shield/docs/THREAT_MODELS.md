# Guardian Shield — Threat Models & Defensive Posture

_Consolidated 2026-07-18. Companion to `AUDIT_AND_UPGRADE_PLAN.md` (the Linux
audit) and `CONVERGENCE.md` (the macOS/Linux schema contract). This is the
reference for **which threat each posture actually defends against, what has been
proven on a live kernel, and — explicitly — where each stops.**_

The cardinal rule of this document: **never claim more than what was tested.**
Every "blocked" below was observed on a real BPF-LSM kernel (Arch 6.18) via an
external-vector harness, and every limit is stated honestly.

---

## 1. Three threats, not one

Guardian Shield is aimed at a spectrum, and the postures differ because the
adversaries differ:

| Threat | Who | Identity | The right posture |
|---|---|---|---|
| **A. AI agent goes rogue** | a known agent (claude/cursor/node) that is prompt-injected or autonomously misbehaves | cooperative — it runs as the agent binary; it isn't hiding | **agent-containment**: restrict the known agent subtree (deny-list) |
| **B. Attacker escalates** | a human/malware with code-exec trying to persist/exfil and to disable the shield | adversarial — won't run as a known agent, will try to unload the shield, may seek root | **hardening**: default-deny the critical set + self-protection (allow-list) |
| **C. Supply-chain / credential theft** | a malicious npm/PyPI package whose postinstall runs as the developer | a build tool's *child* — masquerades inside a legitimate `npm install` | a hybrid: **build-tool taint** + credential-**read** deny + egress control |

Threat C (the 2025–26 npm worms) is the one that spans both models and is the
current frontier — §5–§7.

---

## 2. The shared foundation: kernel-level enforcement

Both postures run on the same mechanism, and that mechanism is the hard,
already-done part.

**BPF-LSM, not userspace interposition.** The old `libwarden` LD_PRELOAD shim is
a guardrail, not a boundary — `io_uring`, `openat2`, `renameat2`, raw `syscall()`,
and statically-linked binaries all sail past it, and a process can disable it for
itself. The v9 rewrite moves enforcement into **LSM hooks at the VFS layer, after
path resolution**, so those bypasses do not exist: the hook sees the canonical
path regardless of how the syscall was issued. Proven — the bypass harness blocks
`glibc unlink`, raw `syscall(unlinkat)`, `io_uring UNLINKAT` (caught even from the
`iou-wrk` kernel worker thread via process-tree tag inheritance), `openat2`, and
`renameat2`.

**Process-tree identity, not `comm`.** Identity is a kernel-maintained
`agent_pids`/tag map keyed on tgid, seeded at `sched_process_exec` (by exe **inode
identity**, not the forgeable 15-char `comm`), inherited on `fork`, sticky across
`exec` (so spawning `rm` can't escape a tag), cleared on `exit`. This is the
primitive both postures — and the future build-tool taint (§8) — key off.

**The honest root ceiling (applies to everything below).** A userspace-loaded
BPF-LSM raises the bar but **cannot stop a determined root** who can touch the
boot path or the disk offline: reboot without `lsm=…,bpf`, `kexec`, single-user,
or an offline disk edit. This is a property of the mechanism, not a bug. It fails
**secure** (the shield gets stuck *on*, never off). Truly resisting root needs a
higher root of trust — kernel lockdown + signed/locked BPF, Secure Boot, IMA/EVM.

---

## 3. Posture A — Agent-containment (default, `hardening_mode=false`)

**What it does.** Restricts only process subtrees tagged `TAG_AGENT` (launcher
basenames in `agent_exes`: claude/cursor/aider/…) from write/delete/rename/move/
create/truncate/chmod on `protected_paths`. Everyone else is unaffected — a normal
process, and the user, work exactly as before. This is the "protect my files from
a rogue AI" product.

**Proven (kernel 6.18).** External-vector suite `tests/run_bypass_suite.sh`:
against an agent-tagged process, all delete/move/overwrite vectors → EPERM/EACCES;
against a non-agent control, all → allowed. `SUITE EXIT=0`.

**Boundary.** Reads are allowed by design (the threat is destruction/modification,
not theft). It protects *files from agents*; it does **not** defend against Threat
B or C — a non-agent attacker is not tagged, so it is unrestricted. That is
intentional, and it is exactly why Posture B exists.

---

## 4. Posture B — Hardening (opt-in, `hardening_mode=true`)

**Gate inversion → default-deny.** `restricted = hardening ? (tag != TAG_TRUSTED)
: (tag == TAG_AGENT)`. In hardening mode the `critical_paths` set is protected
from **everyone except an explicit `trusted_exes` allowlist** (keyed on exe inode
identity, non-forgeable). The critical set = the shield's own state
(`/sys/fs/bpf/guardian_shield` pins + install dir) + credentials + boot:
`~/.ssh`, `~/.claude`, `/etc/sudoers.d`, `/boot`.

**Self-protection hooks** (active in hardening mode, independent of `enforce_priv`):
- `lsm/bpf` (`gs_bpf`) — denies `bpf()` for non-trusted callers → **an attacker,
  even root, cannot `bpf()`/bpftool-detach the shield.**
- `path_mknod` — denies **new-file creation** in the critical set (closes the
  injection vector: dropping a rogue `authorized_keys` / `~/.claude` config /
  `/etc/sudoers.d` persistence file).
- `kernel_read_file` (module load), `sb_mount`/`move_mount` (mount tricks),
  `ptrace` (**scoped to protecting `TAG_TRUSTED` targets only** — normal
  `strace`/`gdb` of ordinary processes still works), `/dev/mem`.
- `gs_capable` — denies **only** `CAP_SYS_MODULE` + `CAP_BPF` for non-trusted
  (deliberately **not** blanket `CAP_SYS_ADMIN`, which would brick the box).

**Proven (kernel 6.18), attacker simulation `tests/attacker_sim.sh`, two tiers:**

| Class | unprivileged | **root** |
|---|---|---|
| delete / overwrite / move existing critical files | BLOCKED | BLOCKED |
| **new-file injection** (`~/.ssh`, `~/.claude`, `sudoers.d`) | BLOCKED | BLOCKED |
| `bpf()` LINK_DETACH (peel off the shield) | BLOCKED | BLOCKED |
| unlink a BPF pin | BLOCKED | BLOCKED |
| kernel module load / `mount` | — | BLOCKED |

`SUMMARY: blocked=23, allowed=0`. Persistence: after killing the loader,
enforcement continued via the pinned links.

**Teardown contract (operability).** `--unpin` drives each link's refcount to zero
(re-open → unpin → destroy, closing the last fd itself) and self-trusts by exe
inode, so the operator can cleanly stop the shield regardless of invocation path;
if a separate logger is running, `pkill -x guardian_shield` too. Guaranteed
fallback: **reboot** clears all BPF state (and is the same escape hatch as the root
ceiling). Verified: load → `--unpin` → `touch ~/.ssh/x` succeeds.

**Boundary (restated, because it matters).** Tamper-resistant against a **live,
already-booted** attacker including root — but **not** a guarantee against root who
reboots without the LSM, `kexec`s, or edits the disk offline (the same qemu-nbd
disk-edit we used to grant ourselves sudo cuts both ways). Hardening mode is a
strong layer, not a root-proof cage.

---

## 5. The 2025–26 developer supply-chain threat (Threat C)

Three campaigns, one kill chain (sources: Wiz, Unit 42, Sysdig, CISA, Datadog
Security Labs, Semgrep, InfoQ — see `AUDIT_AND_UPGRADE_PLAN.md` refs):

- **Shai-Hulud** (Sept 2025 → "2.0" Nov 24 2025 → 2026 variants) — the **first
  self-replicating npm worm**; v2 hit **25,000+ repos across ~350 users**. A
  **postinstall** runs `bundle.js` → **TruffleHog** sweeps the filesystem +
  harvests env vars, IMDS cloud keys, GitHub/npm/AWS/GCP tokens → exfil to a
  hardcoded **`webhook.site`** + double-base64 dumps into **public GitHub repos** +
  pushes a GitHub Actions workflow to every accessible repo → **self-propagates**
  by republishing with any npm token it finds. Staging in `/tmp/processor.sh`.
- **s1ngularity / nx** (Aug 26 2025) — `telemetry.js` postinstall; **first to
  actively hunt installed AI/LLM CLI tools** on the dev's machine to extract more
  secrets. Exfil to public GitHub repos under the victim's own account.
- **chalk / debug** (Sept 2025) — phishing (`npmjs.help` fake 2FA reset) →
  maintainer account takeover → browser crypto-stealer in 18+ packages.

**The kill chain and the key insight.** phishing/token-theft → malicious version →
**postinstall executes as the developer** → **read-harvest credentials**
(`~/.npmrc`, `~/.aws/credentials`, `~/.ssh`, `~/.gitconfig`, env, cloud metadata) →
**exfil** → **self-propagate**. This is a **credential-READ + exfiltration** attack,
not a delete/overwrite one. That single fact drives the gap analysis in §8.

---

## 6. macOS (Metatron) coverage — what's already built

Metatron ships a purpose-built **Developer Supply-Chain Sentinel** that is
conceptually ahead of most EDR for exactly this threat:

- `AssetMap.swift` — maps ~every credential file a real stealer targets
  (ssh/aws/gcloud/kube/netrc/**npmrc/pypirc**/cargo/gem/docker/gh/git-credentials/
  vault/azure/**codex/gemini**/Keychains/browsers/`chat.db`/shell-history/gitconfig).
- `BuildTreeTracker.swift` — an **audit-token taint engine** that models the
  postinstall→child→credential-read→exfil chain; reads `npm_package_name`/
  `npm_lifecycle_event` from the exec env to name the culprit package.
- Hooks `AUTH_OPEN`/`NOTIFY_OPEN` on credential paths — watches **reads**, not just
  writes — and **distinguishes a build tool reading its own `.npmrc` from a tainted
  descendant reaching for `.aws`** (`isBuildToolSecret` + `isTrustedExpectedReader`
  + signature check). A ≥3-distinct-cred burst in 300s = "sweeper" signature.
- Egress: `evaluateFlow` blocks a **secret-tainted** process's outbound on a
  **read→connect-within-60s** correlation — **even to allowlisted hosts** like
  `github.com` (the Shai-Hulud vector). `DNSProxyProvider` NXDOMAINs known-bad
  feeds; `NetworkApprovalManager` interactive prompts.

**Why it currently detects rather than blocks — and why that's fine.** Metatron
ships default **detect/monitor**, with hard blocking gated behind Enforce mode +
Workspace Jail, **by deliberate operator choice**: it is being developed on the
same machine, and a kernel-level deny-engine in Enforce mode would risk bricking
that dev environment. The enforcement path exists and works (`evaluateOpen`/
`evaluateFlow` return `.deny`, `block:true` hard-blocks, AUTH_EXEC pre-blocks) — the
safety interlock is simply on during development. **So the mechanism AND the
detection are done; only the switch is deliberately off.**

**Convergence lesson (both directions).** Metatron's one weakness (detect-only) is
exactly what the Linux hardening mode delivers (default-deny). The macOS action is
therefore **not new building** — it is a **validated enforce-mode cutover**: flip
the crown-jewel credential set to `block:true`, proven in a **VM first** (the same
isolate-and-test discipline as `forge-build-farm`), then enable on the real
machine with confidence. That turns "I don't want to brick my dev env" from a
reason to stay in monitor mode into a safe, reversible switch.

---

## 7. Coverage matrix — Threat C across both platforms

| Kill-chain stage | macOS Metatron | Linux v9 |
|---|---|---|
| 1. Postinstall executes | detect/attribute (BuildTreeTracker taint root) | **absent** (tags AI agents, not build trees) |
| 2. Credential file **READ** | **implemented** (AssetMap + read hooks; build-tool self-read vs theft distinguished); block-on-read is a config flip | **gap — v9 allows reads by design** |
| 3. Behavior detection (curl/trufflehog, /tmp exec) | partial (CommandPolicy, ThreatClassifier) | absent (zig_sentinel could host it) |
| 4. Network exfiltration | strongest (read→connect-within-60s, even to allowlisted hosts) + DNS feeds | **gap** (Linux network side is a stub) |
| 5. Self-propagation (token→publish) | partial (npm-publish/git-push escalation) | absent |
| 6. Persistence / tamper | thin (Custodian observe-only) | **hardening mode blocks** write/create/delete on the critical set for all non-trusted |

---

## 8. Gap analysis & roadmap

**Linux v9 — two missing primitives for Threat C** (the macOS side has both):

1. **Credential-READ protection.** v9's `file_open` hook already sees every open;
   it filters to write-intent today. Add a **read-deny path** on a credential
   AssetMap (`~/.ssh`, `~/.aws`, `~/.npmrc`, `~/.gitconfig`, `~/.claude`) so the
   *harvest* step is denied. This is the single highest-value add for the
   supply-chain threat and folds into the hardening critical set.
2. **Build-tool taint tagging.** v9 tags AI agents; the supply-chain threat needs
   tagging **build-tool subtrees** (npm/pip/cargo + lifecycle scripts) as *tainted*,
   then denying *their descendants'* credential reads and correlated egress —
   Metatron's `BuildTreeTracker` is the reference; the BPF process-tree tagger
   (`agent_pids`, sticky-across-exec) is the right kernel primitive to build it on.

Secondary: egress correlation on Linux (the network side is a stub); a shared
supply-chain simulation harness (postinstall → cred-sweep → exfil) that runs on
both platforms so "did we block it" is a test, not a belief.

**macOS Metatron — no new building, one validated cutover:** flip the crown-jewel
credential assets to `block:true`, proven in a VM first (§6).

**Shared schema:** the policy/event contract in `CONVERGENCE.md` already lets one
config + one dashboard drive both OSes; the credential AssetMap and taint model
should be expressed there so both platforms consume the same definitions.

---

## 9. What Guardian Shield is NOT (defense in depth)

This is one layer. It does not replace, and must be paired with:

- **Not letting the attacker get code-exec or root in the first place** (the only
  real fix for Threat B's root ceiling).
- **Kernel lockdown + Secure Boot + signed/locked BPF** — the higher root of trust
  needed to close the reboot/offline-disk boundary.
- **IMA/EVM** for file-integrity, **SELinux/AppArmor** MAC, **seccomp** sandboxing,
  **auditd** — complementary controls Guardian Shield sits alongside, not above.

Guardian Shield's contribution is a **kernel-level, bypass-proof, dual-posture
enforcement layer with honest boundaries** — strong where it is strong, and
explicit about where it is not.

---

## Appendix A — macOS (Metatron) enforce-mode cutover (operator procedure)

The macOS roadmap item (§8) is to **walk** the existing cutover ladder, not to
build enforcement — Metatron already ships both. Verified in-app surfaces:

**Custodian (destructive-op guard) 4-mode ladder** — `CustodianSettingsView.swift`,
config `destruction-guard.json`, decoupled from shield-mode, with a live latency
gate (p99 < 100µs) and would-deny soak evidence so "enforce is armed on data, not
faith":
- `off` — client not created.
- `observe (soak)` — full pipeline, nothing blocked, logs would-deny counts;
  "run ≥1 week before enforcing."
- `enforceScratch` — real denies **only under scratch roots** (isolated test tier,
  physically can't touch real data).
- `enforce` — full protection (agent `rm -rf` of vault paths → EPERM).

**Supply-chain Sentinel (credential-read + exfil)** enforces when shield-mode is
`Enforce` **and** the crown-jewel assets carry `block:true` (today only the
self-test anchor does; `evaluateOpen`/`evaluateFlow` already return `.deny`).

**Cutover procedure** (mirrors the Linux hardening validation — isolate, prove,
then flip; I cannot execute it here as there is no macOS host, so it is documented
for the operator):
1. **VM / second machine first**, never the primary dev box — the same discipline
   as `forge-build-farm`. Install Metatron; run a macOS supply-chain simulation
   (fake postinstall that sweeps `~/.aws`/`~/.ssh` then curls a webhook) — the
   macOS analogue of `supplychain_sim.sh`.
2. **Soak in `observe`** — collect would-deny counts on the crown-jewel AssetMap
   over ≥1 week of normal dev; tune the expected-reader allowlist so legit
   `npm→.npmrc` / `git→.config/gh` self-reads don't flag.
3. **`enforceScratch`** — validate real denies under scratch roots (a scratch-rooted
   `~/.aws` harvest → EPERM) with zero impact on real data.
4. **Flip `block:true`** on the crown-jewel credential assets (ssh/aws/gcloud/gh/
   git-credentials/kube/docker) and move shield-mode to `Enforce`; re-run the
   simulation and confirm: tainted-descendant crown-jewel read → denied, exfil
   (read→connect) → denied, legit build-tool self-read → allowed.
5. **Only then enable on the real machine.**

This reaches the same place the Linux side proves by default-deny in the VM —
Metatron gets there by walking its own measured ladder rather than a cold flip.

---

## 10. Testing methodology (how every claim here was earned)

Risky enforcement is validated in the **`forge-build-farm` VM** (Arch clone,
snapshot rollback — see the `vm-kernel-testing` skill), never on a working
machine. The external-vector harnesses (`run_bypass_suite.sh`, `attacker_sim.sh`)
are committed **regression tests**: they attack from multiple angles (`glibc`,
raw `syscall`, `io_uring`, `openat2`, `renameat2`, `bpf()`, module/mount) and
assert the outcome in both agent/non-agent and trusted/attacker tiers, including a
positive control. Six live-kernel iterations of the hardening work found and fixed
what no static review would have (verifier-complexity, CO-RE/bpf_loop/stack
constraints, the `--unpin` inode-trust bug, the file-creation gap, the link-refcount
teardown quirk). **If it isn't proven in the VM, it isn't claimed here.**
