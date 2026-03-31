# zig-port-scanner V2.0 - Sovereign Forge Edition

A high-performance, order-independent TCP port scanner written in Zig for the zig_forge AI safety security system.

## Version History

### V2.0.0 - Sovereign Forge Edition (Current)
**Critical Fixes:**
- ✅ **Order-Independent Argument Parsing**: Arguments can now be specified in any order
- ✅ **Memory Leak Fixed**: Proper `defer` placement ensures cleanup on all error paths
- ✅ **Comprehensive Error Handling**: Detailed error messages for invalid inputs
- ✅ **Input Validation**: Port ranges, invalid hosts, and malformed arguments are caught early

**Breaking Changes:**
- Arguments now require `=` syntax: `-p=80` instead of `-p 80`

### V1.0.0 - Initial Release (Deprecated)
- Basic functionality but flawed argument parsing
- Memory leaks on error paths
- Order-dependent argument processing

## Purpose

This port scanner is part of the zig_forge security monitoring infrastructure, designed to detect unauthorized network activity from AI coding agents. It provides fast, multi-threaded port scanning capabilities to identify open ports and potential data exfiltration attempts.

## Features

- **Multi-threaded scanning**: Concurrent port scanning with configurable thread count (up to 100 threads)
- **Flexible port ranges**: Scan single ports, ranges, or comma-separated lists
- **Non-blocking I/O**: Uses `poll()` for efficient connection testing
- **Service detection**: Identifies common services running on open ports
- **Timeout control**: Configurable connection timeout for faster scanning
- **Real-time feedback**: Optional verbose mode for live results

## Building

```bash
cd src/zig-port-scanner
zig build
```

The compiled binary will be in `zig-out/bin/zig-port-scanner`

## Usage

```bash
zig-port-scanner [OPTIONS] HOST

Options:
  -p=RANGE, --ports=RANGE    Port range (e.g., 1-1000, 80)
  -t=MS, --timeout=MS        Connection timeout in ms (default: 1000)
  -j=N, --threads=N          Number of threads (default: 10, max: 100)
  -v, --verbose              Show results as found
  -c, --closed               Show closed ports
  -h, --help                 Display help
  --version                  Show version
```

**Note**: Arguments are **order-independent**. You can specify the host before or after flags.

## Examples

### Scan common ports on localhost
```bash
zig-port-scanner -p=1-1000 localhost
```

### Order-independent arguments (V2 feature)
```bash
# Host first
zig-port-scanner 192.168.1.1 -p=22-443 -t=500

# Flags first
zig-port-scanner -p=22-443 -t=500 192.168.1.1

# Mixed order
zig-port-scanner -j=20 example.com -v -p=1-100
```

### Full port scan with verbose output
```bash
zig-port-scanner -p=1-65535 -j=50 -v example.com
```

### Monitor for unauthorized agent activity
```bash
zig-port-scanner -p=1-10000 -j=20 127.0.0.1
```

### Error handling examples
```bash
# Invalid port range
$ zig-port-scanner -p=100-50 localhost
❌ Invalid port range: start port (100) > end port (50)

# Invalid port
$ zig-port-scanner -p=99999 localhost
❌ Invalid port: '99999' (must be 1-65535)

# Unknown host
$ zig-port-scanner invalid.host
❌ Failed to resolve host 'invalid.host': UnknownHostName
```

## Integration with zig_forge

This port scanner is designed to work alongside other zig_forge security components:

- **zig-sentinel**: eBPF-based syscall monitoring
- **libwarden**: Process-aware filesystem protection
- **grok-warden-v2**: Dynamic security policy enforcement

When monitoring AI coding agents, this scanner can detect if an agent attempts to:
- Open unauthorized network connections
- Establish reverse shells
- Transfer data to external servers
- Set up listening services

## Security Monitoring Workflow

1. **Baseline**: Run an initial scan to establish normal port activity
2. **Monitor**: Periodically scan during agent execution
3. **Detect**: Compare results to baseline to identify anomalies
4. **Alert**: Flag unauthorized port openings for security review

## Architecture

Built for Zig 0.16 using modern POSIX APIs:
- Non-blocking sockets with `SOCK.NONBLOCK`
- Poll-based connection timeout handling
- Thread-safe result collection with mutex protection
- Signal handling for graceful interruption

## Port Status Types

- **open**: Port accepts connections
- **closed**: Port actively refuses connections
- **filtered**: Connection times out (firewall/no response)
- **unknown**: Error occurred during scan

## Service Detection

Identifies common services including:
- SSH (22), HTTP (80), HTTPS (443)
- MySQL (3306), PostgreSQL (5432), Redis (6379)
- RDP (3389), SMB (445), MongoDB (27017)
- And more...

## Performance

- Fast scanning with configurable thread count
- Typical scan of 1000 ports: < 10 seconds
- Full 65535 port scan: 1-2 minutes (50 threads)

## License

Part of the zig_forge AI safety security system.
