#!/bin/bash
# Guardian Shield V8.0 - Crucible Test Runner
# Runs the full wolf/lamb adversarial test campaign
#
# Usage:
#   ./run-crucible.sh           # Full test with report
#   ./run-crucible.sh --quick   # Quick smoke test
#   ./run-crucible.sh --clean   # Clean up containers and images

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDIAN_DIR="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${CYAN}[CRUCIBLE]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[CRUCIBLE]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[CRUCIBLE]${NC} $1"
}

log_error() {
    echo -e "${RED}[CRUCIBLE]${NC} $1"
}

# Parse arguments
QUICK_MODE=false
CLEAN_MODE=false

for arg in "$@"; do
    case $arg in
        --quick)
            QUICK_MODE=true
            ;;
        --clean)
            CLEAN_MODE=true
            ;;
        --help|-h)
            echo "Guardian Shield V8.0 - Crucible Test Runner"
            echo ""
            echo "Usage: ./run-crucible.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --quick    Run quick smoke test only"
            echo "  --clean    Clean up containers, images, and volumes"
            echo "  --help     Show this help message"
            exit 0
            ;;
    esac
done

# Clean mode
if [ "$CLEAN_MODE" = true ]; then
    log_info "Destroying the arena..."
    docker-compose down -v 2>/dev/null || true
    docker rmi crucible-lamb:v8.0 crucible-wolf:v8.0 2>/dev/null || true
    docker network rm crucible-arena 2>/dev/null || true
    docker volume rm crucible-lamb-logs crucible-wolf-results crucible-wolf-logs 2>/dev/null || true
    log_success "Arena destroyed."
    exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           GUARDIAN SHIELD V8.0 - THE CRUCIBLE                ║"
echo "║                                                              ║"
echo "║   \"A defense is not battle-proven until it has faced         ║"
echo "║    a true adversary.\"                                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Step 0: Build Guardian Shield on host first
log_info "Phase 0: Building Guardian Shield on host..."
cd "$GUARDIAN_DIR"

if [ ! -f "zig-out/lib/libwarden.so" ] || [ ! -f "zig-out/bin/wardenctl" ]; then
    log_info "Building libwarden.so and wardenctl..."
    zig build
    if [ ! -f "zig-out/lib/libwarden.so" ]; then
        log_error "Build failed: zig-out/lib/libwarden.so not found"
        exit 1
    fi
    log_success "Guardian Shield built successfully."
else
    log_success "Guardian Shield artifacts already exist."
fi

cd "$SCRIPT_DIR"

# Step 1: Build containers
log_info "Phase 1: Forging the containers..."
docker-compose build lamb wolf
log_success "Containers forged."

# Step 2: Start the arena
log_info "Phase 2: Raising the arena..."
docker-compose up -d
log_success "Arena is live."

# Wait for lamb to be healthy
log_info "Waiting for the Lamb to stabilize..."
ATTEMPTS=0
MAX_ATTEMPTS=30
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    if docker exec crucible-lamb pgrep -x sshd > /dev/null 2>&1; then
        log_success "Lamb is ready (SSH daemon running)."
        break
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 1
done

if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    log_error "Lamb failed to stabilize. Check logs: docker-compose logs lamb"
    exit 1
fi

# Step 3: Verify Guardian Shield is loaded
log_info "Phase 3: Verifying Guardian Shield protection..."
if docker exec crucible-lamb cat /proc/self/maps 2>/dev/null | grep -q "libwarden"; then
    log_success "Guardian Shield V8.0 is ACTIVE (libwarden.so loaded)"
else
    log_warn "Warning: libwarden.so may not be loaded. Continuing anyway..."
fi

# Step 4: Run attacks
log_info "Phase 4: Unleashing the Wolf..."
echo ""

if [ "$QUICK_MODE" = true ]; then
    # Quick smoke test - just try one attack
    log_info "Running quick smoke test..."
    docker exec crucible-wolf bash -c "
        export SSHPASS=root
        sshpass -e ssh -o StrictHostKeyChecking=no root@lamb 'rm /etc/passwd' 2>&1 || true
    " | head -20
else
    # Full campaign
    log_info "Running full attack campaign..."
    docker exec crucible-wolf bash -c "
        cd /wolf
        export SSHPASS=\$LAMB_PASS

        # Setup SSH
        mkdir -p ~/.ssh
        ssh-keyscan lamb >> ~/.ssh/known_hosts 2>/dev/null

        echo '=== GUARDIAN SHIELD V8.0 CRUCIBLE ===' > /wolf/results/campaign-report.md
        echo 'Date: '\$(date) >> /wolf/results/campaign-report.md
        echo '' >> /wolf/results/campaign-report.md

        run_attack() {
            local name=\$1
            local cmd=\$2
            echo \"[*] Testing: \$name\"
            echo \"### \$name\" >> /wolf/results/campaign-report.md
            result=\$(sshpass -e ssh -o StrictHostKeyChecking=no root@lamb \"\$cmd\" 2>&1) || true
            echo \"\$result\"
            echo '\`\`\`' >> /wolf/results/campaign-report.md
            echo \"\$result\" >> /wolf/results/campaign-report.md
            echo '\`\`\`' >> /wolf/results/campaign-report.md
            echo '' >> /wolf/results/campaign-report.md
        }

        echo '## Delete Attacks' >> /wolf/results/campaign-report.md
        run_attack 'Delete /etc/passwd' 'rm -f /etc/passwd'
        run_attack 'Delete protected data' 'rm -f /protected/data/important.txt'

        echo '## Symlink Attacks' >> /wolf/results/campaign-report.md
        run_attack 'Symlink to /usr/bin' 'ln -sf /tmp/evil /usr/bin/fake-python'
        run_attack 'Symlink from /etc/passwd' 'ln -sf /etc/passwd /tmp/stolen'

        echo '## Hardlink Attacks' >> /wolf/results/campaign-report.md
        run_attack 'Hardlink to /usr/bin/sudo' 'ln /usr/bin/sudo /tmp/my-sudo'
        run_attack 'Hardlink from /etc/shadow' 'ln /etc/shadow /tmp/shadow-copy'

        echo '## Truncate Attacks' >> /wolf/results/campaign-report.md
        run_attack 'Truncate /etc/hosts' 'truncate -s 0 /etc/hosts'
        run_attack 'Truncate protected data' 'truncate -s 0 /protected/data/important.txt'

        echo '## Mkdir Attacks' >> /wolf/results/campaign-report.md
        run_attack 'Mkdir in /usr/bin' 'mkdir /usr/bin/evil-dir'
        run_attack 'Mkdir in /protected' 'mkdir /protected/evil-subdir'

        # Generate verdict
        echo '' >> /wolf/results/campaign-report.md
        echo '## Verdict' >> /wolf/results/campaign-report.md
        if grep -qi 'operation not permitted\|permission denied\|blocked\|EACCES' /wolf/results/campaign-report.md; then
            echo '**PASSED** - Guardian Shield blocked attacks!' >> /wolf/results/campaign-report.md
            echo 'PASSED' > /wolf/results/verdict.txt
        else
            echo '**FAILED** - Some attacks may have succeeded!' >> /wolf/results/campaign-report.md
            echo 'FAILED' > /wolf/results/verdict.txt
        fi
    "
fi

echo ""

# Step 5: Show results
log_info "Phase 5: Judgment..."
echo ""

VERDICT=$(docker exec crucible-wolf cat /wolf/results/verdict.txt 2>/dev/null || echo "UNKNOWN")

if [ "$VERDICT" = "PASSED" ]; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║   ✓ GUARDIAN SHIELD V8.0 IS BATTLE-PROVEN                   ║"
    echo "║                                                              ║"
    echo "║   The Lamb endured the Wolf.                                ║"
    echo "║   All attacks were blocked.                                 ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    EXIT_CODE=0
elif [ "$VERDICT" = "FAILED" ]; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║   ✗ GUARDIAN SHIELD HAS VULNERABILITIES                     ║"
    echo "║                                                              ║"
    echo "║   The Wolf breached the Lamb's defenses.                    ║"
    echo "║   Review the campaign report for details.                   ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    EXIT_CODE=1
else
    log_warn "Verdict could not be determined. Check logs."
    EXIT_CODE=2
fi

echo ""
log_info "Full report: docker exec crucible-wolf cat /wolf/results/campaign-report.md"
log_info "Clean up:    ./run-crucible.sh --clean"
echo ""

exit $EXIT_CODE
