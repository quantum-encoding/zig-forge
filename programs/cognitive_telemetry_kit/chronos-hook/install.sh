#!/bin/bash
# Install chronos-hook globally and link to all git repositories
set -e

echo "🔨 Building chronos-hook..."
zig build

echo "📦 Installing chronos-hook to /usr/local/bin..."
sudo cp zig-out/bin/chronos-hook /usr/local/bin/
sudo chmod +x /usr/local/bin/chronos-hook

echo "✅ chronos-hook installed successfully!"
echo ""
echo "To install hooks in all your git repositories, run:"
echo "  chronos-hook-install-all"
echo ""
echo "Or manually create symlinks in individual projects:"
echo "  mkdir -p .claude/hooks"
echo "  ln -sf /usr/local/bin/chronos-hook .claude/hooks/tool-result-hook.sh"
