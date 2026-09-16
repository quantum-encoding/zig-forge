# zig_darwin_kit

Helpers for calling Apple's C frameworks from Zig: Objective-C block construction, mach time, audit tokens, runtime macOS version, and ownership of `malloc`ed and length-prefixed strings.

These are the pieces that had to be hand-rolled every time a Zig program touched EndpointSecurity, libdispatch or XPC. Each module is small, has no dependency beyond libc, and is anchored against the Apple implementation it interoperates with.

## Modules

| Module | What it gives you | Anchored against |
|---|---|---|
| `block` | `Block(Ctx, handler)`: a Zig function plus a captured context laid out as a clang `Block_literal`; stack literal, `_Block_copy` heap copy, global block, direct `call` | libdispatch (`dispatch_sync`, `dispatch_async` copies and invokes the block on another thread), `_Block_copy`/`_Block_release` refcounting |
| `machtime` | ticks ⇄ nanoseconds, `nanosUntil(deadline)`, timespec/timeval → ns | kernel `CLOCK_UPTIME_RAW` (defined by Apple as `mach_absolute_time` in ns) |
| `audit_token` | `AuditToken` with `pid/euid/ruid/egid/rgid/auid/asid/pidversion`, `current()` via `task_info`, `sameExecution` | libbsm `audit_token_to_*` on the live process token; `getpid`/`geteuid`/`getuid` |
| `os_version` | `current()` → `Version{major, minor, patch}`, `atLeast` | `uname` release major (equals product major since macOS 26) |
| `cmem` | `Slice(T)` borrows a `malloc`ed out-parameter array and frees it; `take` copies into a Zig allocator; `CString`/`takeString` | libc `malloc`/`strdup`/`free` round trips |
| `zstr` | `pathZ` NUL-terminates a length-prefixed string on the stack (cuts at the first embedded NUL); `dupeZ` on the heap | – |

## Blocks

```zig
const darwin = @import("darwin_kit");

const Ctx = extern struct { hits: *u32 };
const B = darwin.Block(Ctx, struct {
    fn run(ctx: *Ctx, client: *anyopaque, msg: *const anyopaque) void { ... }
}.run);

const block = try B.create(.{ .hits = &hits });   // heap, one reference owned by you
defer block.release();
_ = es_new_client(&client, block.ref());          // ES takes its own reference
```

`Ctx` must have a defined layout (`extern struct`, pointer, integer): `_Block_copy` copies it bit for bit and no copy/dispose helpers are emitted. A stack literal (`initStack`) is only valid at its original address while in scope; use it for synchronous callers such as `dispatch_sync` and `es_sync_client`.

Passing a plain function pointer where a block is expected is undefined behaviour: the runtime dereferences the pointer as a `Block_literal` (`isa`, `flags`, `invoke`) and calls through whatever bytes it finds.

## Mutation tests (2026-09-16)

Each anchor was broken deliberately and observed to fail before being restored:

| Mutation | Observed |
|---|---|
| Block descriptor `size` set to the 32-byte header only | `dispatch_async` test and copy/release test segfault (truncated context copied) |
| `invoke` moved before `flags`/`reserved` | layout test red, `dispatch_sync` test aborts |
| `AuditToken.pid()` reads index 4 instead of 5 | libbsm anchor red (`expected 64514, found 20`), `getpid` anchor red |
| `numer`/`denom` swapped in the cached timebase | round-trip test and `CLOCK_UPTIME_RAW` anchor red |

## Build

```
zig build test      # 24 tests; links libbsm for the audit-token anchor only
```

Consume from another package with a path dependency:

```zig
// build.zig.zon
.darwin_kit = .{ .path = "../zig_darwin_kit" },
// build.zig
const darwin_kit = b.dependency("darwin_kit", .{ .target = target, .optimize = optimize });
mod.addImport("darwin_kit", darwin_kit.module("darwin_kit"));
```

macOS only. Zig 0.16.
