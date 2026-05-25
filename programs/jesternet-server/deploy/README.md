# jesternet-server deploy

Self-hosted Linux deployment via systemd. No Docker, no Cloud Run —
single static binary + a dedicated user + a hardened service unit.

## What's here

| File | Purpose |
|---|---|
| `jesternet-server.service` | systemd unit. Hardened: `ProtectSystem=strict`, `NoNewPrivileges`, syscall filter, `MemoryDenyWriteExecute`, no caps. |
| `setup.sh` | Idempotent installer. Creates `jesternet:jesternet` system user, `/var/lib/jesternet` data dir (0750), installs the binary to `/usr/local/bin`, the unit to `/etc/systemd/system`, enables + (re)starts the service, runs a health check. Re-running is safe — upgrades the binary, preserves the data dir. |
| `build-linux.sh` | Cross-compiles from any host (Mac/Linux/WSL) to x86_64-linux-gnu (default), x86_64-linux-musl, or aarch64-linux-gnu. Drops the binary next to `setup.sh` so the directory is ready to scp. |

## Workflow

**On the dev machine (Mac/Linux):**

```bash
cd programs/jesternet-server
./deploy/build-linux.sh         # → deploy/jesternet-server (x86_64 by default)
scp -r deploy/ user@target:/tmp/jesternet-deploy/
```

**On the target Linux box:**

```bash
ssh user@target
cd /tmp/jesternet-deploy
sudo ./setup.sh
```

The installer prints a health-check verdict + the useful followup
commands (`journalctl -u jesternet-server -f`, `systemctl status`,
etc.).

## Upgrading

Same workflow. setup.sh detects the existing install, replaces the
binary, reloads systemd, restarts the service. The data dir (WAL,
repos) survives.

```bash
./deploy/build-linux.sh
scp deploy/jesternet-server user@target:/tmp/
ssh user@target 'sudo ./setup.sh --bin /tmp/jesternet-server'
```

## Uninstalling

```bash
sudo ./setup.sh --uninstall              # stop + remove unit/user
                                         # PRESERVES /var/lib/jesternet
sudo ./setup.sh --uninstall --purge-data # also rm -rf the data dir
```

## Defaults

- **Binds 127.0.0.1:8080.** Public exposure goes through a reverse
  proxy of the operator's choice — `cloudflared` tunnel, nginx,
  Caddy, etc. Direct public binding is a one-line edit to the unit
  (`--host 0.0.0.0`) but needs CAP_NET_BIND_SERVICE if you want
  port 443 directly (the hardened unit doesn't grant any caps).
- **Data dir: `/var/lib/jesternet`** (0750, owned by `jesternet:jesternet`).
  Backed up via plain `cp -r` while the service is stopped or with
  `rsync` while running (the WAL is append-only so partial copies
  recover via replay on next start).
- **Workers: 64.** Per-instance concurrent connections. Matches the
  zig_ai_server Cloud Run config.
- **Logs: journald.** `journalctl -u jesternet-server -f` for live;
  journald handles rotation. No log files in `/var/log/jesternet`.

## Security hardening (what the unit actually does)

The systemd unit drops every privilege jesternet-server doesn't need.
The lock-down is comprehensive enough that even a remote-code-execution
in the server is heavily constrained:

- **No filesystem write access** except `/var/lib/jesternet`.
  `/usr`, `/etc`, `/var/log`, `/tmp` (private tmpfs), `/home` are
  all read-only or hidden.
- **No kernel surface:** `ProtectKernelTunables`,
  `ProtectKernelModules`, `ProtectKernelLogs`,
  `ProtectControlGroups`, `ProtectClock`, `ProtectProc=invisible`.
- **No capabilities** at all (`CapabilityBoundingSet=` empty).
- **No new privileges** (`NoNewPrivileges=true` — defeats setuid).
- **Memory W^X enforced** (`MemoryDenyWriteExecute=true` — Zig
  doesn't JIT, so this is free).
- **Network restricted** to `AF_INET` + `AF_INET6` only — no raw
  sockets, no netlink, no unix sockets.
- **Syscall filter:** `@system-service` baseline minus
  `@privileged`, `@resources`, `@debug`, `@mount`, `@cpu-emulation`,
  `@obsolete`. RCE → can't load a kernel module, can't ptrace,
  can't mount a fs.
- **Architectures: native only** (no x32/i386 syscall emulation).
- **Namespaces locked** (`RestrictNamespaces=true`).
- **No realtime priority**, no SUID/SGID, locked personality.

If the operator's threat model is lighter and the lockdowns get in
the way of legitimate operations (e.g. running git hooks inside the
data dir that need fork+exec), the corresponding `Protect*` /
`Restrict*` line can be relaxed. Each one is documented inline in
the unit so the reasoning for relaxing is visible at edit time.

## Reverse proxy (operator's responsibility)

Two practical patterns:

**Cloudflare Tunnel** (zero inbound port):

```bash
cloudflared service install <token>
# Then in the Cloudflare dashboard, point the tunnel at
# http://127.0.0.1:8080 — no public port needed on the box.
```

This is the pattern the audit's caveat about "raw listener on a
personal machine's public IP" recommends.

**Caddy** (simple TLS + HTTP/2 reverse proxy):

```caddyfile
git.example.com {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1   # so SSE streams flush immediately
    }
}
```

The `flush_interval -1` is important for the SSE notifications
endpoint — without it Caddy buffers the response and the event
stream batches up.

## What's NOT here

- **No backup script.** `cp -r /var/lib/jesternet` works; a real
  rotation policy is the operator's call (b2 sync, restic, hourly
  cron, etc.).
- **No log shipping.** journald keeps everything; add `journalbeat`
  or `vector` if you want central logging.
- **No multi-host HA.** The single-process-atomicity caveat from
  ZIG_PORT_AUDIT.md is binding here. Two boxes = two stores; the
  contract doesn't support sharing today.
