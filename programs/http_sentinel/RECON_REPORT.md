# http_sentinel Zigix-Native Build — Recon Report

**Goal**: Map the std.os.linux / syscall surface that `std.http.Client` +
`std.crypto.tls 1.3` + `std.Io.Threaded` + `std.heap.smp_allocator` actually
pull in, so we know exactly what `userspace/lib/zigix_io.zig` must cover.

**Method**: Built `tests/recon.zig` (a minimal `HttpClient.init → GET http →
GET https → POST https`) with `os_tag = .linux, abi = .none, link_libc =
false`, optimize=ReleaseSmall, target=aarch64. Disassembled the binary,
extracted every `mov w8, #N` immediately preceding `svc #0`, and
cross-referenced against `kernel/arch/aarch64/syscall.zig` SYS_* constants.

## Build result

- Builds cleanly. Zig std library is fully usable under `.linux/.none/no-libc`.
- Binary: 469 KB, statically linked, no PT_INTERP (no dynamic linker).
- 210 `svc #0` sites in `.text`. 188 with the syscall NR resolvable from the
  preceding `mov w8` immediate; 22 indirected through `os.linux.aarch64.syscallN`.
- 91 distinct syscall numbers referenced. Many are linked-but-unreachable
  scaffolding from `std.process` / `std.fs` transitive imports.

## Syscall surface vs. Zigix kernel coverage

### ✅ Already implemented in Zigix (`kernel/arch/aarch64/syscall.zig`)

Process / threads / signals:
`futex (98)`, `clone (220)`, `gettid (178)`, `getpid (172)`, `tgkill (131)`,
`tkill (130)`, `kill (129)`, `exit (93)`, `exit_group (94)`, `wait4 (260)`,
`execve (221)`, `set_tid_address (96)`, `set_robust_list (99)`, `rseq (293)`,
`prlimit64 (261)`, `rt_sigaction (134)`, `rt_sigprocmask (135)`,
`rt_sigreturn (139)`, `sigaltstack (132)`, `sched_yield (124)`,
`sched_getaffinity (123)`, `sched_setaffinity (123)`.

Memory:
`mmap (222)`, `munmap (215)`, `mremap (216)`, `mprotect (226)`, `brk (214)`,
`madvise (233)`.

Time / RNG:
`clock_gettime (113)`, `clock_nanosleep (114)`, `nanosleep (101)`,
`getrandom (278)`.

Sockets:
`socket (198)`, `bind (200)`, `listen (201)`, `accept (202)`, `connect (203)`,
`sendto (206)`, `recvfrom (207)`, `setsockopt (208)`, `getsockopt (209)`,
`shutdown (210)`, `getsockname (204)`, `ppoll (73)`, `epoll_create1 (20)`,
`epoll_ctl (21)`, `epoll_pwait (22)`.

Files (used by std.crypto.Certificate.Bundle to load `/etc/ssl/certs`):
`openat (56)`, `close (57)`, `read (63)`, `write (64)`, `readv (65)`,
`writev (66)`, `pread64 (67)`, `pwrite64 (68)`, `preadv (69)`, `pwritev (70)`,
`lseek (62)`, `newfstatat (79)`, `fstat (80)`, `statx (291)`, `getdents64 (61)`,
`readlinkat (78)`, `getcwd (17)`, `dup (23)`, `dup3 (24)`, `pipe2 (59)`,
`fcntl (25)`, `flock (32)`, `ftruncate (46)`, `fallocate (47)`,
`fsync (82)`, `fdatasync (83)`, `sync (81)`, `sendfile (71)`, `splice (76)`,
`tee (77)`, `copy_file_range (285)`, `unlinkat (35)`, `mkdirat (34)`,
`renameat (38)`, `renameat2 (276)`, `linkat (37)`, `symlinkat (36)`,
`fchmod (52)`, `fchmodat (53)`, `fchown (55)`, `fchownat (54)`,
`utimensat (88)`, `faccessat (48)`, `chdir (49)`, `umask`, `mknodat (33)`,
`statfs (43)`, `fstatfs (44)`.

### ❌ Real gaps (referenced by recon, NOT in Zigix kernel)

| NR | Name | Why std/Zig pulls it in | Zigix has? |
|---:|------|-------------------------|:----------:|
| 211 | `sendmsg` | `std.posix.sendmsg` — vectored / control-msg send (TLS records, fd-passing fallback) | **NO** |
| 212 | `recvmsg` | `std.posix.recvmsg` — peer of sendmsg | **NO** |
| 242 | `accept4` | `std.posix.accept4` — preferred over `accept` (atomic O_CLOEXEC/O_NONBLOCK) | **NO** |
| 269 | `sendmmsg` | std-lib feature probe (`have_sendmmsg = native_os == .linux`) | **NO** |
| 243 | `recvmmsg` | counterpart to sendmmsg | **NO** |
| 199 | `socketpair` | linked from `std.posix.socketpair`, likely unreachable on our path | **NO** |
| 439 | `faccessat2` | new flag-bearing variant; std probes & falls back | NO (graceful) |
| 452 | `fchmodat2` | same pattern as faccessat2 | NO (graceful) |

**Critical gaps** (item 1–3 above): `sendmsg`, `recvmsg`, `accept4`. The
`*mmsg` variants and `*at2` variants follow the std-lib **feature-probe
pattern**: try the modern syscall, fall back if kernel returns `ENOSYS`. So
returning `-ENOSYS` for those from Zigix's syscall dispatcher is sufficient
— std lib handles it.

`accept4` is HTTP-server-only; for an http_sentinel **client**, the call is
linked-but-unreached unless we run server code. We can defer it.

`sendmsg`/`recvmsg` are the genuinely needed ones, since `std.posix.write`
on a socket fd ultimately routes through scatter-gather APIs in some std
paths (notably TLS write path may use `sendmsg` for record framing).

### 🟡 Linked-but-likely-unreachable (no action needed)

Pulled in by transitive `std.process` / `std.fs` imports but unreachable
from `HttpClient.init → request → recv body` on a real run. Listed for
completeness; safe to ignore unless they show up in actual runtime traces:

`inotify_init1 (26)`, `getpriority (149)`, `getsid (154)`, `setpgid (143)`,
`getpgid (145)`, `rt_sigpending (136)`.

## Verdict on the three option-3 strategies

The recon makes the cost/value tradeoff much sharper:

### 3a — `os_tag = .linux, abi = .none, link_libc = false`
Add the 3 missing syscalls (`sendmsg`, `recvmsg`, `accept4`) to Zigix
kernel + ENOSYS stubs for `*mmsg`/`*at2`. http_sentinel binary runs
unmodified on Zigix. Static, no libc, raw `svc #0`. Same machine code as
zcurl/zsh, only the source attribution says `std.os.linux.write` instead
of `sys.write`. **Smallest delta, largest reuse, runs in days.**

### 3b — `zigix_io.zig` over `os_tag = .linux`
Write a custom `std.Io` impl that bottoms out in `userspace/lib/sys.zig`,
keep `os_tag = .linux` so `std.fs` / `std.process` still work via
`std.os.linux`. Reduces but does not eliminate `std.os.linux.*`
references — file-I/O for cert loading still goes through `std.posix`.
~800–1200 LoC, mostly modeled on `std/Io/Threaded.zig`. **Aesthetic
improvement, partial purity.**

### 3c — `os_tag = .freestanding, abi = .none` + full Zigix Io
True principled freestanding: roll our own `_start`, allocator, full
`std.Io` vtable (file I/O, sockets, threads, futex, RNG, clock), AND
either ship the CA bundle as an embedded const or wire `std.crypto.tls`
to call our Zigix file I/O instead of `std.fs`. ~2000–3000 LoC. **The
"human/Claude built an OS in Zig with its own libSystem" outcome.**

## Recommendation

I'd ship 3a first as a forcing function — within a day we'd have
http_sentinel actually running on Zigix calling api.anthropic.com over
TLS 1.3, which validates the kernel's Linux ABI surface end-to-end and
gives us a working comparison binary. Then iterate to 3c on top of that
known-good baseline. The recon syscall trace becomes the precise
implementation checklist for the Zigix Io vtable in 3c.

**Concrete next step (3a)**: add `sendmsg`/`recvmsg`/`accept4` handlers
in `kernel/arch/aarch64/syscall.zig`, return ENOSYS for `sendmmsg`/
`recvmmsg`/`faccessat2`/`fchmodat2`, build the recon binary into the
ext4 image, deploy to QEMU, then Axion.

If you'd rather skip 3a and go straight to the 3c lift, the recon
checklist above is what `zigix_io.zig` + freestanding startup must cover.
