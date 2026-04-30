# Guardian ESD - Endpoint Security Daemon

Kernel-level file protection for macOS using Apple's Endpoint Security Framework.

## Requirements

- macOS 13.0+
- Apple Developer account
- `com.apple.developer.endpoint-security.client` entitlement (must request from Apple)
- Code signing with proper provisioning profile

## Build

```bash
# Build the binary
swift build -c release

# Binary location
.build/release/guardian-esd
```

## Code Signing

Once you have your Apple Developer account approved:

```bash
# Sign with entitlements
codesign --force --sign "Developer ID Application: YOUR_NAME (TEAM_ID)" \
    --entitlements guardian-esd.entitlements \
    --options runtime \
    .build/release/guardian-esd

# Verify signature
codesign -dv --verbose=4 .build/release/guardian-esd
```

## Installation

```bash
# Install to /usr/local/bin
sudo cp .build/release/guardian-esd /usr/local/bin/

# Run (must be root)
sudo /usr/local/bin/guardian-esd
```

## User Approval

After first run, users must approve in:
- System Preferences → Privacy & Security → Security
- Look for "Guardian ESD" and click "Allow"

## LaunchDaemon (Auto-start)

Create `/Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.quantumencoding.guardian-esd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/guardian-esd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/guardian-esd.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/guardian-esd.log</string>
</dict>
</plist>
```

Load it:
```bash
sudo launchctl load /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist
```

## Emergency Disable

If something goes wrong:

```bash
# Create kill switch file
touch /tmp/.guardian_esd_disable

# Or stop the daemon
sudo launchctl stop io.quantumencoding.guardian-esd
sudo launchctl unload /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist
```

## Events Monitored

| Event | Description |
|-------|-------------|
| AUTH_UNLINK | File deletion |
| AUTH_RENAME | File/directory rename/move |
| AUTH_TRUNCATE | File truncation |
| AUTH_LINK | Hard link creation |
| AUTH_CREATE | File creation |
| AUTH_CLONE | File cloning |
| AUTH_EXCHANGEDATA | Data exchange |
| AUTH_SETEXTATTR | Extended attribute modification |
| AUTH_DELETEEXTATTR | Extended attribute deletion |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    macOS Kernel                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │         Endpoint Security Framework                  │    │
│  │                                                      │    │
│  │  Process → syscall → ES Hook → guardian-esd         │    │
│  │                           ↓                          │    │
│  │                    ALLOW or DENY                     │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Comparison with DYLD (libmacwarden)

| Attack Vector | DYLD | ESF (this) |
|---------------|------|------------|
| Normal libc calls | ✅ | ✅ |
| Go direct syscall | ❌ | ✅ |
| Rust direct syscall | ❌ | ✅ |
| Assembly svc #0x80 | ❌ | ✅ |
| System binaries | ❌ | ✅ |

## License

Dual License - MIT (Non-Commercial) / Commercial License
Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
