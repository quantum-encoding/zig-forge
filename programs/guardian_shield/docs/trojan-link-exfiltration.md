# 🚨 Incident Response Runbook: Trojan Link Exfiltration

## Overview

**Threat**: Cunning Exfiltration via Trojan Link
**Tactic**: Data smuggling through base64-encoded URL parameters
**MITRE ATT&CK**: T1567.002 (Exfiltration Over Web Service)

## Threat Model

A rogue agent or compromised process has read sensitive data (SSH keys, AWS credentials, tokens, etc.) and is attempting to exfiltrate it by encoding the data as a URL query parameter. The URL appears in logs as a "harmless" link.

**Example**:
```
https://www.google.com/search?q=LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFy...
```

The query parameter is actually a base64-encoded SSH private key.

---

## Alert Triggers

### 1. **Suspicious URL Length**
- **Trigger**: URL query parameter > 2048 characters
- **Severity**: CRITICAL
- **False Positive Rate**: Low (legitimate URLs rarely exceed this length)

### 2. **Base64 Pattern**
- **Trigger**: URL contains `?param=[Base64String]` where string > 200 chars
- **Severity**: HIGH
- **False Positive Rate**: Medium (some APIs use base64, but rarely this long)

### 3. **SSH Key Signature**
- **Trigger**: URL contains `-----BEGIN` or base64 of `-----BEGIN` (LS0tLS1CRUdJTiB)
- **Severity**: CRITICAL
- **False Positive Rate**: Very Low (confirmed threat)

### 4. **AWS Credentials**
- **Trigger**: URL contains `AKIA[0-9A-Z]{16}` or `aws_access_key_id`
- **Severity**: CRITICAL
- **False Positive Rate**: Very Low

### 5. **GitHub Token**
- **Trigger**: URL contains `ghp_` or `github_pat_`
- **Severity**: CRITICAL
- **False Positive Rate**: Very Low

---

## Incident Response Procedure

### Phase 1: IMMEDIATE TRIAGE (First 5 Minutes)

#### Step 1: Verify the Alert
```bash
# Query Loki for the specific log entry
logcli query '{job="systemd-journal"} |~ "https?://[^\s]+\?[^\s]{2048,}"' --limit=50 --since=10m

# Look for the suspicious URL in the output
```

#### Step 2: Extract the URL
```bash
# Copy the full URL from the log entry
# Example: https://example.com/search?q=BASE64_STRING_HERE
```

#### Step 3: Decode the Parameter
```bash
# Extract just the query parameter value
ENCODED_DATA="LS0tLS1CRUdJTiBP..."

# Decode it
echo "$ENCODED_DATA" | base64 -d

# Check if it's sensitive data
```

#### Step 4: Identify the Source Process
```bash
# Check which process wrote to the log
sudo journalctl -S "10 minutes ago" | grep -C 5 "example.com/search"

# Or check application-specific logs
tail -f /var/log/app/*.log | grep -E "https?://"
```

---

### Phase 2: CONTAINMENT (Next 10 Minutes)

#### If SSH Key is Compromised:

```bash
# 1. Identify affected user
ls -la /home/*/.ssh/id_rsa
ls -la /root/.ssh/id_rsa

# 2. Immediately revoke the key on all servers
# On each server:
ssh-keygen -R <compromised_host>
vim ~/.ssh/authorized_keys  # Remove the compromised public key

# 3. Generate new keys
ssh-keygen -t ed25519 -C "emergency-rotation-$(date +%Y%m%d)"

# 4. Distribute new public key
```

#### If AWS Credentials are Compromised:

```bash
# 1. Disable the access key IMMEDIATELY
aws iam update-access-key \
  --access-key-id AKIA... \
  --status Inactive \
  --user-name <username>

# 2. Audit recent API calls
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=AccessKeyId,AttributeValue=AKIA... \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --max-results 100

# 3. Check for unauthorized resources
aws ec2 describe-instances --filters "Name=tag:CreatedBy,Values=unauthorized"
aws s3 ls
aws iam list-users

# 4. Rotate credentials
aws iam create-access-key --user-name <username>
aws iam delete-access-key --access-key-id AKIA... --user-name <username>
```

#### If GitHub Token is Compromised:

```bash
# 1. Revoke immediately at https://github.com/settings/tokens
# Or via API:
curl -X DELETE \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/applications/$CLIENT_ID/token

# 2. Audit repository access
# Check GitHub audit log: https://github.com/organizations/<org>/settings/audit-log

# 3. Rotate all tokens
```

---

### Phase 3: INVESTIGATION (Next 30 Minutes)

#### Determine Attack Timeline

```bash
# 1. Find when the malicious process started
sudo ps aux | grep <process_name>
ps -ef --forest  # View process tree

# 2. Check recent file access
sudo lsof -p <PID>
sudo find /home -type f -mmin -60  # Files modified in last 60 min

# 3. Review command history
cat ~/.bash_history | tail -100
sudo journalctl -u <service> -S "1 hour ago"

# 4. Check network connections
sudo netstat -anp | grep <PID>
sudo tcpdump -i any -n host <suspicious_ip>
```

#### Forensic Data Collection

```bash
# Create forensic snapshot
CASE_ID="trojan-link-$(date +%Y%m%d-%H%M%S)"
mkdir -p /var/forensics/$CASE_ID

# Capture process info
ps aux > /var/forensics/$CASE_ID/processes.txt
sudo lsof > /var/forensics/$CASE_ID/open-files.txt

# Capture network state
sudo netstat -anp > /var/forensics/$CASE_ID/netstat.txt
sudo iptables -L -v -n > /var/forensics/$CASE_ID/iptables.txt

# Capture logs
sudo journalctl -S "2 hours ago" > /var/forensics/$CASE_ID/journal.log
cp /var/log/syslog /var/forensics/$CASE_ID/

# Memory dump (if available)
sudo gcore <PID>
mv core.<PID> /var/forensics/$CASE_ID/

# Preserve evidence
tar -czf /var/forensics/${CASE_ID}.tar.gz /var/forensics/$CASE_ID/
sha256sum /var/forensics/${CASE_ID}.tar.gz > /var/forensics/${CASE_ID}.sha256
```

---

### Phase 4: ERADICATION (Next 20 Minutes)

#### Terminate Malicious Process

```bash
# 1. Kill the process
sudo kill -9 <PID>

# 2. If it's a service
sudo systemctl stop <service>
sudo systemctl disable <service>

# 3. Remove malicious binaries/scripts
sudo find /tmp -type f -executable -mmin -120
sudo rm -f /path/to/malicious/file

# 4. Check for persistence mechanisms
crontab -l
sudo cat /etc/crontab
ls -la ~/.config/autostart/
```

#### System Cleanup

```bash
# 1. Clear suspicious logs (after forensic backup)
sudo rm -f /var/log/suspicious.log

# 2. Update Guardian Shield rules
# Add the malicious pattern to watchlist

# 3. Restart monitoring services
sudo systemctl restart vector
sudo systemctl restart zig-sentinel
```

---

### Phase 5: RECOVERY (Next Hour)

#### Credential Rotation Checklist

- [ ] SSH keys rotated on all servers
- [ ] AWS credentials rotated
- [ ] GitHub tokens regenerated
- [ ] Database passwords changed
- [ ] API keys revoked and reissued
- [ ] TLS/SSL certificates rotated (if compromised)

#### System Hardening

```bash
# 1. Update Guardian Shield to V7.2
cd /path/to/guardian-shield
git pull
zig build
sudo ./deploy.sh

# 2. Enable Emoji Guardian
sudo ./zig-out/bin/zig-sentinel --enable-emoji-scan --duration=3600 &

# 3. Tighten file permissions
sudo chmod 600 ~/.ssh/id_rsa
sudo chmod 600 ~/.aws/credentials
```

---

### Phase 6: POST-INCIDENT REVIEW (Next Day)

#### Metrics to Collect
- Time to detection (alert trigger → human awareness)
- Time to containment (awareness → credential revocation)
- Blast radius (how many systems were compromised)
- Data loss (what was exfiltrated)

#### Questions to Answer
1. How did the attacker gain initial access?
2. What vulnerability allowed file reads?
3. Why didn't existing controls prevent this?
4. What process bypassed zig-jail's network restrictions?

#### Improvements to Implement
- Stricter file permissions on sensitive files
- Enhanced zig-sentinel correlation rules
- Additional Grafana alerts
- More restrictive zig-jail policies

---

## Testing the Alert

### Safe Test (No Real Credentials)

```bash
# Generate a fake "SSH key" exfiltration
FAKE_KEY=$(head -c 2048 /dev/urandom | base64 | tr -d '\n')
echo "Visit: https://www.google.com/search?q=$FAKE_KEY" | logger -t test-trojan-link

# Check if Grafana alert fires
# Expected: Alert triggers within 1 minute
```

### Verify Alert Configuration

```bash
# Query Loki to see if the pattern matches
logcli query '{job="systemd-journal"} |~ "https?://[^\s]+\?[^\s]{2048,}"' --limit=10

# Expected output: Your test log entry should appear
```

---

## Prevention

### Proactive Measures
1. **Enable Emoji Guardian**: Detect data hidden in emoji steganography
2. **zig-sentinel V5**: Implement File I/O Correlation Monitor (upcoming)
3. **Restrict Network Access**: Use zig-jail to block outbound connections
4. **File Access Auditing**: Monitor reads of `/home/*/.ssh/`, `/root/.ssh/`, `~/.aws/`
5. **Encrypt Sensitive Files**: Use `gpg` or `age` for credentials

### Detection Layering
```
Layer 1: zig-jail (prevent network access)
Layer 2: zig-sentinel (syscall correlation)
Layer 3: Emoji Guardian (steganography in alerts)
Layer 4: Grafana Alerts (log-based detection)  ← WE ARE HERE
Layer 5: Network IDS (inspect egress traffic)
```

---

## Contact Information

**Security Team**: security@example.com
**On-Call Engineer**: +1-555-SECURITY
**Incident Commander**: [Name/Slack Handle]
**Executive Notification**: CTO/CISO

---

## Appendix: Common Base64 Signatures

| Type | Plaintext | Base64 |
|------|-----------|--------|
| SSH Private Key | `-----BEGIN OPENSSH PRIVATE KEY-----` | `LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K` |
| RSA Private Key | `-----BEGIN RSA PRIVATE KEY-----` | `LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo=` |
| AWS Access Key | `AKIA...` | (Not base64, plaintext pattern) |
| GitHub Token | `ghp_...` | (Not base64, plaintext pattern) |

---

**Document Version**: 1.0
**Last Updated**: 2025-10-08
**Classification**: INTERNAL - SECURITY SENSITIVE
