#!/usr/bin/env python3
"""chronos-settings-hook.py — idempotent, safe wiring of the Chronos PostToolUse
hook into a Claude Code settings.json.

The Chronos tick engine only fires when Claude Code runs `chronos-hook` as a
PostToolUse hook. Editing settings.json by hand (or with a blunt jq one-liner) is
where installers usually break other people's config: they clobber unrelated
hooks, corrupt the file on a parse slip, or double-add on re-run. This helper does
the edit the careful way:

  * It ALWAYS backs the file up first (settings.json.chronos.bak) before writing.
  * It parses the existing JSON with the stdlib (no shell-quoting hazards) and
    fails closed on malformed JSON rather than overwriting it.
  * It is IDEMPOTENT: a PostToolUse hook whose command already references
    `chronos-hook` is detected and (on --add) refreshed in place, never duplicated.
  * It only ever touches the single hook entry it owns. Every other matcher, hook
    type, permission, env var and setting in the file is preserved by a structural
    round-trip (parse -> mutate one node -> serialise).
  * The write is atomic (temp file in the same dir + os.replace), so a crash
    mid-write can never leave a half-written settings.json.

It is deliberately a standalone script with no imports beyond the stdlib so it can
be unit-tested against a throwaway settings.json / temp $HOME without installing
anything or touching the operator's real config.

Usage:
  chronos-settings-hook.py --add    --command "<cmd>" [--settings PATH] [--matcher '*']
  chronos-settings-hook.py --remove                    [--settings PATH]
  chronos-settings-hook.py --check                     [--settings PATH]

Exit codes: 0 success (or already in desired state), 2 usage error, 3 malformed
existing settings.json (nothing written).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

# The stable marker every Chronos PostToolUse command contains. Detection keys off
# this substring so the entry is recognised regardless of the absolute install
# prefix baked into the command (a ~/.local/bin install and a /usr/local/bin
# install both match), and regardless of any env-var prefix on the command line.
CHRONOS_MARKER = "chronos-hook"

DEFAULT_SETTINGS = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")


def load_settings(path: str) -> dict:
    """Load settings.json, or return {} if it does not exist yet. Malformed JSON
    is a hard error (exit 3) — we never overwrite a file we could not parse."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"chronos-settings: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(3)
    if text.strip() == "":
        return {}
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        print(
            f"chronos-settings: {path} is not valid JSON ({exc}); refusing to "
            "touch it. Fix or remove it, then re-run.",
            file=sys.stderr,
        )
        sys.exit(3)
    if not isinstance(data, dict):
        print(
            f"chronos-settings: {path} top level is not a JSON object; refusing "
            "to touch it.",
            file=sys.stderr,
        )
        sys.exit(3)
    return data


def atomic_write(path: str, data: dict) -> None:
    """Serialise `data` to `path` atomically (temp file + os.replace), after
    backing up any existing file to <path>.chronos.bak."""
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)

    if os.path.exists(path):
        backup = path + ".chronos.bak"
        with open(path, "r", encoding="utf-8") as src:
            original = src.read()
        with open(backup, "w", encoding="utf-8") as dst:
            dst.write(original)
        print(f"chronos-settings: backed up {path} -> {backup}")

    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".settings.chronos.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        # Leave no orphan temp file behind on any failure.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def find_chronos_entries(post_tool_use: list) -> list[tuple[int, int]]:
    """Return (matcher_index, hook_index) pairs whose command references Chronos."""
    hits: list[tuple[int, int]] = []
    for mi, matcher in enumerate(post_tool_use):
        if not isinstance(matcher, dict):
            continue
        for hi, hook in enumerate(matcher.get("hooks", []) or []):
            if isinstance(hook, dict) and CHRONOS_MARKER in str(hook.get("command", "")):
                hits.append((mi, hi))
    return hits


def cmd_check(path: str) -> int:
    data = load_settings(path)
    ptu = (data.get("hooks", {}) or {}).get("PostToolUse", []) or []
    present = bool(find_chronos_entries(ptu))
    print(f"chronos-settings: PostToolUse chronos-hook {'PRESENT' if present else 'ABSENT'} in {path}")
    return 0 if present else 1


def cmd_add(path: str, command: str, matcher: str) -> int:
    data = load_settings(path)
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        print("chronos-settings: existing 'hooks' is not an object; refusing.", file=sys.stderr)
        return 3
    ptu = hooks.setdefault("PostToolUse", [])
    if not isinstance(ptu, list):
        print("chronos-settings: existing 'hooks.PostToolUse' is not an array; refusing.", file=sys.stderr)
        return 3

    existing = find_chronos_entries(ptu)
    if existing:
        # Idempotent refresh: update the command in place (the install prefix or
        # baked env may have changed) without adding a second entry or disturbing
        # any sibling hook in the same matcher.
        changed = False
        for mi, hi in existing:
            if ptu[mi]["hooks"][hi].get("command") != command:
                ptu[mi]["hooks"][hi]["command"] = command
                changed = True
        if changed:
            atomic_write(path, data)
            print(f"chronos-settings: refreshed existing Chronos PostToolUse hook in {path}")
        else:
            print(f"chronos-settings: Chronos PostToolUse hook already present and current in {path} (no change)")
        return 0

    # Prefer to append into an existing matcher of the same selector so we don't
    # add a redundant second matcher block; else create a fresh matcher.
    for m in ptu:
        if isinstance(m, dict) and m.get("matcher") == matcher:
            m.setdefault("hooks", []).append({"type": "command", "command": command})
            atomic_write(path, data)
            print(f"chronos-settings: added Chronos hook to existing '{matcher}' PostToolUse matcher in {path}")
            return 0

    ptu.append({"matcher": matcher, "hooks": [{"type": "command", "command": command}]})
    atomic_write(path, data)
    print(f"chronos-settings: added Chronos PostToolUse hook (matcher '{matcher}') to {path}")
    return 0


def cmd_remove(path: str) -> int:
    data = load_settings(path)
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        print(f"chronos-settings: no hooks in {path} (nothing to remove)")
        return 0
    ptu = hooks.get("PostToolUse")
    if not isinstance(ptu, list):
        print(f"chronos-settings: no PostToolUse hooks in {path} (nothing to remove)")
        return 0

    removed = 0
    for matcher in ptu:
        if not isinstance(matcher, dict):
            continue
        before = matcher.get("hooks", []) or []
        after = [h for h in before if not (isinstance(h, dict) and CHRONOS_MARKER in str(h.get("command", "")))]
        if len(after) != len(before):
            removed += len(before) - len(after)
            matcher["hooks"] = after

    if removed == 0:
        print(f"chronos-settings: no Chronos PostToolUse hook found in {path} (nothing to remove)")
        return 0

    # Drop now-empty matcher blocks WE emptied, but only if they carry no other
    # keys of interest — a matcher we reduced to zero hooks is ours to prune.
    hooks["PostToolUse"] = [m for m in ptu if not (isinstance(m, dict) and (m.get("hooks", []) == []) and set(m.keys()) <= {"matcher", "hooks"})]
    if not hooks["PostToolUse"]:
        del hooks["PostToolUse"]
    if not hooks:
        del data["hooks"]

    atomic_write(path, data)
    print(f"chronos-settings: removed {removed} Chronos PostToolUse hook entr{'y' if removed == 1 else 'ies'} from {path}")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Idempotent Chronos PostToolUse hook wiring for Claude Code settings.json")
    grp = ap.add_mutually_exclusive_group(required=True)
    grp.add_argument("--add", action="store_true", help="add/refresh the Chronos PostToolUse hook")
    grp.add_argument("--remove", action="store_true", help="remove the Chronos PostToolUse hook")
    grp.add_argument("--check", action="store_true", help="report whether the hook is present (exit 0 present, 1 absent)")
    ap.add_argument("--settings", default=DEFAULT_SETTINGS, help=f"settings.json path (default: {DEFAULT_SETTINGS})")
    ap.add_argument("--command", help="the hook command string to install (required with --add)")
    ap.add_argument("--matcher", default="*", help="PostToolUse matcher selector (default: '*')")
    args = ap.parse_args(argv)

    if args.add:
        if not args.command:
            ap.error("--add requires --command")
        return cmd_add(args.settings, args.command, args.matcher)
    if args.remove:
        return cmd_remove(args.settings)
    return cmd_check(args.settings)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
