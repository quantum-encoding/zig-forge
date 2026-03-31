#!/bin/bash
# es-warden Signing Script
# Signs the Endpoint Security binary with proper entitlements
#
# Prerequisites:
#   - Apple Developer Program membership
#   - Developer ID Application certificate in Keychain
#   - ES entitlement approved by Apple (applied via developer portal)
#
# Usage:
#   ./sign-es-warden.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/zig-out/bin/es-warden"
ENTITLEMENTS="$SCRIPT_DIR/es_warden.entitlements"

echo -e "${CYAN}=== es-warden Signing Script ===${NC}"
echo ""

# Check binary exists
if [ ! -f "$BINARY" ]; then
    echo -e "${RED}Error: Binary not found at $BINARY${NC}"
    echo -e "${YELLOW}Run 'zig build' first${NC}"
    exit 1
fi

# Check entitlements exist
if [ ! -f "$ENTITLEMENTS" ]; then
    echo -e "${RED}Error: Entitlements file not found at $ENTITLEMENTS${NC}"
    exit 1
fi

# Find Developer ID Application signing identity
echo -e "${CYAN}Looking for signing identities...${NC}"
echo ""

# Show all identities
security find-identity -v -p codesigning | grep -E "Developer ID|Apple Development" || true

echo ""

# Try Developer ID Application first (for distribution)
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ -z "$SIGNING_IDENTITY" ]; then
    # Fall back to Apple Development (for local testing)
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi

if [ -z "$SIGNING_IDENTITY" ]; then
    echo -e "${RED}Error: No signing identity found.${NC}"
    echo -e "${YELLOW}Please ensure you have:${NC}"
    echo -e "  1. Apple Developer Program membership"
    echo -e "  2. Developer ID Application certificate installed"
    echo -e "  3. Or Apple Development certificate for local testing"
    exit 1
fi

echo -e "${GREEN}Using identity: ${CYAN}$SIGNING_IDENTITY${NC}"
echo ""

# Sign the binary
echo -e "${CYAN}Signing binary...${NC}"
codesign --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --force \
    --verbose \
    "$BINARY"

echo ""

# Verify signature
echo -e "${CYAN}Verifying signature...${NC}"
codesign --verify --verbose=4 "$BINARY"

echo ""

# Show entitlements
echo -e "${CYAN}Entitlements:${NC}"
codesign --display --entitlements - "$BINARY" 2>/dev/null || true

echo ""
echo -e "${GREEN}=== Signing complete ===${NC}"
echo ""
echo -e "${YELLOW}To run es-warden:${NC}"
echo -e "  1. Grant Full Disk Access in System Settings → Privacy & Security"
echo -e "  2. Run: ${CYAN}sudo $BINARY${NC}"
echo ""
echo -e "${YELLOW}Note: The ES entitlement must be approved by Apple.${NC}"
echo -e "Without approval, you'll get 'not entitled' error."
echo ""
