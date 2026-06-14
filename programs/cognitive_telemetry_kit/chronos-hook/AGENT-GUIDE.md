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

# 3. Ship it. Future `git add .` won't re-add it (now untracked AND ignored).
#    Do steps 1-3 as ONE command so a tick can't fire between them (see race below):
git push "chore: untrack build artifacts"
```

This is enough **only if the bloat was never committed before** — i.e. this untrack
is the first time those paths enter unpushed history. If a build already baked
the bloat into an earlier unpushed commit, untracking now is *not* enough — see
"already baked into unpushed commits" below.

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

### When the bloat is already baked into unpushed commits (the slow-push case)

Symptom: you've untracked the build output and your **working tree / final tree
is clean**, but `git push` still hangs for minutes "sending something massive."

Why: `git push` ships every **object reachable from the commits being pushed**,
not just the final tree. If a build dumped 1.5 GB of `target/` into an earlier
unpushed commit and a later commit deleted it, those blobs still live *inside the
in-between commit* — so the push has to upload all of them even though the tip
tree is clean.

And `chronos-push` will **not** save you here: it drops `[CHRONOS]` ticks, but it
**replays your real commits reusing their exact trees**. Bloat baked into a *real*
(non-tick) commit's tree gets faithfully re-shipped. (Tick-only bloat *is* dropped
by the fold — the danger is bloat in real commits, or a tick that the fold turns
into the summary's base.)

Fix — collapse the whole unpushed range so **no pushed commit ever references the
blobs**, orphaning them. Because none of it is on origin yet, this rewrites only
*local unpushed* history (safe, no force-push):

```sh
git reset --soft origin/main      # keep ALL your real changes staged; drop the
                                  # intermediate commits (and their fat blobs)
git rm -r --cached <build paths>  # ensure the bloat isn't in the new tree either
# ...confirm .gitignore covers it...
git commit -m "feat: <your real work>"   # ONE commit, clean tree, no fat objects
git push                          # 2 seconds, not 2 minutes
```

`git reset --soft origin/main` is the surgical move: it preserves every real file
change in the index (nothing on disk is touched) while making the giant blobs
unreachable from any commit you'll push.

### Don't `git stash` a build dir, and mind the tick race

- **Never `git stash` build output to "clean" the tree.** Stashing a 1.5 GB
  `target/` writes all of it into a stash commit — that *is* the multi-minute
  hang. The state-preserving tool is `git rm --cached` (removes only the index
  entry, leaves files on disk and the rest of the repo untouched) — not stash,
  not `rm`.
- **The tick race:** a `PostToolUse` tick can fire `git add .` + commit *between*
  your commands and re-stage/re-commit the very thing you just cleaned ("staged
  count is now 0… chronos committed under me again"). Run the whole cleanup —
  ignore + `git rm --cached` + (`reset --soft` if needed) + commit + push — as
  **one** shell command, and snapshot `git rev-parse HEAD` / `git status` before
  and after so you can see if a tick interleaved.

---

## TL;DR for a working session

- Ticks pile up — ignore them, that's the design.
- `git push "message"` folds + pushes. Don't hand-squash; don't `git reset --hard`.
- `git add .` on every tick means an incomplete `.gitignore` = tracked bloat.
- `.gitignore` alone never untracks; use `git rm -r --cached`, then push.
- `chronos-push` drops ticks but replays real commits' trees verbatim — it won't
  clean bloat baked into a real commit. For that, `git reset --soft origin/<branch>`
  then re-commit once, so the fat blobs are orphaned and never pushed.
- Slow "massive" push = blobs living in an unpushed intermediate commit. Don't
  `git stash` the build dir to fix it (that's what's slow) — collapse the range.
- Do the whole cleanup in ONE command; a tick can `git add .` + commit between
  your steps and undo it.
