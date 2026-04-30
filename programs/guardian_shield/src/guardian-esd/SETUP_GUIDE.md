# Guardian ESD - Complete Setup Guide

This guide covers everything needed to deploy Guardian ESD once your Apple Developer account with Endpoint Security entitlement is approved.

## Overview

Guardian ESD provides **kernel-level file protection** on macOS using Apple's Endpoint Security Framework (ESF). Unlike DYLD interposition (libmacwarden), ESF operates at the kernel level and catches ALL file operations - including direct syscalls from Go, Rust, and assembly code.

### Protection Comparison

| Attack Vector | libmacwarden (DYLD) | guardian-esd (ESF) |
|---------------|---------------------|-------------------|
| Normal libc calls | Yes | Yes |
| Go direct syscall | **No** | Yes |
| Rust direct syscall | **No** | Yes |
| Assembly svc #0x80 | **No** | Yes |
| System binaries | **No** (SIP blocks) | Yes |
| Runs as daemon | No | Yes |

## Prerequisites

### 1. Apple Developer Account

You need an **Apple Developer Program** membership ($99/year):
- https://developer.apple.com/programs/

### 2. Endpoint Security Entitlement

This is a **restricted entitlement** that requires Apple approval:

1. Log into https://developer.apple.com/account
2. Go to **Certificates, Identifiers & Profiles**
3. Under **Identifiers**, create a new App ID:
   - Platform: macOS
   - Bundle ID: `io.quantumencoding.guardian-esd` (or your own)
   - Description: Guardian ESD - Endpoint Security Daemon

4. Request the entitlement:
   - Go to https://developer.apple.com/contact/request/system-extension/
   - Or: Account → Certificates → Request → System Extension
   - Select **Endpoint Security**
   - Explain use case: "File integrity protection daemon for development environments"
   - Apple typically responds within 1-2 weeks

### 3. Provisioning Profile

Once approved, create a provisioning profile:

1. Go to **Profiles** in your developer account
2. Click **+** to create new profile
3. Select **macOS App Development** (for testing) or **Developer ID** (for distribution)
4. Select your App ID with the ES entitlement
5. Select your Mac's development certificate
6. Download the `.provisioningprofile` file

## Building

### 1. Build the Binary

```bash
cd /Users/director/work/quantum-zig-forge/programs/guardian_shield/src/guardian-esd

# Build release
swift build -c release

# Binary is at:
# .build/release/guardian-esd
```

### 2. Create Developer ID Certificate (if not exists)

```bash
# List existing certificates
security find-identity -v -p codesigning

# You should see something like:
# "Developer ID Application: Your Name (TEAMID)"
```

If you don't have one:
1. Open Keychain Access
2. Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority
3. In developer portal, create a Developer ID Application certificate
4. Download and double-click to install

### 3. Code Sign with Entitlements

```bash
# Replace with your actual identity
IDENTITY="Developer ID Application: Richard Tune (YOURTEAMID)"

# Sign the binary
codesign --force --sign "$IDENTITY" \
    --entitlements guardian-esd.entitlements \
    --options runtime \
    --timestamp \
    .build/release/guardian-esd

# Verify signature
codesign -dv --verbose=4 .build/release/guardian-esd

# Check entitlements are embedded
codesign -d --entitlements :- .build/release/guardian-esd
```

Expected output should show:
```xml
<key>com.apple.developer.endpoint-security.client</key>
<true/>
```

## Installation

### 1. Install Binary

```bash
sudo cp .build/release/guardian-esd /usr/local/bin/
sudo chmod 755 /usr/local/bin/guardian-esd
```

### 2. First Run (Manual Test)

```bash
# Run manually first to trigger user approval
sudo /usr/local/bin/guardian-esd
```

You should see:
```
Guardian ESD - Endpoint Security Daemon
========================================
[*] Initializing Endpoint Security client...
[+] ES client created successfully
[+] Subscribed to 9 event types
[+] Protected paths:
    - /Users/director/work
    - /Users/director/websites
    ...
[+] Guardian Shield ACTIVE - Kernel-level protection enabled
```

### 3. User Approval (Required)

After first run, macOS requires user approval:

1. Open **System Preferences** (or System Settings on macOS 13+)
2. Go to **Privacy & Security** → **Security**
3. Look for "System software from application 'guardian-esd' was blocked"
4. Click **Allow**

You may also need to approve in:
- **Privacy & Security** → **Full Disk Access** (if needed)
- **Privacy & Security** → **Endpoint Security** (if shown)

### 4. Install as LaunchDaemon (Auto-start)

Create the plist file:

```bash
sudo tee /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist > /dev/null << 'EOF'
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
EOF

# Set permissions
sudo chmod 644 /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist
sudo chown root:wheel /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist

# Load daemon
sudo launchctl load /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist

# Check status
sudo launchctl list | grep guardian
```

## Configuration

Edit `Sources/GuardianESD/main.swift` before building to customize:

```swift
struct GuardianConfig {
    // Paths that cannot be modified
    static let protectedPaths: [String] = [
        "/Users/director/work",
        "/Users/director/websites",
        "/Users/director/.ssh",
        "/Users/director/.gnupg",
        "/Users/director/.aws",
        // Add more paths here
    ]

    // Paths that are always allowed
    static let whitelistedPaths: [String] = [
        "/tmp",
        "/private/tmp",
        "/var/folders",
        // Add more paths here
    ]

    // Trusted processes (bypass all checks)
    static let trustedProcesses: [String] = [
        "/usr/bin/git",
        "/usr/local/bin/git",
        "/opt/homebrew/bin/git",
        // Add more trusted binaries here
    ]
}
```

## Operations

### View Logs

```bash
# Real-time log viewing
tail -f /var/log/guardian-esd.log

# View recent blocks
grep BLOCKED /var/log/guardian-esd.log
```

### Stop Daemon

```bash
sudo launchctl stop io.quantumencoding.guardian-esd
```

### Start Daemon

```bash
sudo launchctl start io.quantumencoding.guardian-esd
```

### Unload Daemon

```bash
sudo launchctl unload /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist
```

### Reload After Code Changes

```bash
# Rebuild
swift build -c release

# Re-sign
codesign --force --sign "$IDENTITY" \
    --entitlements guardian-esd.entitlements \
    --options runtime \
    --timestamp \
    .build/release/guardian-esd

# Replace and restart
sudo launchctl stop io.quantumencoding.guardian-esd
sudo cp .build/release/guardian-esd /usr/local/bin/
sudo launchctl start io.quantumencoding.guardian-esd
```

## Emergency Procedures

### Quick Disable (Kill Switch)

If guardian-esd is blocking legitimate operations:

```bash
# Create kill switch file - immediately disables all blocking
touch /tmp/.guardian_esd_disable

# Guardian will now allow all operations
# Remove when ready to re-enable:
rm /tmp/.guardian_esd_disable
```

### Complete Removal

```bash
# Stop and unload daemon
sudo launchctl stop io.quantumencoding.guardian-esd
sudo launchctl unload /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist

# Remove files
sudo rm /Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist
sudo rm /usr/local/bin/guardian-esd
sudo rm /var/log/guardian-esd.log
```

### Recovery Mode

If the system becomes unusable (extremely unlikely with current config):

1. Reboot into Recovery Mode (hold Command+R during boot)
2. Open Terminal from Utilities menu
3. Mount your main volume: `diskutil mount /Volumes/Macintosh\ HD`
4. Remove the daemon:
   ```bash
   rm "/Volumes/Macintosh HD/Library/LaunchDaemons/io.quantumencoding.guardian-esd.plist"
   ```
5. Reboot normally

## Troubleshooting

### "Missing entitlement" Error

```
[-] ERROR: Missing entitlement
    Need: com.apple.developer.endpoint-security.client
```

**Cause**: Binary not properly signed with ES entitlement.

**Fix**:
1. Verify entitlement was approved in developer portal
2. Re-sign with correct certificate and entitlements file
3. Check embedded entitlements: `codesign -d --entitlements :- guardian-esd`

### "Not permitted" Error

```
[-] ERROR: Not permitted
    Must run as root: sudo ./guardian-esd
```

**Cause**: Not running as root.

**Fix**: Always run with `sudo`

### "Not privileged" Error

```
[-] ERROR: Insufficient privileges
    System Extension must be approved in System Preferences
```

**Cause**: User hasn't approved the extension in System Preferences.

**Fix**: Go to System Preferences → Privacy & Security → Allow

### "Too many clients" Error

```
[-] ERROR: Too many ES clients
    Another instance may be running
```

**Cause**: Multiple guardian-esd instances or other ES clients.

**Fix**:
```bash
# Find and kill existing instances
ps aux | grep guardian-esd
sudo kill <PID>

# Or restart the daemon
sudo launchctl stop io.quantumencoding.guardian-esd
sudo launchctl start io.quantumencoding.guardian-esd
```

### Blocks Not Appearing in Log

**Cause**: Operations targeting non-protected paths are allowed silently.

**Check**: Ensure the path you're testing is in `protectedPaths` and not in `whitelistedPaths`.

## Security Considerations

1. **The binary must be protected**: Add `/usr/local/bin/guardian-esd` to protected paths after installation

2. **LaunchDaemon plist must be protected**: The plist file is in /Library/LaunchDaemons which requires root to modify

3. **Kill switch file**: The `/tmp/.guardian_esd_disable` kill switch is intentional for emergencies but could be abused. In production, consider:
   - Moving it to a protected location
   - Requiring a specific file content/hash
   - Using a signal-based disable instead

4. **Trusted processes**: Be careful what you add to `trustedProcesses` - these bypass ALL protection

## Combined Deployment with libmacwarden

For maximum protection, run both:

1. **guardian-esd**: Kernel-level protection for all processes
2. **libmacwarden**: Additional DYLD-level protection for non-SIP binaries

This provides defense in depth - if one layer is bypassed, the other still protects.

```bash
# Terminal 1: Guardian ESD (kernel level)
sudo /usr/local/bin/guardian-esd

# Terminal 2: Run commands with libmacwarden (DYLD level)
DYLD_INSERT_LIBRARIES=/usr/local/lib/libmacwarden.dylib your-command
```

## License

Guardian ESD - Endpoint Security Daemon
Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
Dual License - MIT (Non-Commercial) / Commercial License
