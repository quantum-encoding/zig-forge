# Zig Secret Scanner (zss)

High-performance secret detection tool for preventing credential leaks. Built in Zig for maximum speed and minimal resource usage.

## Features

- **50+ Detection Patterns**: AWS, GitHub, GitLab, Slack, Stripe, Google Cloud, OpenAI/Anthropic, databases, private keys, JWT, and more
- **Entropy-Based Detection**: Uses Shannon entropy to detect high-randomness strings that might be secrets
- **Git Hook Integration**: Pre-push hook to prevent secrets from being committed
- **Multiple Output Formats**: Text (with colors), JSON, SARIF (for CI/CD integration)
- **Configurable Severity**: Filter by critical, high, medium, or low severity
- **Secret Redaction**: Masks secrets in output for safe display
- **Smart Exclusions**: Automatically skips binary files, images, build directories

## Building

```bash
zig build
```

The scanner binary will be at `./zig-out/bin/zss`.

## Usage

### Basic Scanning

```bash
# Scan current directory
zss scan .

# Scan specific paths
zss scan src/ config/ .env

# Scan with high severity only
zss scan -s high .

# JSON output for CI/CD
zss scan -f json .

# SARIF output for GitHub/GitLab
zss scan -f sarif . > results.sarif
```

### Git Hook

```bash
# Install pre-push hook
zss hook install

# Remove hook
zss hook uninstall
```

The pre-push hook will scan your repository before each push and block if secrets are detected.

### View Patterns

```bash
# List all detection patterns
zss patterns
```

## Command Line Options

```
USAGE:
    zss <command> [options] [path...]

COMMANDS:
    scan [path]         Scan directory or file for secrets (default: .)
    hook install        Install git pre-push hook
    hook uninstall      Remove git pre-push hook
    patterns            List all detection patterns
    version             Show version information
    help                Show this help message

OPTIONS:
    -s, --severity <level>   Minimum severity to report
                             (critical, high, medium, low)
    -f, --format <fmt>       Output format (text, json, sarif)
    -o, --output <file>      Write output to file
    -q, --quiet              Suppress output, exit code only
    -v, --verbose            Show detailed output
    --no-color               Disable colored output
    --no-redact              Show full secrets (dangerous!)
```

## Exit Codes

- `0`: No secrets found
- `1`: Secrets detected
- `2`: Error occurred

## Detected Secret Types

### API Keys & Tokens
- AWS Access Keys and Secret Keys
- GitHub Personal Access Tokens (ghp_, gho_, ghs_, ghr_, github_pat_)
- GitLab Personal Access Tokens (glpat-)
- Slack Tokens (xoxb-, xoxp-, xapp-)
- Stripe API Keys (sk_live_, pk_live_, rk_live_)
- Google API Keys (AIza...)
- OpenAI API Keys (sk-...)
- Anthropic/Claude API Keys (sk-ant-...)
- SendGrid API Keys (SG.)
- Twilio Auth Tokens

### Database Credentials
- PostgreSQL connection strings
- MySQL connection strings
- MongoDB connection strings (including SRV)
- Redis connection strings

### Private Keys
- RSA Private Keys
- OpenSSH Private Keys
- EC Private Keys
- DSA Private Keys
- PGP Private Key Blocks
- PKCS#8 Encrypted Private Keys

### Other
- JWT Tokens
- NPM/PyPI Tokens
- Discord Bot Tokens and Webhooks
- Azure Storage Keys and Connection Strings
- Generic API keys, secrets, tokens, and passwords

## CI/CD Integration

### GitHub Actions

```yaml
- name: Check for secrets
  run: |
    zss scan -f sarif -o results.sarif .

- name: Upload SARIF
  uses: github/codeql-action/upload-sarif@v2
  with:
    sarif_file: results.sarif
```

### GitLab CI

```yaml
secret-scan:
  script:
    - zss scan -f json . > secrets.json
  artifacts:
    reports:
      sast: secrets.json
```

## Example Output

```
[HIGH] GitHub Personal Access Token
  src/config.js:15:21
  Secret: ghp_**********************************9012

[CRITICAL] AWS Secret Access Key
  .env:3:22
  Secret: wJal****************xyz9

Found 2 secret(s): 1 critical 1 high
Scanned 42 files (128456 bytes)
```

## Running Tests

```bash
zig build test
```

## Performance

The scanner is optimized for speed:
- Direct file reading without external dependencies
- Efficient pattern matching using Zig's comptime features
- Minimal memory allocations
- Parallel-ready architecture

## License

MIT
