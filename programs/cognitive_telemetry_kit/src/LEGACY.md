# Legacy Linux capture stack

The sources in this directory are the **original Linux-first cognitive capture
path** and are kept for reference / Linux deployments. They are **not** part of
the maintained two-plane architecture (see the repo `README.md` →
"Current architecture" and `chronos-ledger/DESIGN.md`), and they are **not**
built or tested by the top-level `build.zig`.

| File | What it is | Status |
|---|---|---|
| `cognitive-oracle-v2.bpf.c` | eBPF kprobe on `tty_write()` — kernel-side TTY tap | Linux-only, untested here |
| `cognitive-watcher-v2.c` | Userspace daemon consuming the ring buffer → SQLite | Linux-only, untested here |
| `chronos-stamp-cognitive-direct.zig` | Standalone timestamp generator | Superseded by `chronos-hook` + `chronos-ledger` |
| `chronos_client_dbus.zig`, `dbus_bindings.zig` | D-Bus client/FFI for the oracle | Linux-only |
| `get-cognitive-state` | Shell state-extraction script | Superseded by the `get-cognitive-state/` Zig reader (macOS DYLD path) |
| `build.zig` | Build for the above | Standalone; not referenced by the top-level build |

Treat everything here as **unaudited legacy** per `zig-forge/CLAUDE.md`: do not
promote it as a library and do not wire it into money/auth/key paths. New work
belongs in `chronos-ledger/`, `chronos-hook/`, `ledger-daemon/`, and
`ledger-verify/`.
