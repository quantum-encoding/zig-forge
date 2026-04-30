# Guardian Shield Crucible

**Doctrine**: A defense is not battle-proven until it has faced a true adversary.

**V8.2 Cardinal Rule**: A security tool that breaks the system is worse than no security.

## Architecture

The Crucible is a dual-container adversarial testing environment for Guardian Shield V8.2:

### The Lamb (Defender)
- **Purpose**: Protected environment with libwarden.so active
- **Base**: Arch Linux with development tools (git, gcc, python, make)
- **Protection**: Full Guardian Shield V8.2 (17 syscall interceptors)
- **Network**: `crucible-arena` (172.28.0.0/16)
- **V8.2 NEW**: Runs comprehensive "normal operations" battery test on startup

### The Wolf (Attacker)
- **Purpose**: Attempt to bypass Guardian Shield protections
- **Base**: Arch Linux with security tools
- **Arsenal**: Custom bypass scripts, privilege escalation tools
- **Network**: `crucible-arena` (can only see Lamb)

### The Arena (Network)
- **Type**: Isolated Docker bridge network
- **Subnet**: 172.28.0.0/16
- **Isolation**: Lamb and Wolf can only see each other

---

## Quick Start

### Option A: Automated (Recommended)

```bash
cd /path/to/guardian_shield/crucible

# Run the full test campaign
./run-crucible.sh

# Quick smoke test
./run-crucible.sh --quick

# Clean up everything
./run-crucible.sh --clean
```

### Option B: Manual

#### 1. Build the Containers

```bash
cd /path/to/guardian_shield/crucible

# Build the Lamb (defender with libwarden)
docker build -f Dockerfile.lamb -t crucible-lamb:v8.0 ..

# Build the Wolf (attacker)
docker build -f Dockerfile.wolf -t crucible-wolf:v8.0 .
```

#### 2. Launch the Arena

```bash
docker-compose up -d
```

Or start containers manually:

```bash
# Create network first
docker network create --subnet=172.28.0.0/16 crucible-arena

# Start the Lamb (defender)
docker run -d \
  --name crucible-lamb \
  --network crucible-arena \
  --ip 172.28.0.10 \
  -e LD_PRELOAD=/usr/local/lib/security/libwarden.so \
  crucible-lamb:v8.0

# Start the Wolf (attacker)
docker run -it \
  --name crucible-wolf \
  --network crucible-arena \
  --ip 172.28.0.20 \
  -e LAMB_HOST=lamb \
  crucible-wolf:v8.0
```

---

## Attack Campaigns

### Campaign 1: Path Hijacking (V8.0 Defense)

Test the new symlink/link/truncate/mkdir interceptors:

```bash
# Inside the Wolf:
docker exec -it crucible-wolf /bin/bash

# Attempt symlink attacks
./attacks/symlink-hijack.sh

# Attempt hardlink privilege escalation
./attacks/hardlink-escalate.sh

# Attempt truncate data destruction
./attacks/truncate-destroy.sh

# Attempt mkdir PATH injection
./attacks/mkdir-inject.sh
```

### Campaign 2: Protected Path Bypass

Attempt to access protected paths:

```bash
# Inside the Wolf:

# Try to delete files in /etc
ssh lamb "rm /etc/passwd"  # Should be blocked

# Try to write to /usr/bin
ssh lamb "echo 'malware' > /usr/bin/fake"  # Should be blocked

# Try symlink to protected binary
ssh lamb "ln -s /tmp/evil /usr/bin/python"  # Should be blocked
```

### Campaign 3: Process Restriction Bypass

Test process-specific restrictions:

```bash
# Inside the Wolf:

# Try /tmp execution attack
ssh lamb "echo '#!/bin/bash\nid' > /tmp/exploit.sh && chmod +x /tmp/exploit.sh && /tmp/exploit.sh"

# Try dotfile poisoning
ssh lamb "echo 'alias sudo=evil' >> /home/user/.bashrc"
```

### Campaign 4: TOCTOU Race Conditions

Test Time-of-Check to Time-of-Use attacks:

```bash
# Inside the Wolf:
./attacks/toctou-race.sh
```

---

## Validation Criteria

### Guardian Shield MUST Block:

| Attack Vector | Expected Result |
|---------------|-----------------|
| `rm /etc/passwd` | BLOCKED (EACCES) |
| `ln -s /tmp/evil /usr/bin/python` | BLOCKED |
| `echo '' > /etc/shadow` | BLOCKED |
| `truncate -s 0 /etc/hosts` | BLOCKED |
| `mkdir /usr/bin/evil` | BLOCKED |
| `/tmp/exploit.sh` execution | BLOCKED (for restricted processes) |

### Guardian Shield MUST Allow:

| Operation | Expected Result |
|-----------|-----------------|
| `rm /tmp/testfile` | ALLOWED |
| `touch /home/user/newfile` | ALLOWED |
| Git operations in `.git/` | ALLOWED |
| Build tool operations | ALLOWED (exempt processes) |

---

## Management Commands

### Monitor the Lamb

```bash
# View libwarden logs
docker logs -f crucible-lamb

# See blocked operations
docker exec crucible-lamb grep "BLOCKED" /var/log/warden.log

# Interactive shell
docker exec -it crucible-lamb /bin/bash
```

### Interactive Wolf Session

```bash
docker exec -it crucible-wolf /bin/bash
```

### View Attack Results

```bash
docker exec crucible-wolf cat /wolf/results/campaign-report.md
```

### Destroy the Arena

```bash
docker-compose down -v
docker rmi crucible-lamb crucible-wolf
docker network rm crucible-arena
```

---

## Rite of Fire Protocol

1. **The Forging**: Build Guardian Shield V8.0
2. **The Offering**: Deploy Lamb with full protection
3. **The Unleashing**: Attack from Wolf with all bypass techniques
4. **The Judgment**:
   - All attacks blocked → Guardian Shield is battle-proven
   - Any attack succeeds → Document vulnerability, return to forge
5. **The Cleansing**: Destroy all containers

---

## Security Notes

- The Crucible is **completely isolated** from the host
- Lamb and Wolf can **only** communicate with each other
- All containers are **disposable**
- Attack findings are documented in `/wolf/results`
- **Never** test attacks on production systems

---

## CI/CD Integration

Add to your pipeline:

```yaml
guardian-shield-crucible:
  stage: security-test
  script:
    - cd crucible
    - docker-compose up -d
    - docker exec crucible-wolf /wolf/scripts/full-campaign.sh
    - docker exec crucible-wolf cat /wolf/results/verdict.txt
    - docker-compose down -v
  artifacts:
    paths:
      - crucible/results/
```

---

**THE LAMB MUST ENDURE THE WOLF, OR PERISH IN THE FLAMES.**
