# Chronos D-Bus Deployment Guide

**Phase 2: D-Bus System Integration**

Chronos Daemon now uses D-Bus for system-wide IPC, replacing the interim Unix socket implementation.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  System D-Bus Message Bus                │
│            org.jesternet.Chronos service                 │
└─────────────────────────────────────────────────────────┘
                           │
                    ┌──────┴──────┐
                    │             │
            ┌───────▼────────┐    │
            │  chronosd-dbus │    │ (Privileged)
            │   (systemd)    │    │ User: chronos
            │ /var/lib/      │    │ Owns: tick.dat
            │ chronos/       │    │
            └────────────────┘    │
                                  │
        ┌────────────────┬────────┴────────┬─────────────┐
        │                │                 │             │
   ┌────▼──────┐  ┌──────▼─────┐  ┌───────▼────┐  ┌─────▼──────┐
   │chronos-ctl│  │ Agent #1   │  │ Agent #2   │  │  Clients   │
   │  (CLI)    │  │            │  │            │  │ (Unprivileged)
   └───────────┘  └────────────┘  └────────────┘  └────────────┘
```

### Security Model

**Centralized Privilege:**
- Only `chronosd-dbus` daemon writes to `/var/lib/chronos/tick.dat`
- Runs as dedicated `chronos` system user (created by systemd DynamicUser)
- Owns D-Bus service name `org.jesternet.Chronos`

**Decentralized Access:**
- All clients use unprivileged D-Bus method calls
- No file system permissions required
- D-Bus policy enforces access control

## Components

### 1. Daemon: `chronosd-dbus`

Production daemon with D-Bus SYSTEM bus integration.

**Source:** `chronosd-dbus.zig`
**Binary:** `/usr/local/bin/chronosd-dbus`
**Service:** `chronosd.service`

### 2. Client Library: `chronos_client_dbus.zig`

D-Bus client library for applications.

**Methods:**
- `connect(allocator, bus_type)` - Connect to daemon
- `getTick()` - Read current tick
- `nextTick()` - Increment and return tick
- `getPhiTimestamp(agent_id)` - Generate Phi timestamp
- `shutdown()` - Shutdown daemon (requires root)

### 3. CLI Tool: `chronos-ctl-dbus`

Command-line interface for administrators and scripts.

**Source:** `chronos-ctl-dbus.zig`
**Binary:** `/usr/local/bin/chronos-ctl`

**Commands:**
```bash
chronos-ctl ping              # Health check
chronos-ctl tick              # Get current tick
chronos-ctl next              # Increment tick
chronos-ctl stamp <agent-id>  # Generate Phi timestamp
chronos-ctl shutdown          # Shutdown daemon (root only)
chronos-ctl version           # Show version
```

### 4. D-Bus Bindings: `dbus_bindings.zig`

Zig FFI wrapper around C libdbus, following Guardian Shield's proven C interop pattern.

**Features:**
- Manual `DBusError` definition (handles opaque type issue)
- Connection management
- Message handling
- Type-safe wrappers

### 5. D-Bus Interface: `dbus_interface.zig`

Service definition and introspection XML.

**Service:** `org.jesternet.Chronos`
**Path:** `/org/jesternet/Chronos`
**Interface:** `org.jesternet.Chronos`

**Methods:**
- `GetTick() → u64`
- `NextTick() → u64`
- `GetPhiTimestamp(agent_id: String) → String`
- `LogEvent(agent_id, action, status, details: String) → String`
- `Shutdown()`

## Installation

### Step 1: Compile Binaries

```bash
# Compile daemon
zig build-exe chronosd-dbus.zig \
  -I/usr/include/dbus-1.0 \
  -I/usr/lib/dbus-1.0/include \
  -lc -ldbus-1 \
  -O ReleaseSafe

# Compile CLI tool
zig build-exe chronos-ctl-dbus.zig \
  -I/usr/include/dbus-1.0 \
  -I/usr/lib/dbus-1.0/include \
  -lc -ldbus-1 \
  -O ReleaseSafe
```

### Step 2: Install Binaries

```bash
sudo install -m 755 chronosd-dbus /usr/local/bin/chronosd-dbus
sudo install -m 755 chronos-ctl-dbus /usr/local/bin/chronos-ctl
```

### Step 3: Install D-Bus Policy

```bash
sudo install -m 644 org.jesternet.Chronos.conf /etc/dbus-1/system.d/
```

### Step 4: Install systemd Service

```bash
sudo install -m 644 chronosd.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### Step 5: Enable and Start Service

```bash
sudo systemctl enable chronosd.service
sudo systemctl start chronosd.service
```

### Step 6: Verify Deployment

```bash
# Check service status
sudo systemctl status chronosd.service

# Check D-Bus service
dbus-send --system --print-reply \
  --dest=org.jesternet.Chronos \
  /org/jesternet/Chronos \
  org.freedesktop.DBus.Introspectable.Introspect

# Test with chronos-ctl
chronos-ctl ping
chronos-ctl tick
chronos-ctl stamp SYSTEM-TEST
```

## D-Bus Policy

**File:** `/etc/dbus-1/system.d/org.jesternet.Chronos.conf`

Access control:
- ✅ All users: `GetTick`, `NextTick`, `GetPhiTimestamp`, `LogEvent`, `Introspect`
- 🔒 Root only: `Shutdown`
- 🔒 Chronos user only: Service ownership

## systemd Security Hardening

The service runs with extensive security restrictions:

**User Isolation:**
- `DynamicUser=yes` - Creates ephemeral system user
- `StateDirectory=chronos` - Grants `/var/lib/chronos` access only
- `PrivateTmp=yes` - Isolated /tmp

**File System:**
- `ProtectSystem=strict` - Read-only /usr, /boot, /efi
- `ProtectHome=yes` - No access to user home directories
- `ReadWritePaths=/var/lib/chronos` - Only writable path

**Process Isolation:**
- `NoNewPrivileges=yes` - Cannot gain privileges
- `PrivateDevices=yes` - No device access
- `ProtectKernelTunables=yes` - Kernel parameters read-only
- `MemoryDenyWriteExecute=yes` - W^X enforcement

**Capabilities:**
- `CapabilityBoundingSet=` - No capabilities
- `AmbientCapabilities=` - No ambient capabilities

**System Calls:**
- `SystemCallFilter=@system-service` - Whitelist approach
- `SystemCallFilter=~@privileged @resources` - Block dangerous calls

## Testing

### Session Bus Testing (Development)

For testing without root privileges:

```bash
# Start test daemon
./chronosd-dbus-test &

# Test with session bus
export CHRONOS_USE_SESSION_BUS=1
./chronos-ctl-dbus ping
./chronos-ctl-dbus tick
./chronos-ctl-dbus stamp TEST-AGENT
```

### System Bus Testing (Production)

Requires proper installation:

```bash
# No environment variable needed (defaults to SYSTEM bus)
chronos-ctl ping
chronos-ctl tick
chronos-ctl stamp PROD-AGENT
```

## Troubleshooting

### Daemon won't start

```bash
# Check systemd status
sudo systemctl status chronosd.service

# Check journal logs
sudo journalctl -u chronosd.service -f

# Common issues:
# - D-Bus policy not installed
# - /var/lib/chronos permissions
# - Binary not executable
```

### D-Bus policy rejection

```bash
# Error: "Request to own name refused by policy"
# Solution: Install D-Bus policy
sudo cp org.jesternet.Chronos.conf /etc/dbus-1/system.d/
sudo systemctl reload dbus
```

### Permission denied on tick file

```bash
# Error: Unable to read/write tick.dat
# Solution: Let systemd create the directory
sudo rm -rf /var/lib/chronos
sudo systemctl restart chronosd.service
```

### Client can't connect

```bash
# Check if D-Bus service is registered
dbus-send --system --print-reply \
  --dest=org.freedesktop.DBus \
  /org/freedesktop/DBus \
  org.freedesktop.DBus.ListNames | grep Chronos
```

## Migration from Unix Sockets

The D-Bus version replaces the Unix socket implementation:

| Feature | Unix Socket (Phase 1) | D-Bus (Phase 2) |
|---------|----------------------|-----------------|
| IPC | `/tmp/chronos.sock` | System D-Bus |
| Deployment | Manual | systemd |
| Security | File permissions | D-Bus policy |
| Discovery | Socket path | D-Bus name |
| Access Control | Socket perms | Policy rules |
| Multi-user | Limited | Full support |

**Breaking changes:**
- Client library API changed (socket → D-Bus)
- chronos-ctl now uses D-Bus methods
- Environment variable: `CHRONOS_USE_SESSION_BUS` for testing

**Compatible:**
- chronos.zig (core clock engine)
- phi_timestamp.zig (timestamp generation)
- Phi timestamp format
- Tick persistence (/var/lib/chronos/tick.dat)

## Files Summary

### Source Files
- `chronosd-dbus.zig` - D-Bus daemon (SYSTEM bus)
- `chronosd-dbus-test.zig` - Test daemon (SESSION bus)
- `chronos_client_dbus.zig` - Client library
- `chronos-ctl-dbus.zig` - CLI tool
- `dbus_bindings.zig` - C libdbus FFI wrapper
- `dbus_interface.zig` - Service definition

### Configuration Files
- `chronosd.service` - systemd unit file
- `org.jesternet.Chronos.conf` - D-Bus policy

### Installation Paths
- `/usr/local/bin/chronosd-dbus` - Daemon binary
- `/usr/local/bin/chronos-ctl` - CLI binary
- `/etc/systemd/system/chronosd.service` - Service unit
- `/etc/dbus-1/system.d/org.jesternet.Chronos.conf` - D-Bus policy
- `/var/lib/chronos/tick.dat` - Persistent tick (created by systemd)

## Phase 2 Complete

✅ D-Bus C bindings (libdbus FFI)
✅ D-Bus daemon with message loop
✅ D-Bus client library
✅ CLI tool with D-Bus integration
✅ systemd service with security hardening
✅ D-Bus policy with access control
✅ Full end-to-end testing
✅ Documentation

**Next:** Production deployment and integration with Guardian Shield agents.
