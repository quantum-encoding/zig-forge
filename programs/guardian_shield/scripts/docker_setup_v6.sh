#!/bin/bash
# docker_setup_v6.sh - Setup script for V6 Docker test environment
# Runs inside the Docker container to create protected directories

echo "[Docker Setup] Creating test project directories..."

# Create a mock zig_forge project with .git
mkdir -p /home/testuser/zig_forge/{src,.git}
echo "const std = @import(\"std\");" > /home/testuser/zig_forge/src/main.zig
echo "pub fn build(b: *std.Build) void {}" > /home/testuser/zig_forge/build.zig
echo "[core]" > /home/testuser/zig_forge/.git/config
mkdir -p /home/testuser/zig_forge/zig-out

# Create a mock rust_programs project
mkdir -p /home/testuser/rust_programs/{src,.git}
echo "fn main() {}" > /home/testuser/rust_programs/src/main.rs
echo "Cargo.toml" > /home/testuser/rust_programs/Cargo.toml

echo "[Docker Setup] ✓ Test directories created"
echo "[Docker Setup]   /home/testuser/zig_forge/"
echo "[Docker Setup]   /home/testuser/zig_forge/.git/"
echo "[Docker Setup]   /home/testuser/rust_programs/"

echo ""
echo "[Docker Setup] Copying V6 config to /etc/warden/..."
mkdir -p /etc/warden
cp /forge/config/warden-config-docker-test.json /etc/warden/warden-config.json
echo "[Docker Setup] ✓ Configuration deployed"

echo ""
echo "[Docker Setup] Environment ready. Starting V6 Citadel tests..."
echo ""
