```markdown
# Migration Card: `/tmp/tmp.4B8VzrxwuA/files/posix.zig`

## 1) Concept

This file implements Zig's POSIX API layer (`std.posix`), providing low-level, libc-compatible wrappers for POSIX system calls and constants. It serves as a more portable alternative to direct OS-specific APIs (e.g., `std.os.linux`) while being lower-level than higher abstractions like `std.fs` or `std.process`. Key components include re-exported constants and types (e.g., `AF`, `O`, `Stat`, `iovec`), an `errno` helper for error detection, and public functions for file I/O (`read`, `write`, `open`, `fchmod`), process control (`fork`, `execveZ`), networking (`socket`, `bind`, `connect`), signals (`sigaction`, `kill`), memory mapping (`mmap`, `mprotect`), and more. Functions handle platform differences (e.g., Windows/WASI fallbacks, retries on `EINTR`), use precise error sets, and conditionally link libc or use direct syscalls.

The API emphasizes safety with Zig idioms: explicit error unions (e.g., `ReadError!usize`), null-terminated variants (e.g., `openZ`), fd-relative "at" functions (e.g., `openatZ`), and cross-platform portability notes (e.g., WTF-8 paths on Windows, UTF-8 on WASI).

## 2) The 0.11 vs 0.16 Diff

- **Explicit Allocator requirements**: No allocators used; all functions are stack-based or direct syscalls (unchanged from 0.11).
- **I/O interface changes**: Added fd-relative "at" variants with dependency injection (e.g., `fchmodat(dirfd, path, mode, flags)`, `openat(dirfd, path, flags, mode)` with precise `FChmodAtError`, `OpenError`); `fchmodat` now uses `fchmodat2` fallback on Linux 6.6+ or procfs workaround, returning `OperationNotSupported` for symlinks with `AT.SYMLINK_NOFOLLOW`. `readv`/`writev`/`preadv`/`pwritev` enforce `IOV_MAX` limits and fallback on non-supporting platforms (e.g., Windows to single `read`).
- **Error handling changes**: Switched to granular, platform-specific error sets (e.g., `ReadError!usize` with `WouldBlock`, `ConnectionResetByPeer`; `OpenError!fd_t` with `ProcessFdQuotaExceeded`, `WouldBlock`); many now include `UnexpectedError` catch-all. `errno` now handles libc/thread-local vs. direct syscall uniformly. Added `unexpectedErrno` for unhandled cases.
- **API structure changes**: `open`/`openat` now explicitly `@compileError` on Windows (use `std.fs.Dir.openFile`); `getrandom` prefers `getrandom(2)` over `/dev/urandom`; `abort`/`raise`/`kill` refined for no-libc; added `reboot`, `fchmodat`, `copy_file_range` with kernel-copy fallback to `pread`/`pwrite`; networking unified `sendto`/`sendmsg`/`recvfrom`/`recvmsg` with Windows WS2_32 handling; `realpath`/`realpathZ` now use `open`+`getFdPath` fallback without libc.

No `init`/`deinit` pairs; all are fire-and-forget syscalls like 0.11, but with better error granularity and platform shims.

## 3) The Golden Snippet

```zig
const fd = try std.posix.open("/tmp/example.txt", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
defer std.posix.close(fd);
var buf: [4096]u8 = undefined;
const nread = try std.posix.read(fd, &buf);
```

## 4) Dependencies

- `std.mem` (slicing, `toPosixPath`, `iovec`, `zeroes`)
- `std.fs` (`max_path_bytes`, `max_path_bytes_w`, path helpers, `Dir`, `OpenOptions`)
- `std.os` (OS tags, `linux`, `windows`, `wasi`; syscall wrappers)
- `std.math` (`maxInt`, `cast`)
- `std.debug` (`assert`)
- `std.heap` (`page_size_min`)
```
```