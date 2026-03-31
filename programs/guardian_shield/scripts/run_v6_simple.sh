#!/bin/bash
# run_v6_simple.sh - Simplified V6 Docker test (no /etc/warden needed)

docker run --rm \
  -v /home/founder/github_public/guardian-shield:/forge:ro \
  warden-test:v4 \
  bash -c '
# Create test directories as testuser
mkdir -p /home/testuser/zig_forge/{src,.git,zig-out}
echo "const std = @import(\"std\");" > /home/testuser/zig_forge/src/main.zig
echo "pub fn build(b: *std.Build) void {}" > /home/testuser/zig_forge/build.zig
echo "[core]" > /home/testuser/zig_forge/.git/config

echo "Test environment ready. Running V6 Citadel tests..."
echo ""

bash /forge/test_v6_citadel.sh
'
