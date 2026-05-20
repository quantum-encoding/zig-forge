# Deferred behaviors (user-visible)

Things zigit does today that differ from git in a way a real user
will eventually trip over. Framed by the user-reported **symptom**
first, then the mechanism. Find the symptom here; find the fix in
the source comment it points to.

This is distinct from the CHANGELOG (what landed) and the v1.x
specs (what's planned). DEFERRED entries are *known gaps that are
silent enough to surprise a user*. If a behavior is loud (errors
cleanly, refuses to proceed), it doesn't need an entry here — the
error message is the record. If a behavior is quiet (succeeds with
the wrong result), it does.

---

## `add .` from a subdirectory stages the WHOLE repo, not the subtree

**Symptom.** "I ran `zigit add .` in `src/` and it staged my whole
repo, including files outside `src/`."

**Mechanism.** Every pathspec is interpreted as work-tree-root-
relative, not cwd-relative. `.` thus means "the whole work tree"
regardless of where you invoke from. git's `.` is cwd-relative —
`git add .` from `src/` stages `src/`'s subtree only.

**Why we're like this.** Before commit `7ccc75b`, `add` had a worse
bug: classification used `work_root.statFile` while staging used
`Dir.cwd().openFile`. The two phases disagreed about the path base
and `add .` from a subdir would FileNotFound mid-staging. The fix
in `7ccc75b` made both phases agree on `work_root` as the base. That
turned a *loud* bug (crash mid-staging) into a *quiet* one (silent
over-staging). Strictly correct trade — a command that does too
much beats a command that errors out — but the user-visible
result is unexpected.

**What's defending it.** `tests/parity.sh §9.add.6` asserts that
`add .` from a subdir stages both root-level and subdir files. Any
future fix toward cwd-relative semantics must update §9.add.6.

**Fix scope.** Implement true cwd-relative pathspec resolution:
compute `cwd` relative to `work_root` once at the top of `run`;
prepend it to relative args; resolve `.` to `cwd_rel`. Handle
`..` and absolute paths explicitly. The pre-existing v1.0 bug of
`add foo.txt` from a subdir (writes cwd-relative paths to the
index instead of work-root-relative) needs the same fix.

**Source pointer.** `src/cli/add.zig` file header, the
"Limitations" block.

---

## `core.excludesFile` is unread

**Symptom.** "I have `*.log` in my global gitignore via
`core.excludesFile` and `zigit status` still shows them as
untracked."

**Mechanism.** `Ruleset` already accepts global-excludes bytes via
`LoadOptions.global_excludes_bytes`; only the *path resolution*
glue is missing. `status` + `add` currently pass empty bytes for
the global file.

**Fix scope.** Resolve in this order:
  1. `cfg.get("core.excludesFile")` — if set, expand `~/` against
     `$HOME`, read the absolute path.
  2. `$XDG_CONFIG_HOME/git/ignore` — if set, read.
  3. `$HOME/.config/git/ignore` — read if it exists.

Pass the resulting bytes through `LoadOptions.global_excludes_bytes`
to `Ruleset.load`. Mechanical work — both `status.zig` and `add.zig`
have a TODO comment naming this.

**Source pointer.** `src/cli/status.zig` ruleset-loading block and
the same in `src/cli/add.zig`.

---

## `zigit switch` doesn't consult `.gitignore` for would-clobber

**Symptom.** "I'm switching branches and zigit refuses, saying it
would overwrite a file I don't care about because it's in
`.gitignore`."

**Mechanism.** `cli/switch.zig` passes `null` to `workdir.walk`, so
ignored files appear in the would-clobber check. git's switch makes
ignored files invisible to that check entirely.

**Fix scope.** One-line change: load a `Ruleset` and pass `&rs` to
`workdir.walk`. Matches what `status` does now.

**Source pointer.** `src/cli/switch.zig` — search for `null` in the
`workdir.walk` call; there's a TODO comment.

---

## `zigit add -f` / `--force` doesn't exist

**Symptom.** "I want `zigit add ignored_dir/` to add it anyway, but
zigit warns and exits without staging."

**Mechanism.** v1.1 picked the policy "explicit *file* arg bypasses
the filter, explicit *directory* arg honors it." That means an
ignored directory has no escape hatch. git's `-f`/`--force` is the
universal "do it anyway" override.

**Fix scope.** Parse `-f` / `--force` in `add.zig`. When set, skip
the ruleset entirely (both for dir expansion and explicit files,
matching git). Suppresses the "paths are ignored" warning.

**Source pointer.** `src/cli/add.zig` header — documented as a
known gap.
