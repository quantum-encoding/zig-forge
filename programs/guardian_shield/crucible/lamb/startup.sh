#!/bin/bash
# Guardian Shield V8.2 - Crucible Lamb Startup Script
echo "=========================================="
echo "Guardian Shield V8.2 - Crucible Lamb"
echo "=========================================="
echo ""
echo "Running normal operations battery test..."
echo ""

# Run the battery test - if it fails, warn but don't exit
# (so we can debug in the container)
if /usr/local/bin/test-normal-ops.sh; then
    echo ""
    echo "Battery test PASSED - Guardian Shield is safe"
    echo ""
else
    echo ""
    echo "WARNING: Battery test FAILED!"
    echo "Some normal operations are being blocked."
    echo "Do NOT deploy this version to production!"
    echo ""
fi

# Start SSH daemon
exec /usr/sbin/sshd -D
