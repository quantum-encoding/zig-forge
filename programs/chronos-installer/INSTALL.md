# Chronos — Installation Guide

Chronos is automatic git provenance for AI-agent work. As you work in an opted-in
repo, a `PostToolUse` hook leaves one **`[CHRONOS]` tick commit per tool call**, so
your history records *what was done, in what order, by which agent*. When you're
ready to publish, `git push "message"` **folds** all the ticks into one clean
commit and pushes a tick-free history. Nothing ships automatically — the fold and
the push are an explicit step.

This directory (`programs/chronos-installer/`) is the machine-agnostic, downloadable
installer — the same treatment Guardian Shield v9 received.

---

## The two tiers

| Tier | Platforms | What you get | Installer |
|---|---|---|---|
| **1. Git-provenance** (default) | Linux **and** macOS | `[CHRONOS]` tick commits per tool call, folded on `git push`. Tick cognitive state uses a clean tool-activity gerund (Editing/Writing/…). | `./install.sh` |
| **2. D-Bus daemon** (add-on) | **Linux only** | Adds `chronosd` — a systemd **--user** turn-complete / cognitive emitter. Ticks then carry the *live* cognitive gerund, and turn-complete signals hit the session bus. | `./install-daemon.sh` |

**macOS is tier 1 only** (the tame posture — there is no `chronosd`). **Linux
original** is tier 1 + tier 2. Tier 2 is strictly optional; tier 1 is the whole
value proposition on its own.

---

## What quantum-diary detects

The quantum-diary app lights up its **Chronos** component the moment **`chronos-push`
is on your `$PATH`** (it also reports the D-Bus daemon separately if `chronosd` is
found). So the installer's core job is simply to put `chronos-push` (and the rest of
the tier-1 tools) on your PATH — machine-agnostically, no `/usr/local/bin`
assumption, no sudo where it isn't needed.

---

## Prerequisites

**Tier 1 (`install.sh`):**
- **Zig 0.16+** — builds the hook binary and the daemon-free stamp. Get it from
  <https://ziglang.org/download/>.
- **git**, **bash**.
- **python3** — used to edit `~/.claude/settings.json` **structurally and safely**
  (back up → parse → mutate one node → atomic write). Skip it with `--no-wire-hook`
  and wire the hook by hand.

**Build target (tier 1).** On Linux the installer builds **static musl**
binaries by default: they are portable (no glibc-version dependency — one build
runs on any distro) and it sidesteps a link failure seen with very new
toolchains — gcc 16's `crt1.o` carries `.sframe` unwind sections whose
`R_X86_64_PC64` relocations Zig's linker rejects when linking the *system*
glibc CRT. macOS builds native. Override with `CHRONOS_ZIG_TARGET` (e.g.
`CHRONOS_ZIG_TARGET=native` to force the system glibc toolchain, or a specific
`<arch>-linux-musl`). Tier 1 needs no system C libraries, so musl is a clean fit.

**Tier 2 (`install-daemon.sh`, Linux only), additionally:**

> **Note — the daemon has stricter build requirements than tier 1.** It links
> `libdbus-1` (a system library), so it **cannot** use the static-musl path —
> it builds against **glibc**. Two things to know:
>
> 1. **Zig version.** The engine source targets an **older `0.16.0-dev`** std
>    API (`std.Io`, `std.process.Init`, the `std.process.run(allocator, io, …)`
>    signature) — verified to resolve at **≈`0.16.0-dev.2510`**. Stable
>    `0.16.0` *removed/changed* those, and older dev builds (≤`dev.1859`) don't
>    have `std.process.Init` yet. Build the daemon with a Zig from that dev
>    window (set `CHRONOS_DAEMON_ZIG=/path/to/zig`), not stable.
> 2. **glibc.** On a very new box the glibc↔Zig `translate-c` path can fail two
>    ways: the gcc-16 `.sframe` CRT relocation (see tier-1 note), and a fortify
>    header using `__builtin_va_arg_pack` (`bits/stdio2.h`) that Zig's C parser
>    doesn't implement. Both are toolchain-version issues, not source bugs;
>    a mainstream glibc/gcc builds cleanly.
>
> The daemon is an **optional add-on** — the git-provenance tier that
> quantum-diary detects (tier 1) needs none of this.

- **libdbus-1 dev** + **pkg-config** (Arch: `pacman -S dbus`; Debian/Ubuntu: `apt install libdbus-1-dev pkg-config`)
- **libbpf dev** (Arch: `pacman -S libbpf`; Debian/Ubuntu: `apt install libbpf-dev`)
- **sqlite3 dev** (Arch: `pacman -S sqlite`; Debian/Ubuntu: `apt install libsqlite3-dev`)
- **systemd --user** session available (headless boxes: `loginctl enable-linger $USER`)

Each installer runs a prerequisite gate that collects **every** missing item and
fails once with the exact remediation — it never half-installs.

---

## Install (tier 1)

```bash
cd programs/chronos-installer
./install.sh                    # build + install to ~/.local/bin, wire the Claude hook
```

Options:

```bash
./install.sh --prefix DIR       # install somewhere else (no sudo if DIR is writable)
./install.sh --system           # install to /usr/local/bin (uses sudo)
./install.sh --no-wire-hook     # install binaries only; do not touch settings.json
./install.sh --settings PATH    # target a non-default settings.json
./install.sh --skip-build       # reuse existing zig-out artifacts
```

Default prefix is **`~/.local/bin`** (no sudo). If it isn't on your `$PATH`, the
installer warns you and prints the `export PATH=...` line to add — this matters
because quantum-diary's detection looks for `chronos-push` by name.

### What it installs

`chronos-hook`, `chronos-stamp`, `chronos-push`, `chronos-enable-repo`,
`chronos-disable-repo`, `chronos-post-commit`, `chronos-hook-install-all`.

> `chronos-stamp` is built from the engine's daemon-free stamp source
> (`chronos-stamp-macos.zig`) on **both** platforms — it is pure libc (a local
> tick file), and it's what makes the hook emit a fold-able `[CHRONOS]` line
> without needing the D-Bus daemon.

### How the settings.json wiring works (and why it's safe)

The hook only fires if Claude Code runs `chronos-hook` as a `PostToolUse` hook.
The installer adds that hook to `~/.claude/settings.json` via
`chronos-settings-hook.py`, which is deliberately careful:

- **Backs the file up first** (`settings.json.chronos.bak`) before any write.
- **Parses the JSON structurally** with the stdlib and **fails closed** on
  malformed JSON — it never overwrites a file it couldn't parse.
- **Idempotent**: a `chronos-hook` PostToolUse entry that already exists is
  refreshed in place, never duplicated on re-run.
- **Never clobbers other hooks** — every other matcher, hook, permission and
  setting is preserved by a parse → mutate-one-node → serialise round-trip.
- **Atomic write** (temp file + `os.replace`), so a crash can't leave a
  half-written settings.json.

The command it installs is **absolute** and carries `CHRONOS_*_BIN` env vars:

```
CHRONOS_STAMP_BIN='<prefix>/chronos-stamp' CHRONOS_STATE_BIN='<prefix>/get-cognitive-state' \
CHRONOS_ENABLE_REPO_BIN='<prefix>/chronos-enable-repo' CHRONOS_POST_COMMIT_BIN='<prefix>/chronos-post-commit' \
'<prefix>/chronos-hook'
```

so the hook resolves its helpers **regardless of the hook process's PATH** — the
key to a per-user install that doesn't rely on `/usr/local/bin`. `CHRONOS_STATE_BIN`
points at where tier 2 *would* install `get-cognitive-state`; if tier 2 isn't
installed, the hook degrades cleanly to the tool-activity gerund.

You can test the wiring in isolation, against a throwaway file, without touching
your real config:

```bash
bash tests/test-settings-hook.sh
```

---

## Enable a repo (opt-in, per repo)

Installing does **not** start ticking anywhere. Each repo opts in explicitly:

```bash
chronos-enable-repo /path/to/repo     # git config chronos.enabled true + post-commit shim
# ...work; each tool action leaves a [CHRONOS] tick...
git push "feat: my change"            # fold the ticks, push a clean history
chronos-disable-repo /path/to/repo    # opt back out (history is left as-is)
```

`git push "message"` is routed through `chronos-push` in a chronos-enabled repo;
you can also call `chronos-push -m "message"` directly. See
`../cognitive_telemetry_kit/chronos-hook/AGENT-GUIDE.md` for the full working model
(and the one `.gitignore`/build-artifact trap to avoid).

---

## Install the D-Bus daemon (tier 2, Linux)

```bash
./install-daemon.sh               # build + install chronosd to ~/.local/bin, render a --user unit
```

It installs `chronosd` and the cognitive-state helpers, then renders a **systemd
--user** unit at `~/.config/systemd/user/chronosd.service` with the ExecStart set
to the resolved install path (never a hardcoded `/usr/local/bin`). It **does not
start the daemon** — starting a daemon is your decision. It prints:

```bash
systemctl --user daemon-reload
systemctl --user enable --now chronosd.service
loginctl enable-linger "$USER"        # headless/SSH boxes only
```

### System-wide (root) alternative

A hardened **system** unit (`DynamicUser`, `ProtectSystem=strict`, …) ships at
`../chronos_engine/config/chronosd.service`. Install it to `/etc/systemd/system/`
and manage it with `sudo systemctl` if you want a machine-wide daemon instead of a
per-user one. The per-user unit is the recommended default (no root, serves your
session bus).

---

## Uninstall

```bash
./uninstall.sh                    # unwire settings.json, remove tier-1 (+ tier-2 if present)
./uninstall.sh --system           # for a /usr/local/bin install
./uninstall.sh --keep-settings    # leave settings.json alone
```

Uninstall removes the `chronos-hook` PostToolUse entry (backup first, other hooks
preserved), stops+removes the `--user` daemon unit if present, and **relocates**
the installed binaries into a timestamped backup dir under `$TMPDIR` (it never
hard-deletes — nothing is lost, and it works on boxes where `rm` is blocked). It
deliberately **leaves per-repo opt-in state**: run `chronos-disable-repo
/path/to/repo` for each repo you enabled (do this *before* uninstalling if you want
the post-commit shim's target to still exist).

---

## quantum-diary meta-installer integration

quantum-diary's `tools/package/quantum-fleet-installer.sh` delegates to Chronos via
a **`CHRONOS_DIR`** env var and calls `"$CHRONOS_DIR/install.sh"`. Point `CHRONOS_DIR`
at **this directory**:

```bash
CHRONOS_DIR=/path/to/zig-forge/programs/chronos-installer \
  /path/to/quantum-diary/tools/package/quantum-fleet-installer.sh
```

`$CHRONOS_DIR/install.sh` is exactly this bundle's `install.sh`, so the meta-installer
gets the full, prereq-gated, machine-agnostic tier-1 install with the settings.json
wired safely.

> This installer builds from two sibling source trees in the zig-forge checkout:
> `../cognitive_telemetry_kit/chronos-hook` (the hook) and `../chronos_engine` (the
> stamp/daemon). Override their locations with `CHRONOS_HOOK_SRC` /
> `CHRONOS_ENGINE_SRC` if your layout differs. Clone the full repo — this directory
> alone does not contain the sources.

---

## File map (this bundle)

| File | Purpose |
|---|---|
| `install.sh` | Tier-1 installer (universal). The `CHRONOS_DIR/install.sh` entry point. |
| `install-daemon.sh` | Tier-2 installer (Linux D-Bus daemon add-on). |
| `uninstall.sh` | Removes both tiers; unwires settings.json; relocates binaries. |
| `chronos-settings-hook.py` | Idempotent, safe settings.json hook wiring (add/remove/check). |
| `chronosd.user.service.template` | systemd `--user` unit template (`@EXECSTART@` rendered at install). |
| `tests/test-settings-hook.sh` | Unit tests for the settings.json wiring (throwaway sandbox). |
