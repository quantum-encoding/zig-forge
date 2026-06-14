# Chronos stamp/push — guide for AI coding agents

Read this if you are working in a **chronos-enabled** git repo (one where
`git config --get chronos.enabled` returns `true`). It explains what the system
does to your commits and the **one trap** that loses work or pushes bloat.

---

## What chronos does to your repo

1. **Every tool action leaves a tick.** A `PostToolUse` hook (`chronos-hook`)
   runs after each Edit/Write/Bash/Read/etc. It does:

   ```sh
   git add .                       # stages EVERYTHING not gitignored
   git commit --no-verify -m "[CHRONOS] …::<state>::TICK-… - <Tool> <path>"
   ```

   So your branch fills up with `[CHRONOS]` tick commits as you work. This is
   normal. Do not try to stop it or clean it up by hand.

2. **`git push` is the "ship it" command, not a raw push.** In a chronos repo a
   shell wrapper routes `git push` through `chronos-push`:

   | You type | What happens |
   |---|---|
   | `git push "feat: add X"` | fold all ticks → one summary commit titled `feat: add X` → push |
   | `git push` | fold ticks → auto-titled summary commit → push |
   | `git push origin main` | fold ticks → push |
   | `git push -u …`, `git push --force`, … (any flag) | passes straight to **real** git, no fold |

   The fold replays your **real** commits (reusing their exact trees) onto a
   tick-free chain and collapses trailing ticks into one summary commit. It
   **asserts** the rewritten tip's tree is byte-identical to `HEAD`'s tree before
   it touches the ref, then `git reset --soft` + `git push`. Content is preserved
   by construction; only the `[CHRONOS]` noise is dropped.

**Do not do the squash by hand.** No manual `git reset`, no `git rebase -i` to
kill ticks. Just `git push "your message"`. A stray `git reset --hard` can drop
uncommitted work the ticks have not captured yet.

---

## The trap: build artifacts and `.gitignore`

Because the tick hook runs `git add .`, **anything in the working tree that
isn't gitignored gets committed into a tick** — including build output:
`zig-out/`, `.zig-cache/`, `target/`, `node_modules/`, `*.a`, `*.o`, `*.so`,
`*.dylib`, `DerivedData/`, `*.img`/`*.iso`, etc. Once a tick commits them, they
are **tracked**.

Two things people *assume* will clean this up, but **won't**:

- ❌ **Adding the path to `.gitignore` does NOT untrack it.** `.gitignore` only
  stops *new untracked* files from being added. A file already tracked stays
  tracked, and `git add .` keeps staging its changes regardless of `.gitignore`.
  The bloat keeps riding along and gets pushed.
- ❌ **`chronos-push` does NOT clean it either.** The fold is content-preserving
  *on purpose* — it asserts the pushed tree equals `HEAD`'s tree. It will
  faithfully carry whatever is tracked, bloat included. It is a de-noiser, not a
  cleaner.

### The correct recipe

**Best: prevent it.** Before your first build in a new repo, make sure
`.gitignore` covers the build outputs for every language in the tree. If the
repo has **no** `.gitignore` at all, the hook refuses to stage and prints
`[CHRONOS ERROR] Missing .gitignore …` — write one first.

**If build output is already tracked** (you ran a build before the ignore was in
place, or inherited a dirty repo): untrack it, don't just ignore it.

```sh
# 1. Make sure .gitignore lists the build dirs/globs.
# 2. Untrack the already-committed copies — --cached keeps the files on disk,
#    only the git index entry is removed:
git rm -r --cached zig-out .zig-cache target node_modules
# (only paths that are genuine regenerable build output — see warning below)

# 3. Ship it. The untrack is a real tree change; after the fold the bloat is
#    gone from the pushed history, and future `git add .` won't re-add it
#    (now untracked AND ignored):
git push "chore: untrack build artifacts"
```

Quick check for tracked bloat at any time:

```sh
git ls-files | grep -iE 'zig-out/|\.zig-cache/|/target/|node_modules/|\.(a|o|so|dylib)$|\.DS_Store|DerivedData/'
```

### ⚠️ Do not over-untrack

- Use `--cached`. Plain `git rm -r zig-out` deletes the files from disk too —
  you may still need them to run/test.
- Untrack **only genuine regenerable output**. Never `git rm` source, fixtures,
  checked-in libraries (this repo intentionally tracks `libs/ios-libs/**/*.a`),
  or `Cargo.lock` for binaries (also intentionally kept). When unsure, leave it
  tracked and ask.
- `chronos-push` refuses to run with a dirty index/working tree — so commit (or
  let a tick capture) the untrack before pushing; it won't silently eat it.

---

## TL;DR for a working session

- Ticks pile up — ignore them, that's the design.
- `git push "message"` folds + pushes. Don't hand-squash; don't `git reset --hard`.
- `git add .` on every tick means an incomplete `.gitignore` = tracked bloat.
- `.gitignore` alone never untracks; use `git rm -r --cached`, then push.
- `chronos-push` preserves the tree exactly — it won't clean bloat for you.
