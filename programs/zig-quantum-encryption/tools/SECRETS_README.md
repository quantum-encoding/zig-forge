# secrets

A cross-platform encrypted secret manager for shell environments. Store API keys, tokens, and credentials in an AES-256-GCM encrypted vault instead of plaintext dotfiles.

**Why?** If you export secrets in `.zshrc` and an untrusted tool, AI model, or code agent reads the file, every key is exposed. `secrets` replaces plaintext exports with a single eval line that decrypts at shell startup.

```bash
# Before (plaintext in .zshrc):
export ANTHROPIC_API_KEY="sk-ant-api03-..."
export STRIPE_SECRET_KEY="sk_live_..."
export OPENAI_API_KEY="sk-proj-..."

# After:
eval $(secrets env 2>/dev/null)
```

AI reads your `.zshrc` and sees one line. No keys. No tokens. Nothing.

## Install

### From source (requires Zig 0.16+)

```bash
cd zig-quantum-encryption
zig build secrets -Doptimize=ReleaseSafe
cp zig-out/bin/secrets ~/.local/bin/
```

### Pre-built binaries

Download from [Releases](https://github.com/quantum-encoding/quantum-zig-forge/releases) for:
- macOS ARM64 (Apple Silicon)
- macOS x86_64 (Intel)
- Linux x86_64
- Linux ARM64

Single static binary, ~460 KB, zero runtime dependencies.

## Quick Start

```bash
# Store secrets
secrets set ANTHROPIC_API_KEY "sk-ant-api03-..."
secrets set OPENAI_API_KEY "sk-proj-..."
secrets set STRIPE_SECRET_KEY "sk_live_..."

# Add to your shell config
echo 'eval $(secrets env 2>/dev/null)' >> ~/.zshrc

# Done. New shells load secrets from the encrypted vault.
```

## Usage

```
secrets set KEY [VALUE]   Store a secret (prompts if no value given)
secrets get KEY           Retrieve a secret (stdout, no trailing newline)
secrets delete KEY        Remove a secret
secrets list              List all stored key names
secrets env               Output as shell exports (for eval)
secrets env --json        Output as JSON object
secrets import            Import KEY=VALUE lines from stdin
secrets export            Export all as KEY=VALUE (for backup/migration)
```

### Store a secret

```bash
secrets set API_KEY "sk-..."       # value as argument
secrets set API_KEY                 # prompts (hidden input)
echo "sk-..." | secrets set API_KEY # pipe from stdin
```

### Retrieve

```bash
secrets get API_KEY                  # prints value to stdout
curl -H "Authorization: Bearer $(secrets get API_KEY)" ...
```

### Bulk import from existing .zshrc

```bash
grep "^export" ~/.zshrc | secrets import
```

Then remove the plaintext exports and add:

```bash
eval $(secrets env 2>/dev/null)
```

### JSON output

```bash
secrets env --json
```

```json
{
  "ANTHROPIC_API_KEY": "sk-ant-...",
  "STRIPE_SECRET_KEY": "sk_live_..."
}
```

## How It Works

### Vault format

```
[4 bytes]  Magic:     "QVLT"
[1 byte]   Version:   0x01
[16 bytes] PBKDF2 salt (random per save)
[12 bytes] AES-GCM nonce (random per save)
[16 bytes] AES-GCM authentication tag
[N bytes]  Ciphertext
```

The plaintext inside is a compact binary format:

```
Repeated:
  [2 bytes BE] key length
  [N bytes]    key
  [4 bytes BE] value length
  [N bytes]    value
Terminated by [0x00 0x00]
```

### Cryptography

| Component | Algorithm | Parameters |
|-----------|-----------|------------|
| Encryption | AES-256-GCM | 256-bit key, 96-bit nonce, authenticated |
| Key derivation | PBKDF2-HMAC-SHA256 | 600,000 iterations (OWASP 2023) |
| Salt | Random | 128-bit, fresh per save |
| Nonce | Random | 96-bit, fresh per save |

- **Authenticated encryption**: AES-GCM detects any tampering. A modified vault file fails decryption immediately rather than producing garbage.
- **Fresh randomness per save**: Every `secrets set` re-encrypts the entire vault with a new random salt and nonce. Even storing the same data twice produces completely different ciphertext.
- **Memory zeroing**: Plaintext and derived keys are zeroed after use.
- **No partial decryption**: Wrong passphrase = GCM auth failure. No timing side-channel on passphrase correctness.

### Vault location

```
~/.config/secrets/vault.qvlt
```

Directory: `700`. File: `600`. Override with `SECRETS_DIR`.

## Passphrase Management

The vault passphrase is required for every operation. Three ways to provide it:

### 1. Environment variable (CI, scripts, shell init)

```bash
SECRETS_PASSPHRASE="your-passphrase" secrets env
```

### 2. Interactive prompt (default)

```bash
$ secrets list
Vault passphrase: ****
```

Input is hidden (echo disabled).

### 3. macOS Keychain auto-unlock

Store the vault passphrase in macOS Keychain so shells auto-unlock without prompting:

```bash
# Store passphrase in Keychain (one-time setup)
security add-generic-password -s "secrets-vault-passphrase" -a "$(whoami)" -w "your-passphrase" -U

# In .zshrc — reads passphrase from Keychain, feeds to secrets
eval $(SECRETS_PASSPHRASE="$(security find-generic-password -s secrets-vault-passphrase -w 2>/dev/null)" secrets env 2>/dev/null)
```

This gives you the convenience of auto-loading secrets at shell startup with the vault passphrase protected by OS-level Keychain encryption (Touch ID / login password).

On Linux, use a keyring agent or set `SECRETS_PASSPHRASE` in a session-scoped mechanism.

## Security Model

### What's protected

| Threat | Protection |
|--------|-----------|
| AI reads `.zshrc` | Sees `eval $(secrets env)`, no keys |
| AI reads vault file | AES-256-GCM ciphertext, useless without passphrase |
| Wrong passphrase | GCM auth fails immediately, no partial info leaked |
| Vault tampered | GCM authentication tag detects modification |
| Brute force | PBKDF2 600k rounds, ~300ms per attempt |

### What's NOT protected

- If an attacker has shell access **and** `SECRETS_PASSPHRASE` is set in the environment, they can run `secrets export`. This is inherent to any env-based secret loading.
- The passphrase is in memory during vault operations. Use a strong, unique passphrase.
- No hardware key support (YubiKey, TPM). The vault is pure software encryption.

### Comparison

| Tool | Encryption | Dependencies | Binary size | Cross-platform |
|------|-----------|-------------|-------------|---------------|
| **secrets** | AES-256-GCM + PBKDF2 | None | 460 KB | macOS, Linux |
| pass | GPG | gpg, bash, git, tree | ~50 MB total | macOS, Linux |
| 1Password CLI | AES-256-GCM | Proprietary runtime | ~30 MB | macOS, Linux, Windows |
| Doppler | Cloud-based | curl, auth tokens | ~15 MB | macOS, Linux, Windows |
| dotenvx | AES-256-GCM | Node.js | ~80 MB total | macOS, Linux, Windows |
| Plaintext .env | None | None | 0 | Everywhere |

## Building from Source

Requires [Zig 0.16+](https://ziglang.org/download/).

```bash
git clone https://github.com/quantum-encoding/quantum-zig-forge
cd quantum-zig-forge/programs/zig-quantum-encryption

# Native build
zig build secrets -Doptimize=ReleaseSafe
./zig-out/bin/secrets --version

# Cross-compile (macOS + Linux)
zig build secrets-cross -Doptimize=ReleaseSafe
ls zig-out/bin/secrets-*
```

The binary is fully static — copy it anywhere and it runs.

## Environment Variables

| Variable | Description |
|----------|------------|
| `SECRETS_PASSPHRASE` | Vault passphrase (non-interactive use) |
| `SECRETS_DIR` | Override vault directory (default: `~/.config/secrets`) |

## License

MIT

## Credits

Part of the [Quantum Encoding](https://quantumencoding.io) toolchain. Built with Zig's `std.crypto` — AES-256-GCM and PBKDF2 implementations from the Zig standard library.
