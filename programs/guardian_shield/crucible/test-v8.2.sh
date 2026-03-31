#!/bin/bash
# Guardian Shield V8.2 - One-Click Test Script
# Purpose: Build and test libwarden.so V8.2 in Docker crucible
#
# Usage: ./test-v8.2.sh [--quick|--full|--clean]
#
# Options:
#   --quick   Build and run battery test only (default)
#   --full    Build both containers and run attack simulation
#   --clean   Remove all crucible containers and images

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDIAN_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Guardian Shield V8.2 - Crucible Test Environment        ║"
echo "║                                                              ║"
echo "║  \"A security tool that breaks the system is worse than      ║"
echo "║   no security at all.\"                                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Parse arguments
MODE="quick"
if [[ "$1" == "--full" ]]; then
    MODE="full"
elif [[ "$1" == "--clean" ]]; then
    MODE="clean"
elif [[ "$1" == "--quick" ]]; then
    MODE="quick"
elif [[ -n "$1" ]]; then
    echo -e "${RED}Unknown option: $1${NC}"
    echo "Usage: $0 [--quick|--full|--clean]"
    exit 1
fi

# Clean mode
if [[ "$MODE" == "clean" ]]; then
    echo -e "${YELLOW}Cleaning up crucible containers and images...${NC}"
    docker stop crucible-lamb crucible-wolf 2>/dev/null || true
    docker rm crucible-lamb crucible-wolf 2>/dev/null || true
    docker rmi crucible-lamb:v8.2 crucible-wolf:v8.2 2>/dev/null || true
    docker network rm crucible-arena 2>/dev/null || true
    docker volume rm crucible-lamb-logs crucible-wolf-results crucible-wolf-logs 2>/dev/null || true
    echo -e "${GREEN}Cleanup complete!${NC}"
    exit 0
fi

# Check Docker is running
echo -e "${BLUE}[1/5]${NC} Checking Docker..."
if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Docker is not running!${NC}"
    echo "Starting Docker service..."
    sudo systemctl start docker
    sleep 3
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}Failed to start Docker. Please start it manually:${NC}"
        echo "  sudo systemctl start docker"
        exit 1
    fi
fi
echo -e "${GREEN}Docker is running${NC}"

# Build Guardian Shield V8.2
echo ""
echo -e "${BLUE}[2/5]${NC} Building Guardian Shield V8.2..."
cd "$GUARDIAN_DIR"

if WARDEN_DISABLE=1 /usr/local/zig/zig build 2>&1; then
    echo -e "${GREEN}Build successful${NC}"
else
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

# Verify artifacts exist
if [[ ! -f "$GUARDIAN_DIR/zig-out/lib/libwarden.so" ]]; then
    echo -e "${RED}libwarden.so not found after build!${NC}"
    exit 1
fi

if [[ ! -f "$GUARDIAN_DIR/zig-out/bin/wardenctl" ]]; then
    echo -e "${YELLOW}Warning: wardenctl not found (optional)${NC}"
fi

echo -e "${GREEN}Artifacts ready:${NC}"
ls -lh "$GUARDIAN_DIR/zig-out/lib/libwarden.so"

# Build Docker image
echo ""
echo -e "${BLUE}[3/5]${NC} Building Docker image crucible-lamb:v8.2..."
cd "$GUARDIAN_DIR"

if docker build -f crucible/Dockerfile.lamb -t crucible-lamb:v8.2 . 2>&1 | tail -20; then
    echo -e "${GREEN}Docker image built${NC}"
else
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
fi

# Run the test
echo ""
echo -e "${BLUE}[4/5]${NC} Running normal operations battery test..."
echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"

# Run container with battery test
docker run --rm \
    --name crucible-lamb-test \
    --cap-add SYS_PTRACE \
    --security-opt seccomp:unconfined \
    crucible-lamb:v8.2 \
    /usr/local/bin/test-normal-ops.sh

TEST_EXIT=$?

echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Results
echo -e "${BLUE}[5/5]${NC} Test Results"
echo ""

if [[ $TEST_EXIT -eq 0 ]]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   ✓ ALL TESTS PASSED - V8.2 IS SAFE FOR DEPLOYMENT          ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "To deploy V8.2 to production:"
    echo ""
    echo -e "  ${CYAN}# Backup current version${NC}"
    echo "  sudo cp /usr/local/lib/security/libwarden.so /usr/local/lib/security/backup/libwarden.so.\$(date +%Y%m%d_%H%M%S)"
    echo ""
    echo -e "  ${CYAN}# Deploy V8.2${NC}"
    echo "  sudo cp $GUARDIAN_DIR/zig-out/lib/libwarden.so /usr/local/lib/security/libwarden.so"
    echo ""
    echo -e "  ${CYAN}# Verify (open new terminal)${NC}"
    echo "  WARDEN_VERBOSE=1 ls /tmp"
    echo ""
else
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║   ✗ TESTS FAILED - DO NOT DEPLOY THIS VERSION!              ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║   Some normal system operations are being blocked.          ║${NC}"
    echo -e "${RED}║   Fix the issues before deploying to production.            ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

# Full mode - run attack simulation
if [[ "$MODE" == "full" ]]; then
    echo ""
    echo -e "${BLUE}Running full attack simulation (Wolf vs Lamb)...${NC}"
    cd "$SCRIPT_DIR"
    docker-compose up -d
    echo ""
    echo "Containers started. To run attacks:"
    echo "  docker exec -it crucible-wolf /bin/bash"
    echo ""
    echo "To view defender logs:"
    echo "  docker logs -f crucible-lamb"
    echo ""
    echo "To stop:"
    echo "  docker-compose down -v"
fi
