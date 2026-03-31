#!/bin/bash
# capture_controller.sh - The Rite of Inquisition
#
# Purpose: Capture raw input events from /dev/input/eventX for analysis
# Usage: ./capture_controller.sh --device /dev/input/event5 --output capture.json --duration 60

set -e

# Default values
DEVICE=""
OUTPUT_FILE="input_capture.json"
DURATION=60
FORMAT="json"
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}⚖️  THE RITE OF INQUISITION: Input Event Capture${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_error() {
    echo -e "${RED}❌ ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

The Rite of Inquisition: Capture input device events for behavioral analysis

OPTIONS:
    --device PATH       Input device path (e.g., /dev/input/event5) [REQUIRED]
    --output FILE       Output file path (default: input_capture.json)
    --duration SECONDS  Capture duration in seconds (default: 60)
    --format FORMAT     Output format: json|csv|raw (default: json)
    --verbose           Enable verbose output
    --list-devices      List available input devices and exit
    --help              Show this help message

EXAMPLES:
    # List available devices
    $0 --list-devices

    # Capture 60 seconds from gamepad
    $0 --device /dev/input/event5 --output gamepad_capture.json

    # Capture 120 seconds with verbose output
    $0 --device /dev/input/event5 --duration 120 --verbose

THE RITE:
    1. Connect the device (controller, mouse, keyboard)
    2. Run this script to capture raw input events
    3. Analyze the captured data to extract behavioral fingerprints
    4. Forge Grimoire patterns from the inhuman signatures

EOF
}

list_devices() {
    print_header
    echo -e "${YELLOW}Available Input Devices:${NC}"
    echo ""

    if ! command -v evtest &> /dev/null; then
        print_error "evtest not installed. Install with: sudo pacman -S evtest"
        exit 1
    fi

    # List devices with details
    for device in /dev/input/event*; do
        if [ -e "$device" ]; then
            device_name=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "ID_INPUT" | head -1)
            name=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "^NAME=" | cut -d= -f2- | tr -d '"')

            if [ -n "$name" ]; then
                echo -e "  ${GREEN}$device${NC} → $name"
            else
                echo -e "  ${BLUE}$device${NC}"
            fi
        fi
    done

    echo ""
    print_info "Use --device <path> to capture from a specific device"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --device)
            DEVICE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --list-devices)
            list_devices
            exit 0
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validation
if [ -z "$DEVICE" ]; then
    print_error "Device path is required (use --device)"
    echo ""
    usage
    exit 1
fi

if [ ! -e "$DEVICE" ]; then
    print_error "Device not found: $DEVICE"
    echo ""
    list_devices
    exit 1
fi

if [ ! -r "$DEVICE" ]; then
    print_error "Cannot read device: $DEVICE (try running with sudo)"
    exit 1
fi

# Print configuration
print_header
echo -e "${YELLOW}Configuration:${NC}"
echo "  Device:   $DEVICE"
echo "  Output:   $OUTPUT_FILE"
echo "  Duration: ${DURATION}s"
echo "  Format:   $FORMAT"
echo ""

# Get device information
device_info=$(udevadm info --query=property --name="$DEVICE" 2>/dev/null || echo "Unknown device")
device_name=$(echo "$device_info" | grep "^NAME=" | cut -d= -f2- | tr -d '"')

if [ -n "$device_name" ]; then
    print_info "Device name: $device_name"
else
    print_info "Device name: Unknown"
fi

echo ""
print_info "Starting capture in 3 seconds..."
echo ""
echo -e "${YELLOW}Instructions:${NC}"
echo "  - Use the input device normally during capture"
echo "  - For baseline: Play normally"
echo "  - For adversary: Enable cheating device (Cronus Zen, etc.)"
echo "  - Press Ctrl+C to stop early"
echo ""

sleep 3

# Temporary raw capture file
TEMP_RAW="/tmp/input_capture_$$.raw"

# Start capture
print_success "Capture started..."

if [ "$VERBOSE" = true ]; then
    print_info "Capturing to: $TEMP_RAW"
fi

# Capture with timeout
timeout "$DURATION" sudo cat "$DEVICE" > "$TEMP_RAW" 2>/dev/null || true

# Check if we got data
if [ ! -s "$TEMP_RAW" ]; then
    print_error "No data captured"
    rm -f "$TEMP_RAW"
    exit 1
fi

bytes_captured=$(wc -c < "$TEMP_RAW")
events_captured=$((bytes_captured / 24))  # Each input_event is 24 bytes

print_success "Captured $events_captured events ($bytes_captured bytes)"

# Convert to requested format
print_info "Converting to $FORMAT format..."

case $FORMAT in
    json)
        # Convert raw binary to JSON
        python3 << 'EOF' > "$OUTPUT_FILE"
import struct
import json
import sys

# Read raw input events
with open('/tmp/input_capture_' + str(sys.argv[1]) + '.raw', 'rb') as f:
    data = f.read()

# Parse input_event structures
# struct input_event {
#     struct timeval time; (8 + 8 bytes on 64-bit)
#     __u16 type;
#     __u16 code;
#     __s32 value;
# } __attribute__((packed));

events = []
offset = 0
while offset < len(data):
    if offset + 24 <= len(data):
        # Unpack one event (24 bytes)
        tv_sec, tv_usec, type_, code, value = struct.unpack('=QQHHi', data[offset:offset+24])

        timestamp_us = tv_sec * 1000000 + tv_usec

        events.append({
            'timestamp_us': timestamp_us,
            'timestamp_s': float(tv_sec) + float(tv_usec) / 1000000.0,
            'type': type_,
            'code': code,
            'value': value,
        })
    offset += 24

# Output JSON
output = {
    'metadata': {
        'device': sys.argv[2] if len(sys.argv) > 2 else 'unknown',
        'capture_duration_s': sys.argv[3] if len(sys.argv) > 3 else 0,
        'event_count': len(events),
    },
    'events': events
}

json.dump(output, sys.stdout, indent=2)
EOF
python3 -c "
import struct
import json

# Read raw input events
with open('$TEMP_RAW', 'rb') as f:
    data = f.read()

events = []
offset = 0
while offset + 24 <= len(data):
    tv_sec, tv_usec, type_, code, value = struct.unpack('=QQHHi', data[offset:offset+24])
    timestamp_us = tv_sec * 1000000 + tv_usec
    events.append({
        'timestamp_us': timestamp_us,
        'timestamp_s': float(tv_sec) + float(tv_usec) / 1000000.0,
        'type': type_,
        'code': code,
        'value': value,
    })
    offset += 24

output = {
    'metadata': {
        'device': '$DEVICE',
        'device_name': '$device_name',
        'capture_duration_s': $DURATION,
        'event_count': len(events),
    },
    'events': events
}

print(json.dumps(output, indent=2))
" > "$OUTPUT_FILE"
        ;;

    csv)
        # Convert to CSV
        python3 -c "
import struct
import csv
import sys

with open('$TEMP_RAW', 'rb') as f:
    data = f.read()

with open('$OUTPUT_FILE', 'w', newline='') as csvfile:
    writer = csv.writer(csvfile)
    writer.writerow(['timestamp_us', 'type', 'code', 'value'])

    offset = 0
    while offset + 24 <= len(data):
        tv_sec, tv_usec, type_, code, value = struct.unpack('=QQHHi', data[offset:offset+24])
        timestamp_us = tv_sec * 1000000 + tv_usec
        writer.writerow([timestamp_us, type_, code, value])
        offset += 24
"
        ;;

    raw)
        # Just copy the raw file
        cp "$TEMP_RAW" "$OUTPUT_FILE"
        ;;

    *)
        print_error "Unknown format: $FORMAT"
        rm -f "$TEMP_RAW"
        exit 1
        ;;
esac

# Cleanup
rm -f "$TEMP_RAW"

# Success
echo ""
print_success "Capture complete!"
echo ""
echo -e "${YELLOW}Output:${NC} $OUTPUT_FILE"
echo -e "${YELLOW}Events:${NC} $events_captured"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. Analyze: ./analyze_fingerprint.py $OUTPUT_FILE"
echo "  2. Generate pattern: ./generate_pattern.py $OUTPUT_FILE"
echo "  3. Test: ./test_pattern.sh <pattern_file>"
echo ""
