# Guardian Shield Configuration

## Quick Start

1. Copy the example configuration:
   ```bash
   sudo cp warden-config.example.json /etc/warden/warden-config.json
   ```

2. Edit the configuration to match your system:
   ```bash
   sudo nano /etc/warden/warden-config.json
   ```

## Configuration Structure

### Global Settings

```json
"global": {
  "enabled": true,              // Master enable/disable switch
  "log_level": "normal",        // Logging verbosity: "silent", "normal", "verbose"
  "log_target": "stderr",       // Where to log: "stderr", "syslog", "file"
  "block_emoji": "🛡️",          // Emoji for block messages
  "warning_emoji": "⚠️",        // Emoji for warnings
  "allow_emoji": "✓"            // Emoji for allowed operations
}
```

### Protected Paths

Define which paths should be protected and what operations to block:

```json
"protected_paths": [
  {
    "path": "/etc/",
    "description": "System configuration files",
    "block_operations": ["unlink", "unlinkat", "rmdir", "open_write", "rename"]
  }
]
```

**Supported Operations:**
- `unlink` - Deleting files
- `unlinkat` - Deleting files (at variant)
- `rmdir` - Removing directories
- `open_write` - Opening files for writing
- `rename` - Renaming/moving files

### Whitelisted Paths

Paths that bypass all protection:

```json
"whitelisted_paths": [
  {
    "path": "/tmp/",
    "description": "System temporary directory"
  }
]
```

**Important:** Whitelisted paths take precedence over protected paths.

### Advanced Settings

```json
"advanced": {
  "cache_path_checks": true,         // Cache protection decisions for performance
  "max_cache_size": 1000,            // Maximum cache entries
  "allow_symlink_bypass": false,     // Whether symlinks can bypass protection
  "canonicalize_paths": true,        // Resolve paths to canonical form
  "notify_auditd": true,             // Send events to auditd
  "auditd_key": "libwarden_block",   // Audit log key
  "allow_env_override": false        // Allow LIBWARDEN_OVERRIDE=1 to disable
}
```

## Common Configurations

### Development Machine

- Protect system directories
- Allow `/home/user/workspace/` for development
- Enable verbose logging

### Production Server

- Strict protection on all system paths
- Minimal whitelist
- Disable env override
- Enable auditd notifications

### Desktop/Laptop

- Protect `/etc/`, `/boot/`, `/sys/`
- Whitelist common app directories
- Moderate logging

## Customization Examples

### Protect Custom Application Directory

```json
{
  "path": "/opt/myapp/",
  "description": "My critical application",
  "block_operations": ["unlink", "open_write", "rename"]
}
```

### Whitelist Development Directory

```json
{
  "path": "/home/developer/projects/",
  "description": "Development workspace"
}
```

### Block Only Deletions

```json
{
  "path": "/data/",
  "description": "Data directory - prevent deletion only",
  "block_operations": ["unlink", "unlinkat", "rmdir"]
}
```

## Troubleshooting

### Application Can't Write to Allowed Directory

1. Check if path is whitelisted
2. Verify path matching (must be prefix match)
3. Check file permissions separately
4. Enable verbose logging to debug

### Protection Not Working

1. Verify `LD_PRELOAD` is set: `echo $LD_PRELOAD`
2. Check config is loaded: Look for startup message
3. Ensure config file exists: `/etc/warden/warden-config.json`
4. Verify global.enabled is true

### Emergency Override

If you need to temporarily disable protection:

```bash
# WARNING: Use with caution!
export LIBWARDEN_OVERRIDE=1
```

This only works if `allow_env_override` is true in config.

## Security Considerations

1. **Never disable protection on `/etc/`** - Critical system configs
2. **Be careful with `/home/`** - Consider per-user subdirectories
3. **Review whitelists regularly** - Remove unused entries
4. **Test changes in dev first** - Before applying to production
5. **Keep audit logs** - Monitor for suspicious patterns

## Path Matching Rules

- Paths are matched by **prefix**
- `/etc/` matches `/etc/passwd`, `/etc/ssh/sshd_config`, etc.
- More specific paths take precedence
- Whitelist always wins over protection
