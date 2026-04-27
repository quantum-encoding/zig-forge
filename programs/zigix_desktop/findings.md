# zigix_desktop — Security Findings

**Target:** `programs/zigix_desktop` — TUI desktop environment / window manager.
**Build modes:** Linux/macOS hosted (libc + `terminal_mux` PTY) and Zigix freestanding (raw syscalls + UART).
**Scope:** child-process spawn surface, PTY/FD lifecycle, env passthrough, input handling, freestanding allocator. No IPC sockets, no deeplinks, no auto-update, no config files, no token storage in this tree.
**Method:** manual read of all 11 source files (~2k LOC) + `qai security` regex/AST scanner. Scanner produced 75 in-tree hits, almost all stylistic (every `@intCast`, every `catch {}`, every `undefined`-init); the items below are the substantive ones plus issues only the manual review caught. No patches applied.

---

## Surface map

| Surface                   | Where                                       | Trust boundary crossed                       |
|---------------------------|---------------------------------------------|----------------------------------------------|
| Child process spawn       | `desktop.zig:61`, `platform/zigix.zig:54`   | desktop → child binary                       |
| PTY master read/write     | `window.zig:249,258`, `platform/linux.zig`  | desktop ↔ user shell                         |
| Env passthrough           | `desktop.zig:73`                            | parent env → child                           |
| Stdin raw-mode            | `platform/linux.zig:11`                     | terminal driver                              |
| Launcher input            | `launcher.zig:73`                           | keyboard → app selector                      |
| ANSI/keystroke forwarding | `main.zig:318` → `Window.sendInput`         | desktop input → focused PTY                  |
| `/proc` parse (Linux)     | `platform/linux.zig:107,131`                | kernel → desktop status                      |
| Freestanding allocator    | `platform/zigix.zig:137-167`                | bump arena over BSS                          |

Out-of-scope **and not present in this tree**: IPC unix sockets, abstract-namespace sockets, custom URL schemes, auto-update / signature verification, on-disk config parsing, persisted secrets/tokens. None of these surfaces exist; any future addition should be re-audited.

---

## Findings

### F-01 — PTY children inherit full parent environment (LD_PRELOAD / DYLD_* / IFS / BASH_ENV)
**Severity:** Medium (High if desktop is ever launched setuid, under sudo, or as a privileged service)
**File:** `src/desktop.zig:73-74`
**Code:**
```zig
const env = std.c.environ;
try pane.spawn(shell, env);
```
**Description:** The desktop forwards `std.c.environ` *wholesale* into every spawned PTY child. There is no allow-list, no scrub of dynamic-loader vars (`LD_PRELOAD`, `LD_AUDIT`, `LD_LIBRARY_PATH`, `LD_DEBUG_OUTPUT`, `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`), no scrub of shell-init vars (`BASH_ENV`, `ENV`, `IFS`, `PROMPT_COMMAND`, `PS4`, `SHELLOPTS`).
**Exploit sketch:** Anyone who can write a single env var into the desktop's environment before launch — a `.profile`-style file, a wrapper script, a privilege boundary that propagates env (sudo without `env_reset`, systemd unit without `Environment=`/`PassEnvironment=`) — gets arbitrary code execution in every child shell. If the desktop ever runs at higher privilege than the user controlling the env (e.g. console session manager, kiosk, root TTY), this is privilege escalation. `BASH_ENV=/tmp/x.sh` runs `/tmp/x.sh` in every non-interactive bash child; `PS4='$(curl …)'` fires on `set -x`.
**Fix sketch:** Build a sanitized envp: keep `TERM`, `LANG`/`LC_*`, `HOME`, `USER`, `PATH` (or replace with a known-good `_PATH_STDPATH`), `SHELL`. Strip everything beginning with `LD_`, `DYLD_`, `BASH_`, `PYTHON*`, `NODE_*`, `PERL*`, `RUBYOPT`, `GCONV_PATH`, `IFS`, `ENV`. For setuid scenarios use `secure_getenv` semantics — drop *all* dynamic-loader vars unconditionally.

---

### F-02 — `isProcessAlive` always returns `true` on Linux → unbounded child / PTY-fd leak
**Severity:** High (resource exhaustion / local DoS, eventual fd-table fill)
**File:** `src/platform/linux.zig:84-87`
**Code:**
```zig
pub fn isProcessAlive(handle: ProcessHandle) bool {
    _ = handle;
    return true; // TODO: waitpid(WNOHANG)
}
```
**Description:** `Desktop.reapDead()` (`desktop.zig:197`, called every 60 ticks from `main.zig:267`) iterates windows and closes any whose `isAlive()` returns false. On Linux the predicate never returns false. Children that exit naturally (`exit`, `Ctrl+D`, `SIGPIPE`, etc.) are never reaped, never `waitpid`'d, and the wrapping `Window`/`Pane` is never `deinit`'d. Each exit leaks one zombie PID, one PTY master fd, the `Pane` allocations, and one `MAX_WINDOWS` slot. After 16 exits the desktop refuses to spawn new shells (`error.TooManyWindows` at `desktop.zig:62`).
**Exploit sketch:** Open the launcher (Ctrl+Alt+L), pick anything that exits fast (e.g. `less` with `q`); repeat 16× — desktop can no longer spawn a new window even though zero are visible. With a child the user controls (`bash -c "exit 0"` via a custom command), the window-list will fill in seconds. Beyond functional DoS, the per-process fd cap (`RLIMIT_NOFILE`, default 1024) is reachable across long sessions because PTY master fds are large.
**Fix sketch:** Implement properly via `pane.isAlive()` (the underlying `terminal_mux` Pane should already track child exit) or `posix.waitpid(pid, &status, WNOHANG)` returning the child pid on exit. Reap on every poll, not on a 1Hz tick.

---

### F-03 — Child fd inheritance: no `FD_CLOEXEC` / no close before `execve` (both backends)
**Severity:** Medium (privilege boundary blur, info disclosure between siblings)
**Files:**
- `src/platform/zigix.zig:54-67` (Zigix `spawnProcess` — fork+execve, no fd hygiene)
- `src/desktop.zig:67-77` (Linux: relies on `terminal_mux.Pane.spawn` to do the right thing — *unverified in this tree*)
- `src/platform/linux.zig:181-189` (`readProcFile` — `c.open()` with no `O_CLOEXEC`)
**Description:** On the Zigix path the child inherits the *full* parent fd table — every previously-spawned window's I/O fds (`handle.read_fd`/`handle.write_fd` recorded in `ProcessHandle`), plus the desktop's stdin/stdout/UART. There is no `dup2` to set up the child's own stdio and no loop to close higher fds. `setNonBlocking` on Linux only touches the master end and ignores `O_CLOEXEC`. The hosted `readProcFile` uses raw `open()` without `O_CLOEXEC`, so if a child's exec races a stat read, the `/proc/stat` fd leaks into the new process.
**Exploit sketch (Zigix path):** Spawn shell A, then shell B. Shell B inherits A's `read_fd`/`write_fd`. From B: `read 0<&N` where N is A's fd lets B silently observe everything the user types into A; `cat >&M` lets B inject keystrokes into A. Cross-pane keystroke injection inside a single user session may not seem dramatic — but if the user ever types `sudo` credentials into A, B sees them.
**Fix sketch:**
1. In `spawnProcess`: between `fork` and `execve`, `close()` all fds above stderr (or set `O_CLOEXEC` on every open and dup2 the desired stdio).
2. Use `pipe2(O_CLOEXEC)` rather than `pipe`, `open(…, O_CLOEXEC)`, `socket(…, SOCK_CLOEXEC)`.
3. Verify `terminal_mux.Pane.spawn` does not pass the master fd to the child (it almost certainly closes the master in the child branch — but assert it).

---

### F-04 — Zigix `execve` invoked with NULL `argv` and NULL `envp`
**Severity:** Medium (reliability / undefined kernel behavior; under aggressive ABIs, child crash → reliable DoS for the launcher)
**File:** `src/platform/zigix.zig:65`
**Code:**
```zig
_ = sys.execve(@ptrCast(&path_buf), 0, 0);
```
**Description:** POSIX requires `argv` to be a non-NULL, NULL-terminated array, and `argv[0]` must point to the program name. Many programs immediately `argv[0]` deref (every libc `__progname` setup, every `getopt`, anything that prints `usage: $0 …`). Linux historically *tolerates* `argv=NULL` (treats as empty), but the loaded program will SIGSEGV on first arg access. A custom Zigix kernel ABI may EFAULT or return -EINVAL.
**Exploit sketch:** Not an attacker primitive directly — it's a guaranteed *self-inflicted* crash for any non-trivial child. For zigix-only red-team use: kernel's execve handler MUST validate the argv pointer before deref; if it doesn't, `argv=NULL` is a kernel-side fault (test surface for the kernel, not this binary).
**Fix sketch:** Build `argv = [_][*:0]const u8{ &path_buf, null }` and pass `@ptrCast(&argv)`. Always populate at least argv[0]. Pass a zeroed `envp = [_]?[*:0]const u8{null}` rather than the integer `0`.

---

### F-05 — Path-length validation only inside child after `fork`
**Severity:** Low (resource waste; no security primitive)
**File:** `src/platform/zigix.zig:60-66`
**Code:**
```zig
if (pid_raw == 0) {
    var path_buf: [256]u8 = undefined;
    if (path.len >= 256) sys.exit(127);
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    _ = sys.execve(@ptrCast(&path_buf), 0, 0);
    sys.exit(127);
}
```
**Description:** Length is checked *only* in the child. Parent forks, then learns nothing — child silently exits 127, looks like an exec failure. No info on cause.
**Fix:** Validate `path.len < 256` *before* `fork()`; return `error.PathTooLong`.

---

### F-06 — Pure-mode loop: any 0x1B byte forces immediate quit
**Severity:** Low → Medium (trivial DoS via pasted text or escape-emitting child)
**File:** `src/main.zig:181-191`
**Code:**
```zig
for (input_buf[0..n]) |byte| {
    if (byte == 0x1B) {
        // ESC — could be alt-key or standalone escape
        // Simplified: treat as escape key
        quit_requested = true;
        break;
    }
    if (byte == 0x03) { quit_requested = true; break; }
    if (desktop.getFocused()) |win| { win.sendInput(input_buf[0..n]); }
    break;
}
```
**Description:** The freestanding event loop quits on the *first* 0x1B byte read from UART. Any keypress that begins with ESC (arrow keys: `\x1B[A`), any pasted ANSI sequence, any DSR cursor-position reply (`\x1B[6n` → `\x1B[12;5R`) sent by a *child program* through the UART, kills the desktop. Ctrl+C (0x03) likewise quits unconditionally even though the comment says it's an attempt to handle Ctrl+C. Every escape-emitting TUI app the user runs (vim, htop, nano, less) will close the desktop on first redraw.
**Exploit sketch:** From the freestanding session, a child process emits `\x1B` to stdout — the desktop's read loop reads it and quits, taking the rest of the session with it. With multiple windows, sibling processes are also lost.
**Fix sketch:** Parse ANSI sequences (`\x1B[…final-byte`) and forward them to the focused window; only treat *standalone* `\x1B` (not followed within a few ms by `[`/`O`) as the user's exit key — and even then prefer Ctrl+Alt+Q (already wired) for quit. Don't treat 0x03 as exit; forward it to the child as SIGINT-equivalent.

---

### F-07 — Public `Desktop.createWindow(path)` accepts arbitrary `[]const u8`
**Severity:** Low *today* (no current caller passes user input)
**File:** `src/desktop.zig:61`
**Description:** `createWindow` takes any path and `pane.spawn`s it. Currently invoked only with hardcoded constants (`/bin/bash`, `/bin/zsh`, the `apps[]` table in `launcher.zig:23`). Launcher input is filtered against the hardcoded table — user can't type a free-form path. **However**, the API exposes the primitive: a future contributor wiring the launcher's text buffer to `createWindow(self.input_buf[0..self.input_len])` introduces immediate command execution with no validation, no PATH search, no allow-list. The current `apps[]` entries `zigix-monitor`, etc. (relative names) already rely on the child's PATH lookup — meaning a user-writable directory earlier in PATH wins.
**Fix sketch:** (a) Resolve to an absolute, canonical path before spawn, reject relative names. (b) Maintain an explicit allow-list and have `createWindow` accept an `AppDef` enum, not a string. (c) Document the API as "trusted callers only" if the string-form is intentional.

---

### F-08 — `setNonBlocking` failure swallowed → polling loop can block indefinitely
**Severity:** Low (reliability / lock-up, not security in classic sense)
**File:** `src/desktop.zig:75`
**Code:**
```zig
setNonBlocking(pane.getFd()) catch {};
```
**Description:** If `fcntl(F_GETFL)` or `F_SETFL` fails (rare but possible on a malformed fd, EINTR, or a pseudo-terminal driver quirk), the catch silently drops the error. Subsequent `pane.readOutput` (`window.zig:263`) is then blocking. `Desktop.pollAllOutputs` in the tick handler will hang the entire UI on the first window with no available input — the desktop stops rendering, stops accepting keys, looks frozen. From a user-visible standpoint this is a hang condition.
**Fix:** propagate the error and either fail the spawn or close the window with an explicit error message to the user.

---

### F-09 — `wait4` not WNOHANG-safe; reaped-pid recycle race (Zigix)
**Severity:** Low
**File:** `src/platform/zigix.zig:87-89`
**Code:**
```zig
pub fn isProcessAlive(handle: ProcessHandle) bool {
    const result = sys.wait4(handle.pid, 0, 1); // WNOHANG=1
    return @as(i64, @bitCast(result)) != @as(i64, @bitCast(handle.pid));
}
```
**Description:**
1. `wait4` here passes `status=0` (NULL pointer) — fine if kernel accepts NULL, but exit-status info is silently discarded; child crashes (signal exit) cannot be distinguished from clean exit.
2. After the first reap, if the kernel re-uses `handle.pid` for a *different* user-spawned child (out-of-band spawn from terminal), the next `isProcessAlive` call could match against the new process. Real exposure depends on Zigix scheduler PID-reuse policy. Mitigated in practice because once `false` is returned, the slot is closed and the handle is destroyed — but worth tracking exit status to avoid the ambiguity.
**Fix:** pass a `&status` pointer; treat any non-zero return as exited; on `0` (still running) leave alone; on negative (-ECHILD) treat as already-reaped → exited.

---

### F-10 — `std.os.linux.ioctl` used unconditionally on macOS path
**Severity:** Low (correctness — not security)
**File:** `src/platform/linux.zig:38`
**Code:**
```zig
const TIOCGWINSZ: u32 = if (@import("builtin").os.tag == .macos) 0x40087468 else 0x5413;
…
const result = std.os.linux.ioctl(posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
```
**Description:** macOS does not expose Linux syscalls. `std.os.linux.ioctl` invokes the Linux syscall instruction; on macOS this is either ENOSYS or a wrong-syscall match. The function then silently falls back to the 80×24 default, masking the failure. Build is documented as "Linux/macOS hosted" in `build.zig:48`.
**Fix:** Use `std.posix.system.ioctl` or `@cImport(<sys/ioctl.h>)` so the right ABI is selected per OS.

---

### F-11 — `bufPrint` truncation falls through to a literal `" ? "` placeholder
**Severity:** Info (defense-in-depth; no current overflow possible)
**Files:** `src/window.zig:173`, `src/panel.zig:55`
**Description:** Buffer sizing covers every legitimate input length (`MAX_TITLE_LEN+24`, `tag_buf[32]`), so `bufPrint` should never fail. Still, the silent fallback to `" ? "` masks the failure mode and would let a future contributor enlarge `MAX_TITLE_LEN` (currently 64) past the buffer without noticing. Title text is set from `baseName(shell)` (`desktop.zig:64`) — currently sourced from the launcher's hardcoded `apps[]`, but if window titles ever come from PTY OSC-0 sequences (typical xterm title-set escape), the input becomes attacker-controlled. With a 256-byte OSC payload and a 32-byte buffer, the fallback hides the truncation rather than refusing a too-long title.
**Fix:** Compute the truncated copy explicitly with `@min(name.len, MAX_TITLE_LEN)` already done in `setTitle` — apply the same discipline at every `bufPrint` site, or treat `bufPrint` failure as a hard panic in debug.

---

### F-12 — Freestanding arena: 16-byte alignment, but no overflow check on `aligned`
**Severity:** Info
**File:** `src/platform/zigix.zig:141-145`
**Code:**
```zig
fn arenaAlloc(_: *anyopaque, n: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const aligned = (arena_pos + 15) & ~@as(usize, 15);
    if (aligned + n > ARENA_SIZE) return null;
    arena_pos = aligned + n;
    return arena_buf[aligned..].ptr;
}
```
**Description:** The vtable's `Alignment` parameter is ignored — every allocation is 16-byte aligned even if the type requires 64. For `Cell` and `u8` buffers used here this is fine, but a future caller with `@alignOf(T) > 16` will see misaligned pointers (UB on RISC-V/aarch64 with strict alignment, slow on x86_64). `aligned + n` is computed on `usize`; with `arena_pos < ARENA_SIZE = 256 KiB` and `n` allocator-bounded, no overflow today, but if anyone bumps `ARENA_SIZE` past `usize::MAX − 16` (impossible in practice on 64-bit, possible on 32-bit) this overflow check breaks. Cosmetic. `arenaResize`/`arenaFree` are no-ops — every shrink-in-place fails, every free leaks until process exit. With one `Buffer` ever allocated (`main.zig:173`), bounded.
**Fix:** Honour the `Alignment` parameter; use `std.mem.alignForward(arena_pos, alignment.toByteUnits())`.

---

### F-13 — Inline asm in `_start` flagged Critical by scanner
**Severity:** Info (false positive — required for freestanding entry)
**File:** `src/main.zig:48-72`
**Description:** Scanner flags `asm volatile (…)` as "bypasses all of Zig's safety guarantees." This is the freestanding `_start` thunk that sets up the stack pointer and calls `main`; it has to be inline asm, and the sequences (`mv a0, sp; andi sp, sp, -16; call main`) are the canonical RISC-V/aarch64 entry stubs. No mitigation needed beyond the existing 16-byte stack alignment.

---

## Items checked and OK

- `containsInsensitive` / `toLower` (`launcher.zig:233-253`) — bounded loops, ASCII-only, no overflow.
- Launcher input length capped to `MAX_INPUT_LEN=64` and only printable ASCII 0x20..0x7E accepted (`launcher.zig:81-86`) — no TTY-control injection into the input field.
- `Desktop.closeFocused` / `closeWindow` array shift — bounds-checked, no UAF.
- `tiledCols(0)` cannot be reached (`recalculateLayout` early-returns on `window_count == 0`) — no divide-by-zero.
- `keyToBytes` UTF-8 encode buffer is 16 bytes, max UTF-8 codepoint is 4 bytes + 1 ESC = 5 ≤ 16. Safe.
- `renderBufferToUart` buffer flush threshold (`main.zig:250`) keeps writes under `render_buf.len`. Safe.
- No outbound network; no TLS verification surface; no signature surface; nothing to bypass.
- No filesystem writes outside the implicit ones inside `terminal_mux.Pane` (out of scope here).
- No setuid/setgid manipulation in this tree.

---

## Priority

1. **F-02** — fix the `isProcessAlive` stub before anything else; current behavior is functional + guaranteed to hit users.
2. **F-01** — sanitize child env *before* this binary is shipped to any context that might run with elevated privileges.
3. **F-03** — close-on-exec discipline across both backends.
4. **F-06** — fix the pure-mode escape handler; today the freestanding desktop dies on the first arrow-key press.
5. **F-04 / F-05** — Zigix execve hygiene.
6. Lower-severity items as time permits.

No dependent-module audit done: `terminal_mux` and `zig_tui` were treated as trusted. F-01 / F-03 mitigations may need to flow into `terminal_mux.Pane.spawn`.
