#!/bin/bash
# run_v6_docker_test.sh - Complete V6 Docker test orchestration
# Runs setup as root, then tests as testuser

docker run --rm \
  -v /home/founder/github_public/guardian-shield:/forge:ro \
  warden-test:v4 \
  bash -c '
# Run as root to set up environment
echo "[Root Setup] Creating /etc/warden/ and deploying config..."
mkdir -p /etc/warden
cp /forge/config/warden-config-docker-test.json /etc/warden/warden-config.json
echo "[Root Setup] ✓ Config deployed"

echo "[Root Setup] Creating test project directories..."
mkdir -p /home/testuser/zig_forge/{src,.git,zig-out}
echo "const std = @import(\"std\");" > /home/testuser/zig_forge/src/main.zig
echo "pub fn build(b: *std.Build) void {}" > /home/testuser/zig_forge/build.zig
echo "[core]" > /home/testuser/zig_forge/.git/config

mkdir -p /home/testuser/rust_programs/{src,.git}
echo "fn main() {}" > /home/testuser/rust_programs/src/main.rs

chown -R testuser:testuser /home/testuser/zig_forge /home/testuser/rust_programs
echo "[Root Setup] ✓ Test directories created and owned by testuser"
echo ""

# Switch to testuser and run tests
echo "[Switching to testuser for V6 Citadel tests...]"
echo ""
su - testuser -c "bash /forge/test_v6_citadel.sh"
'
