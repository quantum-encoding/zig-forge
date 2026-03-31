#!/bin/bash
# Fix audit rate limit issue
# 1.85M+ lost events due to rate_limit=100 being too low

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

AUDIT_CONF="/etc/audit/auditd.conf"
BACKUP="${AUDIT_CONF}.backup.$(date +%Y%m%d-%H%M%S)"

echo "═══════════════════════════════════════════════════════════"
echo "  FIX: Audit Rate Limit Configuration"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Show current status
echo "Current audit status:"
auditctl -s | grep -E "rate_limit|backlog_limit|lost"
echo ""

# Backup current config
echo "Creating backup: $BACKUP"
cp "$AUDIT_CONF" "$BACKUP"

# Check if rate_limit already exists in config
if grep -q "^rate_limit" "$AUDIT_CONF"; then
    echo "rate_limit already configured, updating..."
    sed -i 's/^rate_limit.*/rate_limit = 400/' "$AUDIT_CONF"
else
    echo "Adding rate_limit configuration..."
    echo "" >> "$AUDIT_CONF"
    echo "# Increased from default 100 to handle high event volume" >> "$AUDIT_CONF"
    echo "rate_limit = 400" >> "$AUDIT_CONF"
fi

if grep -q "^backlog_limit" "$AUDIT_CONF"; then
    echo "backlog_limit already configured, updating..."
    sed -i 's/^backlog_limit.*/backlog_limit = 16384/' "$AUDIT_CONF"
else
    echo "Adding backlog_limit configuration..."
    echo "# Increased from default 8192 to reduce lost events" >> "$AUDIT_CONF"
    echo "backlog_limit = 16384" >> "$AUDIT_CONF"
fi

echo ""
echo "Updated configuration:"
grep -E "^rate_limit|^backlog_limit" "$AUDIT_CONF"
echo ""

# Restart auditd using service command (bypasses systemd restrictions)
echo "Restarting audit daemon..."
if service auditd restart 2>/dev/null; then
    echo "✓ Audit daemon restarted via service command"
elif systemctl restart auditd 2>/dev/null; then
    echo "✓ Audit daemon restarted via systemctl"
else
    echo "⚠️  Could not restart auditd - you may need to reboot"
    echo "   Or manually send SIGHUP to auditd process:"
    echo "   sudo kill -HUP \$(pidof auditd)"
fi

echo ""
echo "New audit status:"
sleep 2
auditctl -s | grep -E "rate_limit|backlog_limit|lost"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Configuration Complete"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Monitor audit status with: sudo auditctl -s"
echo "Restore backup with: sudo cp $BACKUP $AUDIT_CONF"
