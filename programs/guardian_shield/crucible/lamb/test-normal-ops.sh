#!/bin/bash
# Guardian Shield V8.2 - Normal Operations Battery Test
# Purpose: Verify that libwarden.so does NOT break legitimate system operations
#
# THE CARDINAL RULE: A security tool that breaks the system is worse than no security.
#
# This script tests operations that MUST work for a functioning system.
# If ANY test fails, the library is NOT ready for production deployment.
#
# Usage: ./test-normal-ops.sh [--verbose]

# Note: Don't use 'set -e' - our test functions handle errors gracefully

VERBOSE=0
if [[ "$1" == "--verbose" ]]; then
    VERBOSE=1
fi

PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "${BLUE}[TEST]${NC} $1"
    fi
}

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
}

section() {
    echo ""
    echo -e "${YELLOW}=== $1 ===${NC}"
}

# ============================================================
# SECTION 1: Temporary File Operations
# Programs constantly create/modify/delete temp files
# ============================================================

section "1. Temporary File Operations (/tmp)"

# Test: Create temp file
log "Creating temp file..."
if touch /tmp/warden_test_$$.txt 2>/dev/null; then
    pass "Create temp file"
else
    fail "Create temp file - CRITICAL: Many programs need this!"
fi

# Test: Write to temp file
log "Writing to temp file..."
if echo "test data" > /tmp/warden_test_$$.txt 2>/dev/null; then
    pass "Write to temp file"
else
    fail "Write to temp file - CRITICAL: Build systems, compilers need this!"
fi

# Test: Read temp file
log "Reading temp file..."
if cat /tmp/warden_test_$$.txt >/dev/null 2>&1; then
    pass "Read temp file"
else
    fail "Read temp file"
fi

# Test: Append to temp file
log "Appending to temp file..."
if echo "more data" >> /tmp/warden_test_$$.txt 2>/dev/null; then
    pass "Append to temp file"
else
    fail "Append to temp file"
fi

# Test: Delete temp file (unlink)
log "Deleting temp file..."
if rm /tmp/warden_test_$$.txt 2>/dev/null; then
    pass "Delete temp file (unlink)"
else
    fail "Delete temp file - CRITICAL: Cleanup operations need this!"
fi

# Test: Create temp directory
log "Creating temp directory..."
if mkdir -p /tmp/warden_testdir_$$ 2>/dev/null; then
    pass "Create temp directory (mkdir)"
else
    fail "Create temp directory - CRITICAL: Many programs need this!"
fi

# Test: Create file in temp directory
log "Creating file in temp directory..."
if touch /tmp/warden_testdir_$$/file.txt 2>/dev/null; then
    pass "Create file in temp directory"
else
    fail "Create file in temp directory"
fi

# Test: Delete temp directory
log "Deleting temp directory..."
if rm -rf /tmp/warden_testdir_$$ 2>/dev/null; then
    pass "Delete temp directory (rmdir)"
else
    fail "Delete temp directory"
fi

# ============================================================
# SECTION 2: User Home Directory Operations
# User's own files must be fully accessible
# ============================================================

section "2. User Home Directory Operations"

HOME_TEST_DIR="${HOME:-/tmp}/warden_home_test_$$"

# Test: Create directory in home
log "Creating directory in home area..."
if mkdir -p "$HOME_TEST_DIR" 2>/dev/null; then
    pass "Create directory in user space"
else
    fail "Create directory in user space - CRITICAL!"
fi

# Test: Create file in home
log "Creating file in home directory..."
if touch "$HOME_TEST_DIR/test.txt" 2>/dev/null; then
    pass "Create file in user home"
else
    fail "Create file in user home"
fi

# Test: Write config-like file
log "Writing config file..."
if echo "key=value" > "$HOME_TEST_DIR/config.ini" 2>/dev/null; then
    pass "Write config file"
else
    fail "Write config file"
fi

# Test: Rename file
log "Renaming file..."
if mv "$HOME_TEST_DIR/config.ini" "$HOME_TEST_DIR/config.bak" 2>/dev/null; then
    pass "Rename file (rename syscall)"
else
    fail "Rename file - Programs need this for atomic saves!"
fi

# Test: Symlink creation (in user space)
log "Creating symlink..."
if ln -s "$HOME_TEST_DIR/test.txt" "$HOME_TEST_DIR/test_link" 2>/dev/null; then
    pass "Create symlink in user space"
else
    fail "Create symlink - Package managers need this!"
fi

# Cleanup
rm -rf "$HOME_TEST_DIR" 2>/dev/null || true

# ============================================================
# SECTION 3: Process Runtime Operations
# Operations every process needs to function
# ============================================================

section "3. Process Runtime Operations"

# Test: /proc/self access (CRITICAL for many programs)
log "Accessing /proc/self..."
if cat /proc/self/comm >/dev/null 2>&1; then
    pass "Read /proc/self/comm"
else
    fail "Read /proc/self - CRITICAL: Python, Node.js need this!"
fi

# Test: /proc/self/fd access
log "Accessing /proc/self/fd..."
if ls /proc/self/fd >/dev/null 2>&1; then
    pass "List /proc/self/fd"
else
    fail "List /proc/self/fd - CRITICAL for file descriptor operations!"
fi

# Test: Read /proc/self/maps (debugging, profiling tools)
log "Reading /proc/self/maps..."
if head -5 /proc/self/maps >/dev/null 2>&1; then
    pass "Read /proc/self/maps"
else
    fail "Read /proc/self/maps"
fi

# Test: Read /proc/self/status
log "Reading /proc/self/status..."
if cat /proc/self/status >/dev/null 2>&1; then
    pass "Read /proc/self/status"
else
    fail "Read /proc/self/status"
fi

# ============================================================
# SECTION 4: Common Program Operations
# Test operations that real programs perform
# ============================================================

section "4. Common Program Operations"

# Test: Python temp file handling (if python available)
if command -v python3 &>/dev/null; then
    log "Testing Python tempfile module..."
    if python3 -c "import tempfile; f = tempfile.NamedTemporaryFile(delete=True); f.write(b'test'); f.close()" 2>/dev/null; then
        pass "Python tempfile module"
    else
        fail "Python tempfile module - CRITICAL for Python programs!"
    fi
else
    echo -e "${YELLOW}[SKIP]${NC} Python not installed"
fi

# Test: Shell process substitution (uses /tmp or /dev/fd)
log "Testing shell process substitution..."
if command -v diff &>/dev/null; then
    if diff <(echo "a") <(echo "a") >/dev/null 2>&1; then
        pass "Shell process substitution"
    else
        fail "Shell process substitution"
    fi
else
    # Use cat instead if diff not available
    if [[ "$(cat <(echo "a"))" == "a" ]]; then
        pass "Shell process substitution"
    else
        fail "Shell process substitution"
    fi
fi

# Test: Command pipeline with temp files
log "Testing command pipeline..."
if echo "test" | cat | grep -q "test" 2>/dev/null; then
    pass "Command pipeline"
else
    fail "Command pipeline"
fi

# Test: Here document (uses temp files)
log "Testing here document..."
if cat <<EOF >/dev/null
test heredoc
EOF
then
    pass "Here document"
else
    fail "Here document"
fi

# ============================================================
# SECTION 5: Network-Related File Operations
# Sockets, D-Bus, etc. use filesystem operations
# ============================================================

section "5. Network/IPC File Operations"

# Test: Access /run (runtime data)
log "Checking /run access..."
if ls /run >/dev/null 2>&1; then
    pass "List /run directory"
else
    fail "List /run - CRITICAL for services!"
fi

# Test: Create file in /run/user if available
RUN_USER="/run/user/$(id -u)"
if [[ -d "$RUN_USER" ]]; then
    log "Testing /run/user write..."
    if touch "$RUN_USER/warden_test_$$" 2>/dev/null; then
        rm -f "$RUN_USER/warden_test_$$" 2>/dev/null
        pass "Write to /run/user (user runtime)"
    else
        fail "Write to /run/user - CRITICAL for desktop apps!"
    fi
else
    echo -e "${YELLOW}[SKIP]${NC} /run/user not available (not a desktop session)"
fi

# Test: /dev/null access
log "Testing /dev/null..."
if echo "test" > /dev/null 2>&1; then
    pass "Write to /dev/null"
else
    fail "Write to /dev/null"
fi

# Test: /dev/zero access
log "Testing /dev/zero..."
if head -c 10 /dev/zero >/dev/null 2>&1; then
    pass "Read from /dev/zero"
else
    fail "Read from /dev/zero"
fi

# ============================================================
# SECTION 6: Git Operations (if git available)
# Critical for development workflows
# ============================================================

section "6. Git Operations"

if command -v git &>/dev/null; then
    GIT_TEST_DIR="/tmp/warden_git_test_$$"
    mkdir -p "$GIT_TEST_DIR"
    cd "$GIT_TEST_DIR"

    # Test: git init
    log "Testing git init..."
    if git init >/dev/null 2>&1; then
        pass "git init"
    else
        fail "git init - CRITICAL for developers!"
    fi

    # Test: Create and add file
    log "Testing git add..."
    echo "test" > test.txt
    if git add test.txt 2>/dev/null; then
        pass "git add"
    else
        fail "git add"
    fi

    # Test: git commit (creates files in .git)
    log "Testing git commit..."
    git config user.email "test@test.com" 2>/dev/null || true
    git config user.name "Test" 2>/dev/null || true
    if git commit -m "test" >/dev/null 2>&1; then
        pass "git commit"
    else
        fail "git commit - CRITICAL: git operations must work!"
    fi

    # Test: Create/delete branch (modifies .git)
    log "Testing git branch..."
    if git branch test-branch 2>/dev/null && git branch -d test-branch 2>/dev/null; then
        pass "git branch create/delete"
    else
        fail "git branch operations"
    fi

    # Cleanup
    cd /
    rm -rf "$GIT_TEST_DIR" 2>/dev/null || true
else
    echo -e "${YELLOW}[SKIP]${NC} Git not installed"
fi

# ============================================================
# SECTION 7: Build Tool Operations
# Compilers, linkers, build systems
# ============================================================

section "7. Build Tool Operations"

# Test: gcc/cc if available (creates temp files)
if command -v gcc &>/dev/null || command -v cc &>/dev/null; then
    CC=$(command -v gcc || command -v cc)
    log "Testing C compiler..."

    TEST_C="/tmp/warden_test_$$.c"
    echo 'int main() { return 0; }' > "$TEST_C"

    if $CC -o /tmp/warden_test_$$.out "$TEST_C" 2>/dev/null; then
        pass "C compilation (creates many temp files)"
        rm -f /tmp/warden_test_$$.out
    else
        fail "C compilation - CRITICAL for build systems!"
    fi

    rm -f "$TEST_C"
else
    echo -e "${YELLOW}[SKIP]${NC} No C compiler available"
fi

# Test: make if available
if command -v make &>/dev/null; then
    log "Testing make..."
    MAKE_DIR="/tmp/warden_make_test_$$"
    mkdir -p "$MAKE_DIR"
    echo -e "all:\n\t@echo 'test'" > "$MAKE_DIR/Makefile"

    if make -C "$MAKE_DIR" >/dev/null 2>&1; then
        pass "make execution"
    else
        fail "make execution"
    fi

    rm -rf "$MAKE_DIR"
else
    echo -e "${YELLOW}[SKIP]${NC} make not installed"
fi

# ============================================================
# SECTION 8: Package Manager Operations (containers)
# Critical for system updates
# ============================================================

section "8. Package Manager Operations"

# Test: pacman database access (read-only)
if [[ -d /var/lib/pacman ]]; then
    log "Testing pacman database read..."
    if pacman -Q >/dev/null 2>&1; then
        pass "pacman query (read database)"
    else
        fail "pacman query"
    fi
fi

# Test: apt/dpkg if available
if command -v dpkg &>/dev/null; then
    log "Testing dpkg database read..."
    if dpkg -l >/dev/null 2>&1; then
        pass "dpkg query"
    else
        fail "dpkg query"
    fi
fi

# ============================================================
# SECTION 9: Log Writing Operations
# Programs need to write logs
# ============================================================

section "9. Logging Operations"

# Test: Write to /var/log if writable (usually only root)
if [[ -w /var/log ]]; then
    log "Testing /var/log write..."
    if touch /var/log/warden_test_$$.log 2>/dev/null; then
        rm -f /var/log/warden_test_$$.log
        pass "Write to /var/log"
    else
        fail "Write to /var/log"
    fi
else
    echo -e "${YELLOW}[SKIP]${NC} /var/log not writable (not root)"
fi

# Test: Logger command
if command -v logger &>/dev/null; then
    log "Testing logger command..."
    if logger "warden test $$" 2>/dev/null; then
        pass "logger command"
    else
        fail "logger command"
    fi
fi

# ============================================================
# SECTION 10: Editor/IDE Operations
# Text editors need these operations
# ============================================================

section "10. Editor-Style Operations"

EDITOR_TEST="/tmp/warden_editor_test_$$.txt"

# Test: Create backup file (editors do this)
log "Testing backup file creation..."
echo "original content" > "$EDITOR_TEST"
if cp "$EDITOR_TEST" "${EDITOR_TEST}.bak" 2>/dev/null; then
    pass "Create backup file"
else
    fail "Create backup file"
fi

# Test: Atomic save (write temp, rename)
log "Testing atomic save pattern..."
echo "new content" > "${EDITOR_TEST}.tmp"
if mv "${EDITOR_TEST}.tmp" "$EDITOR_TEST" 2>/dev/null; then
    pass "Atomic save (rename)"
else
    fail "Atomic save - Editors use this for safe writes!"
fi

# Test: Create swap file (vim does this)
log "Testing swap file creation..."
if touch "${EDITOR_TEST}.swp" 2>/dev/null; then
    pass "Create swap file"
else
    fail "Create swap file"
fi

# Cleanup
rm -f "$EDITOR_TEST" "${EDITOR_TEST}.bak" "${EDITOR_TEST}.swp" 2>/dev/null

# ============================================================
# RESULTS SUMMARY
# ============================================================

echo ""
echo "========================================"
echo -e "        ${YELLOW}BATTERY TEST RESULTS${NC}"
echo "========================================"
echo ""
echo -e "Total Tests: $TOTAL"
echo -e "${GREEN}Passed:${NC} $PASS"
echo -e "${RED}Failed:${NC} $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}========================================"
    echo -e "  ALL TESTS PASSED - SAFE TO DEPLOY"
    echo -e "========================================${NC}"
    exit 0
else
    echo -e "${RED}========================================"
    echo -e "  $FAIL TESTS FAILED - DO NOT DEPLOY!"
    echo -e "  Fix issues before production use."
    echo -e "========================================${NC}"
    exit 1
fi
