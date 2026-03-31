#!/bin/bash
#
# zsss Test Harness
# Comprehensive tests for Shamir Secret Sharing, Steganography, and Event Tickets
#
# Usage: ./tests/run_tests.sh [--verbose] [--keep-temp]
#

# Don't exit on error - we want to continue testing
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZSSS="$PROJECT_DIR/zig-out/bin/zsss"
TEST_IMAGES_DIR="/home/founder/Pictures/ai_generated_images/vertex-batch-crg-direct-blog-images"
TEMP_DIR="/tmp/zsss_tests_$$"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Options
VERBOSE=false
KEEP_TEMP=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --verbose|-v)
            VERBOSE=true
            ;;
        --keep-temp|-k)
            KEEP_TEMP=true
            ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--keep-temp]"
            echo "  --verbose, -v    Show detailed output"
            echo "  --keep-temp, -k  Keep temporary files after tests"
            exit 0
            ;;
    esac
done

# Utility functions
log() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_verbose() {
    if $VERBOSE; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

pass() {
    ((TESTS_PASSED++))
    echo -e "${GREEN}[PASS]${NC} $1"
}

fail() {
    ((TESTS_FAILED++))
    echo -e "${RED}[FAIL]${NC} $1"
    if [ -n "$2" ]; then
        echo -e "${RED}       Error: $2${NC}"
    fi
}

cleanup() {
    if ! $KEEP_TEMP && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Setup
setup() {
    log "Setting up test environment..."

    # Create temp directory
    mkdir -p "$TEMP_DIR"
    mkdir -p "$TEMP_DIR/shares"

    # Build project
    log_verbose "Building zsss..."
    cd "$PROJECT_DIR"
    if ! /usr/local/zig/zig build 2>/dev/null; then
        echo -e "${RED}Build failed!${NC}"
        exit 1
    fi

    # Verify binary exists
    if [ ! -x "$ZSSS" ]; then
        echo -e "${RED}zsss binary not found at $ZSSS${NC}"
        exit 1
    fi

    # Select test images (pick 3 different sizes)
    TEST_IMAGE_1=$(find "$TEST_IMAGES_DIR" -name "*.png" | head -1)
    TEST_IMAGE_2=$(find "$TEST_IMAGES_DIR" -name "*.png" | head -2 | tail -1)
    TEST_IMAGE_3=$(find "$TEST_IMAGES_DIR" -name "*.png" | head -3 | tail -1)

    if [ -z "$TEST_IMAGE_1" ]; then
        echo -e "${RED}No test images found in $TEST_IMAGES_DIR${NC}"
        exit 1
    fi

    log_verbose "Using test images:"
    log_verbose "  1: $TEST_IMAGE_1"
    log_verbose "  2: $TEST_IMAGE_2"
    log_verbose "  3: $TEST_IMAGE_3"

    echo ""
}

# =============================================================================
# Shamir Secret Sharing Tests
# =============================================================================

test_sss_basic_split_combine() {
    ((TESTS_RUN++))
    local test_name="SSS: Basic split and combine"

    local secret="This is a test secret for Shamir splitting"
    local secret_file="$TEMP_DIR/secret.txt"
    local shares_dir="$TEMP_DIR/shares_basic"
    local recovered_file="$TEMP_DIR/recovered.txt"

    # Create secret file
    echo -n "$secret" > "$secret_file"
    mkdir -p "$shares_dir"

    # Split
    if ! $ZSSS split -t 3 -n 5 -i "$secret_file" -o "$shares_dir" 2>/dev/null; then
        fail "$test_name" "Split failed"
        return
    fi

    # Get share files
    local share1=$(ls "$shares_dir"/*.sss 2>/dev/null | head -1)
    local share2=$(ls "$shares_dir"/*.sss 2>/dev/null | head -2 | tail -1)
    local share3=$(ls "$shares_dir"/*.sss 2>/dev/null | head -3 | tail -1)

    if [ -z "$share1" ] || [ -z "$share2" ] || [ -z "$share3" ]; then
        fail "$test_name" "Share files not created"
        return
    fi

    # Combine
    if ! $ZSSS combine -s "$share1" -s "$share2" -s "$share3" -o "$recovered_file" 2>/dev/null; then
        fail "$test_name" "Combine failed"
        return
    fi

    # Verify
    local recovered=$(cat "$recovered_file")
    if [ "$recovered" = "$secret" ]; then
        pass "$test_name"
    else
        fail "$test_name" "Recovered secret doesn't match"
    fi
}

test_sss_verify_shares() {
    ((TESTS_RUN++))
    local test_name="SSS: Verify share integrity"

    local secret_file="$TEMP_DIR/verify_secret.txt"
    local shares_dir="$TEMP_DIR/shares_verify"

    echo "Secret for verification" > "$secret_file"
    mkdir -p "$shares_dir"

    # Split
    $ZSSS split -t 2 -n 3 -i "$secret_file" -o "$shares_dir" 2>&1 | grep -v "libwarden"

    # Verify each share
    local all_valid=true
    for share in "$shares_dir"/*.sss; do
        local output=$($ZSSS verify -s "$share" 2>&1)
        if ! echo "$output" | grep -q "VALID"; then
            all_valid=false
            log_verbose "Share $share output: $output"
        fi
    done

    if $all_valid; then
        pass "$test_name"
    else
        fail "$test_name" "Some shares failed verification"
    fi
}

test_sss_large_secret() {
    ((TESTS_RUN++))
    local test_name="SSS: Large secret (1KB)"

    local shares_dir="$TEMP_DIR/shares_large"
    mkdir -p "$shares_dir"

    # Generate 1KB of random data using head (dd is blocked by warden)
    head -c 1024 /dev/urandom > "$TEMP_DIR/large_secret.bin"

    # Split
    if ! $ZSSS split -t 2 -n 3 -i "$TEMP_DIR/large_secret.bin" -o "$shares_dir" 2>&1 | grep -v "libwarden"; then
        fail "$test_name" "Split failed"
        return
    fi

    # Combine
    local share1=$(ls "$shares_dir"/*.sss | head -1)
    local share2=$(ls "$shares_dir"/*.sss | head -2 | tail -1)

    if ! $ZSSS combine -s "$share1" -s "$share2" -o "$TEMP_DIR/large_recovered.bin" 2>&1 | grep -v "libwarden"; then
        fail "$test_name" "Combine failed"
        return
    fi

    # Compare
    if cmp -s "$TEMP_DIR/large_secret.bin" "$TEMP_DIR/large_recovered.bin"; then
        pass "$test_name"
    else
        fail "$test_name" "Recovered data doesn't match"
    fi
}

# =============================================================================
# Steganography Tests
# =============================================================================

test_stego_basic_embed_extract() {
    ((TESTS_RUN++))
    local test_name="Stego: Basic embed and extract"

    local secret="Hidden message in image"
    local secret_file="$TEMP_DIR/stego_secret.txt"
    local output_image="$TEMP_DIR/stego_output.png"
    local extracted_file="$TEMP_DIR/stego_extracted.txt"

    echo -n "$secret" > "$secret_file"

    # Embed
    if ! $ZSSS stego embed --image "$TEST_IMAGE_1" -i "$secret_file" -o "$output_image" 2>/dev/null; then
        fail "$test_name" "Embed failed"
        return
    fi

    # Verify output exists
    if [ ! -f "$output_image" ]; then
        fail "$test_name" "Output image not created"
        return
    fi

    # Extract
    if ! $ZSSS stego extract --image "$output_image" -o "$extracted_file" 2>/dev/null; then
        fail "$test_name" "Extract failed"
        return
    fi

    # Verify
    local extracted=$(cat "$extracted_file")
    if [ "$extracted" = "$secret" ]; then
        pass "$test_name"
    else
        fail "$test_name" "Extracted data doesn't match (got: '$extracted')"
    fi
}

test_stego_with_password() {
    ((TESTS_RUN++))
    local test_name="Stego: Embed/extract with password"

    local secret="Password protected secret"
    local password="MySecretPass123"
    local secret_file="$TEMP_DIR/stego_pass_secret.txt"
    local output_image="$TEMP_DIR/stego_pass_output.png"
    local extracted_file="$TEMP_DIR/stego_pass_extracted.txt"

    echo -n "$secret" > "$secret_file"

    # Embed with password
    if ! $ZSSS stego embed --image "$TEST_IMAGE_1" -i "$secret_file" -o "$output_image" -p "$password" 2>/dev/null; then
        fail "$test_name" "Embed with password failed"
        return
    fi

    # Extract with correct password
    if ! $ZSSS stego extract --image "$output_image" -o "$extracted_file" -p "$password" 2>/dev/null; then
        fail "$test_name" "Extract with password failed"
        return
    fi

    local extracted=$(cat "$extracted_file")
    if [ "$extracted" = "$secret" ]; then
        pass "$test_name"
    else
        fail "$test_name" "Extracted data doesn't match"
    fi
}

test_stego_wrong_password() {
    ((TESTS_RUN++))
    local test_name="Stego: Wrong password fails"

    local secret="This should be protected"
    local password="CorrectPassword"
    local wrong_password="WrongPassword"
    local secret_file="$TEMP_DIR/stego_wrong_secret.txt"
    local output_image="$TEMP_DIR/stego_wrong_pass.png"

    echo -n "$secret" > "$secret_file"

    # Embed with password
    $ZSSS stego embed --image "$TEST_IMAGE_1" -i "$secret_file" -o "$output_image" -p "$password" 2>/dev/null

    # Try to extract with wrong password (should fail)
    if $ZSSS stego extract --image "$output_image" -o "$TEMP_DIR/wrong_out.txt" -p "$wrong_password" 2>/dev/null; then
        fail "$test_name" "Should have failed with wrong password"
    else
        pass "$test_name"
    fi
}

test_stego_multi_layer() {
    ((TESTS_RUN++))
    local test_name="Stego: Multi-layer embedding"

    local secret1="Layer 0 data"
    local secret2="Layer 1 data"
    local secret3="Layer 255 data"
    local pass1="pass_layer_0"
    local pass2="pass_layer_1"
    local pass3="pass_layer_255"
    local image="$TEMP_DIR/stego_multi.png"

    # Start with original image
    cp "$TEST_IMAGE_1" "$image"

    # Create secret files
    echo -n "$secret1" > "$TEMP_DIR/layer0.txt"
    echo -n "$secret2" > "$TEMP_DIR/layer1.txt"
    echo -n "$secret3" > "$TEMP_DIR/layer255.txt"

    # Embed in layer 0
    $ZSSS stego embed --image "$image" -i "$TEMP_DIR/layer0.txt" -o "$image" -p "$pass1" -l 0 2>/dev/null

    # Embed in layer 1
    $ZSSS stego embed --image "$image" -i "$TEMP_DIR/layer1.txt" -o "$image" -p "$pass2" -l 1 2>/dev/null

    # Embed in layer 255
    $ZSSS stego embed --image "$image" -i "$TEMP_DIR/layer255.txt" -o "$image" -p "$pass3" -l 255 2>/dev/null

    # Extract each layer
    $ZSSS stego extract --image "$image" -o "$TEMP_DIR/ext0.txt" -p "$pass1" -l 0 2>/dev/null || true
    $ZSSS stego extract --image "$image" -o "$TEMP_DIR/ext1.txt" -p "$pass2" -l 1 2>/dev/null || true
    $ZSSS stego extract --image "$image" -o "$TEMP_DIR/ext255.txt" -p "$pass3" -l 255 2>/dev/null || true

    local ext1=$(cat "$TEMP_DIR/ext0.txt" 2>/dev/null || echo "")
    local ext2=$(cat "$TEMP_DIR/ext1.txt" 2>/dev/null || echo "")
    local ext3=$(cat "$TEMP_DIR/ext255.txt" 2>/dev/null || echo "")

    if [ "$ext1" = "$secret1" ] && [ "$ext2" = "$secret2" ] && [ "$ext3" = "$secret3" ]; then
        pass "$test_name"
    else
        fail "$test_name" "One or more layers failed extraction"
        log_verbose "Layer 0: expected '$secret1', got '$ext1'"
        log_verbose "Layer 1: expected '$secret2', got '$ext2'"
        log_verbose "Layer 255: expected '$secret3', got '$ext3'"
    fi
}

# =============================================================================
# Event Ticket Tests
# =============================================================================

test_ticket_capacity() {
    ((TESTS_RUN++))
    local test_name="Ticket: Check image capacity"

    local output=$($ZSSS ticket capacity --image "$TEST_IMAGE_1" 2>&1)

    if echo "$output" | grep -q "Practical capacity: 256 tickets"; then
        pass "$test_name"
    elif echo "$output" | grep -q "Bytes/layer"; then
        pass "$test_name"
    else
        fail "$test_name" "Capacity output not found"
        log_verbose "Output: $output"
    fi
}

test_ticket_create_single() {
    ((TESTS_RUN++))
    local test_name="Ticket: Create single ticket"

    local output_base="$TEMP_DIR/single_ticket"

    if ! $ZSSS ticket create \
        --image "$TEST_IMAGE_1" \
        --event "TEST-EVENT-001" \
        -c 1 \
        --tier "General" \
        -o "$output_base" 2>/dev/null; then
        fail "$test_name" "Create failed"
        return
    fi

    # Verify files created
    if [ -f "${output_base}.png" ] && [ -f "${output_base}_passwords.txt" ]; then
        # Verify password file has 1 entry
        local count=$(wc -l < "${output_base}_passwords.txt")
        if [ "$count" -eq 1 ]; then
            pass "$test_name"
        else
            fail "$test_name" "Expected 1 password, got $count"
        fi
    else
        fail "$test_name" "Output files not created"
    fi
}

test_ticket_create_batch() {
    ((TESTS_RUN++))
    local test_name="Ticket: Create batch of 10 tickets"

    local output_base="$TEMP_DIR/batch_tickets"

    if ! $ZSSS ticket create \
        --image "$TEST_IMAGE_2" \
        --event "CONCERT-2026" \
        -c 10 \
        --tier "VIP" \
        --seat-prefix "A-" \
        -o "$output_base" 2>/dev/null; then
        fail "$test_name" "Create failed"
        return
    fi

    # Verify password file has 10 entries
    if [ -f "${output_base}_passwords.txt" ]; then
        local count=$(wc -l < "${output_base}_passwords.txt")
        if [ "$count" -eq 10 ]; then
            pass "$test_name"
        else
            fail "$test_name" "Expected 10 passwords, got $count"
        fi
    else
        fail "$test_name" "Password file not created"
    fi
}

test_ticket_verify_valid() {
    ((TESTS_RUN++))
    local test_name="Ticket: Verify valid ticket"

    local output_base="$TEMP_DIR/verify_test"

    # Create a ticket
    $ZSSS ticket create \
        --image "$TEST_IMAGE_1" \
        --event "VERIFY-TEST" \
        -c 1 \
        --tier "Premium" \
        --seat-prefix "B-" \
        -o "$output_base" 2>&1 | grep -v "libwarden"

    # Get the password (format: "Ticket   1: Layer   0 | Password: XXXXXXXX | Seat: B-1")
    local password=$(cat "${output_base}_passwords.txt" 2>/dev/null | head -1 | sed 's/.*Password: \([^ ]*\).*/\1/')

    log_verbose "Testing with password: $password"

    # Verify ticket
    local output=$($ZSSS ticket verify --image "${output_base}.png" -p "$password" 2>&1)

    if echo "$output" | grep -q "VALID TICKET"; then
        if echo "$output" | grep -q "Event: VERIFY-TEST" && \
           echo "$output" | grep -q "Tier: Premium" && \
           echo "$output" | grep -q "Seat: B-1"; then
            pass "$test_name"
        else
            fail "$test_name" "Ticket data incorrect"
            log_verbose "Output: $output"
        fi
    else
        fail "$test_name" "Ticket not valid"
        log_verbose "Output: $output"
        log_verbose "Password: $password"
    fi
}

test_ticket_verify_invalid() {
    ((TESTS_RUN++))
    local test_name="Ticket: Invalid password rejected"

    local output_base="$TEMP_DIR/invalid_test"

    # Create a ticket
    $ZSSS ticket create \
        --image "$TEST_IMAGE_1" \
        --event "INVALID-TEST" \
        -c 1 \
        -o "$output_base" 2>/dev/null

    # Try with wrong password
    if $ZSSS ticket verify --image "${output_base}.png" -p "WRONG_PASSWORD" 2>/dev/null; then
        fail "$test_name" "Should have rejected invalid password"
    else
        pass "$test_name"
    fi
}

test_ticket_info() {
    ((TESTS_RUN++))
    local test_name="Ticket: Get detailed info"

    local output_base="$TEMP_DIR/info_test"

    # Create a ticket
    $ZSSS ticket create \
        --image "$TEST_IMAGE_1" \
        --event "INFO-TEST-2026" \
        -c 1 \
        --tier "Diamond" \
        --seat-prefix "VIP-" \
        -o "$output_base" 2>&1 | grep -v "libwarden"

    # Get the password
    local password=$(cat "${output_base}_passwords.txt" 2>/dev/null | head -1 | sed 's/.*Password: \([^ ]*\).*/\1/')

    # Get ticket info
    local output=$($ZSSS ticket info --image "${output_base}.png" -p "$password" 2>&1)

    if echo "$output" | grep -q "Event ID:" && \
       echo "$output" | grep -q "Ticket ID:" && \
       echo "$output" | grep -q "Signature:"; then
        pass "$test_name"
    else
        fail "$test_name" "Info output incomplete"
        log_verbose "Output: $output"
        log_verbose "Password: $password"
    fi
}

test_ticket_multi_layer_independence() {
    ((TESTS_RUN++))
    local test_name="Ticket: Multi-layer independence"

    local output_base="$TEMP_DIR/multi_layer"

    # Create 5 tickets
    $ZSSS ticket create \
        --image "$TEST_IMAGE_3" \
        --event "MULTI-LAYER-TEST" \
        -c 5 \
        --tier "Test" \
        --seat-prefix "S-" \
        -o "$output_base" 2>&1 | grep -v "libwarden"

    # Verify each ticket independently
    local all_valid=true
    local line_num=0
    while IFS= read -r line; do
        ((line_num++)) || true
        local password=$(echo "$line" | sed 's/.*Password: \([^ ]*\).*/\1/')

        local output=$($ZSSS ticket verify --image "${output_base}.png" -p "$password" 2>&1)

        if ! echo "$output" | grep -q "VALID TICKET"; then
            all_valid=false
            log_verbose "Failed for line $line_num with password $password"
            log_verbose "Output: $output"
        fi
    done < "${output_base}_passwords.txt"

    if $all_valid; then
        pass "$test_name"
    else
        fail "$test_name" "Some tickets failed verification"
    fi
}

test_ticket_large_batch() {
    ((TESTS_RUN++))
    local test_name="Ticket: Large batch (50 tickets)"

    local output_base="$TEMP_DIR/large_batch"

    # Create 50 tickets
    $ZSSS ticket create \
        --image "$TEST_IMAGE_2" \
        --event "LARGE-BATCH-2026" \
        -c 50 \
        --tier "General" \
        -o "$output_base" 2>&1 | grep -v "libwarden"

    if [ ! -f "${output_base}_passwords.txt" ]; then
        fail "$test_name" "Create failed - no password file"
        return
    fi

    # Verify count
    local count=$(wc -l < "${output_base}_passwords.txt")
    if [ "$count" -eq 50 ]; then
        # Spot check first, middle, and last tickets
        local pass1=$(sed -n '1p' "${output_base}_passwords.txt" | sed 's/.*Password: \([^ ]*\).*/\1/')
        local pass25=$(sed -n '25p' "${output_base}_passwords.txt" | sed 's/.*Password: \([^ ]*\).*/\1/')
        local pass50=$(sed -n '50p' "${output_base}_passwords.txt" | sed 's/.*Password: \([^ ]*\).*/\1/')

        local v1=$($ZSSS ticket verify --image "${output_base}.png" -p "$pass1" 2>&1)
        local v25=$($ZSSS ticket verify --image "${output_base}.png" -p "$pass25" 2>&1)
        local v50=$($ZSSS ticket verify --image "${output_base}.png" -p "$pass50" 2>&1)

        if echo "$v1" | grep -q "VALID" && \
           echo "$v25" | grep -q "VALID" && \
           echo "$v50" | grep -q "VALID"; then
            pass "$test_name"
        else
            fail "$test_name" "Some spot checks failed"
            log_verbose "Ticket 1 (pass=$pass1): $v1"
            log_verbose "Ticket 25 (pass=$pass25): $v25"
            log_verbose "Ticket 50 (pass=$pass50): $v50"
        fi
    else
        fail "$test_name" "Expected 50 tickets, got $count"
    fi
}

# =============================================================================
# Integration Tests
# =============================================================================

test_integration_sss_in_stego() {
    ((TESTS_RUN++))
    local test_name="Integration: SSS shares in stego image"

    local secret="Super secret data to split and hide"
    local secret_file="$TEMP_DIR/int_secret.txt"
    local shares_dir="$TEMP_DIR/int_shares"
    local image_out="$TEMP_DIR/int_stego.png"

    echo -n "$secret" > "$secret_file"
    mkdir -p "$shares_dir"

    # Split secret
    $ZSSS split -t 2 -n 3 -i "$secret_file" -o "$shares_dir" 2>/dev/null

    # Get first share
    local share1=$(ls "$shares_dir"/*.sss | head -1)

    # Hide share in image
    $ZSSS stego embed --image "$TEST_IMAGE_1" -i "$share1" -o "$image_out" -p "integration_test" 2>/dev/null

    # Extract share
    $ZSSS stego extract --image "$image_out" -o "$TEMP_DIR/int_extracted.sss" -p "integration_test" 2>/dev/null

    # Verify extracted share matches original
    if cmp -s "$share1" "$TEMP_DIR/int_extracted.sss"; then
        pass "$test_name"
    else
        fail "$test_name" "Extracted share doesn't match original"
    fi
}

test_integration_different_images() {
    ((TESTS_RUN++))
    local test_name="Integration: Same data in different images"

    local secret="Testing across images"
    local secret_file="$TEMP_DIR/multi_secret.txt"
    local pass="same_password"

    echo -n "$secret" > "$secret_file"

    # Embed in multiple images
    for i in 1 2 3; do
        local src_image=$(find "$TEST_IMAGES_DIR" -name "*.png" | head -$i | tail -1)
        $ZSSS stego embed --image "$src_image" -i "$secret_file" -o "$TEMP_DIR/multi_img_$i.png" -p "$pass" 2>/dev/null
    done

    # Verify all extract correctly
    local all_match=true
    for i in 1 2 3; do
        $ZSSS stego extract --image "$TEMP_DIR/multi_img_$i.png" -o "$TEMP_DIR/multi_ext_$i.txt" -p "$pass" 2>/dev/null || true
        local extracted=$(cat "$TEMP_DIR/multi_ext_$i.txt" 2>/dev/null || echo "")
        if [ "$extracted" != "$secret" ]; then
            all_match=false
            log_verbose "Image $i failed: expected '$secret', got '$extracted'"
        fi
    done

    if $all_match; then
        pass "$test_name"
    else
        fail "$test_name" "Not all images extracted correctly"
    fi
}

# =============================================================================
# Error Handling Tests
# =============================================================================

test_error_invalid_image() {
    ((TESTS_RUN++))
    local test_name="Error: Invalid image file"

    echo "not a png" > "$TEMP_DIR/fake.png"
    echo "test" > "$TEMP_DIR/test_data.txt"

    if $ZSSS stego embed --image "$TEMP_DIR/fake.png" -i "$TEMP_DIR/test_data.txt" -o "$TEMP_DIR/out.png" 2>/dev/null; then
        fail "$test_name" "Should have failed with invalid PNG"
    else
        pass "$test_name"
    fi
}

test_error_missing_file() {
    ((TESTS_RUN++))
    local test_name="Error: Missing input file"

    if $ZSSS stego extract --image "/nonexistent/file.png" -o "$TEMP_DIR/out.txt" 2>/dev/null; then
        fail "$test_name" "Should have failed with missing file"
    else
        pass "$test_name"
    fi
}

test_error_empty_secret() {
    ((TESTS_RUN++))
    local test_name="Error: Empty secret"

    touch "$TEMP_DIR/empty.txt"
    mkdir -p "$TEMP_DIR/empty_shares"

    if $ZSSS split -t 2 -n 3 -i "$TEMP_DIR/empty.txt" -o "$TEMP_DIR/empty_shares" 2>/dev/null; then
        fail "$test_name" "Should have failed with empty secret"
    else
        pass "$test_name"
    fi
}

# =============================================================================
# Performance Tests
# =============================================================================

test_perf_ticket_creation_time() {
    ((TESTS_RUN++))
    local test_name="Perf: Ticket creation time (100 tickets)"

    local start=$(date +%s%3N)

    $ZSSS ticket create \
        --image "$TEST_IMAGE_2" \
        --event "PERF-TEST" \
        -c 100 \
        -o "$TEMP_DIR/perf_tickets" 2>/dev/null

    local end=$(date +%s%3N)
    local duration=$((end - start))

    log_verbose "100 tickets created in ${duration}ms"

    if [ "$duration" -lt 30000 ]; then  # Should complete in under 30 seconds
        pass "$test_name (${duration}ms)"
    else
        fail "$test_name" "Took too long: ${duration}ms"
    fi
}

# =============================================================================
# Main Test Runner
# =============================================================================

run_all_tests() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║             zsss Test Harness                                ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    setup

    # SSS Tests
    echo -e "${YELLOW}━━━ Shamir Secret Sharing Tests ━━━${NC}"
    test_sss_basic_split_combine
    test_sss_verify_shares
    test_sss_large_secret
    echo ""

    # Steganography Tests
    echo -e "${YELLOW}━━━ Steganography Tests ━━━${NC}"
    test_stego_basic_embed_extract
    test_stego_with_password
    test_stego_wrong_password
    test_stego_multi_layer
    echo ""

    # Ticket Tests
    echo -e "${YELLOW}━━━ Event Ticket Tests ━━━${NC}"
    test_ticket_capacity
    test_ticket_create_single
    test_ticket_create_batch
    test_ticket_verify_valid
    test_ticket_verify_invalid
    test_ticket_info
    test_ticket_multi_layer_independence
    test_ticket_large_batch
    echo ""

    # Integration Tests
    echo -e "${YELLOW}━━━ Integration Tests ━━━${NC}"
    test_integration_sss_in_stego
    test_integration_different_images
    echo ""

    # Error Handling Tests
    echo -e "${YELLOW}━━━ Error Handling Tests ━━━${NC}"
    test_error_invalid_image
    test_error_missing_file
    test_error_empty_secret
    echo ""

    # Performance Tests
    echo -e "${YELLOW}━━━ Performance Tests ━━━${NC}"
    test_perf_ticket_creation_time
    echo ""

    # Summary
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                       Test Summary                           ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Tests Run:    ${TESTS_RUN}"
    echo -e "  ${GREEN}Passed:       ${TESTS_PASSED}${NC}"
    echo -e "  ${RED}Failed:       ${TESTS_FAILED}${NC}"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

# Run tests
run_all_tests
