#!/bin/bash
# setup_vfio.sh — Bind a NIC to vfio-pci and configure hugepages for zig_dpdk.
#
# Usage:
#   sudo ./scripts/setup_vfio.sh 0000:03:00.0
#
# This script:
#   1. Loads vfio-pci kernel module
#   2. Enables unsafe no-IOMMU mode (for cloud VMs without VT-d)
#   3. Unbinds the NIC from its current driver
#   4. Binds the NIC to vfio-pci
#   5. Allocates 1024 × 2MB hugepages
#   6. Verifies the setup
#
# After running this script:
#   sudo zig-out/bin/zig-dpdk-hw-test 0000:03:00.0

set -euo pipefail

PCI_ADDR="${1:-}"

if [ -z "$PCI_ADDR" ]; then
    echo "Usage: sudo $0 <PCI_ADDRESS>"
    echo "Example: sudo $0 0000:03:00.0"
    echo ""
    echo "Find your NIC's PCI address with: lspci | grep -i ethernet"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

SYSFS_DEV="/sys/bus/pci/devices/${PCI_ADDR}"

if [ ! -d "$SYSFS_DEV" ]; then
    echo "ERROR: PCI device ${PCI_ADDR} not found in sysfs."
    echo "Available PCI devices:"
    lspci | grep -i ethernet || echo "  (no Ethernet devices found)"
    exit 1
fi

# Read vendor and device ID
VENDOR_ID=$(cat "${SYSFS_DEV}/vendor" 2>/dev/null || echo "unknown")
DEVICE_ID=$(cat "${SYSFS_DEV}/device" 2>/dev/null || echo "unknown")
CURRENT_DRIVER=$(basename "$(readlink "${SYSFS_DEV}/driver" 2>/dev/null)" 2>/dev/null || echo "none")

echo "=========================================="
echo "  zig_dpdk VFIO Setup"
echo "=========================================="
echo "  PCI address:    ${PCI_ADDR}"
echo "  Vendor:Device:  ${VENDOR_ID}:${DEVICE_ID}"
echo "  Current driver: ${CURRENT_DRIVER}"
echo ""

# Step 1: Load vfio-pci module
echo "[1/6] Loading vfio-pci module..."
modprobe vfio-pci 2>/dev/null || true
if ! lsmod | grep -q vfio_pci; then
    echo "  WARNING: vfio_pci module not loaded. Trying vfio..."
    modprobe vfio 2>/dev/null || true
fi
echo "  OK"

# Step 2: Enable unsafe no-IOMMU mode (for cloud VMs without VT-d/IOMMU)
echo "[2/6] Enabling unsafe no-IOMMU mode..."
if [ -f /sys/module/vfio/parameters/enable_unsafe_noiommu_mode ]; then
    echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
    echo "  OK (no-IOMMU mode enabled)"
else
    echo "  SKIP (parameter not available — IOMMU may be active, which is fine)"
fi

# Step 3: Unbind NIC from current driver
echo "[3/6] Unbinding ${PCI_ADDR} from ${CURRENT_DRIVER}..."
if [ "$CURRENT_DRIVER" = "vfio-pci" ]; then
    echo "  Already bound to vfio-pci, skipping unbind."
elif [ "$CURRENT_DRIVER" != "none" ]; then
    echo "$PCI_ADDR" > "${SYSFS_DEV}/driver/unbind" 2>/dev/null || true
    sleep 0.5
    echo "  OK"
else
    echo "  No driver bound, skipping."
fi

# Step 4: Bind to vfio-pci
echo "[4/6] Binding ${PCI_ADDR} to vfio-pci..."
if [ "$CURRENT_DRIVER" = "vfio-pci" ]; then
    echo "  Already bound."
else
    # Write vendor:device to new_id to make vfio-pci recognize this device
    VENDOR_NUM=$(echo "$VENDOR_ID" | sed 's/0x//')
    DEVICE_NUM=$(echo "$DEVICE_ID" | sed 's/0x//')
    echo "${VENDOR_NUM} ${DEVICE_NUM}" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true

    # Override driver
    echo "vfio-pci" > "${SYSFS_DEV}/driver_override" 2>/dev/null || true
    echo "$PCI_ADDR" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    sleep 0.5

    # Verify
    NEW_DRIVER=$(basename "$(readlink "${SYSFS_DEV}/driver" 2>/dev/null)" 2>/dev/null || echo "none")
    if [ "$NEW_DRIVER" = "vfio-pci" ]; then
        echo "  OK"
    else
        echo "  WARNING: Driver is '${NEW_DRIVER}', expected 'vfio-pci'."
        echo "  Try: echo '${VENDOR_NUM} ${DEVICE_NUM}' > /sys/bus/pci/drivers/vfio-pci/new_id"
    fi
fi

# Step 5: Allocate hugepages
echo "[5/6] Allocating hugepages..."
CURRENT_HUGEPAGES=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo "0")
TARGET_HUGEPAGES=1024
if [ "$CURRENT_HUGEPAGES" -ge "$TARGET_HUGEPAGES" ]; then
    echo "  Already have ${CURRENT_HUGEPAGES} × 2MB hugepages (>= ${TARGET_HUGEPAGES})"
else
    echo "$TARGET_HUGEPAGES" > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    ACTUAL=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
    echo "  Allocated ${ACTUAL} × 2MB hugepages (requested ${TARGET_HUGEPAGES})"
    if [ "$ACTUAL" -lt "$TARGET_HUGEPAGES" ]; then
        echo "  WARNING: Got fewer hugepages than requested. System may be low on memory."
        echo "  Hint: Try rebooting or using 'echo 1024 > /sys/kernel/mm/hugepages/...' early in boot."
    fi
fi

# Step 6: Verify setup
echo "[6/6] Verifying setup..."
echo ""

# Check VFIO group
IOMMU_GROUP=$(readlink "${SYSFS_DEV}/iommu_group" 2>/dev/null | grep -oP '\d+$' || echo "none")
if [ "$IOMMU_GROUP" = "none" ]; then
    echo "  WARNING: No IOMMU group found. No-IOMMU mode may not be working."
else
    echo "  IOMMU group:    ${IOMMU_GROUP}"
    if [ -c "/dev/vfio/${IOMMU_GROUP}" ]; then
        echo "  VFIO device:    /dev/vfio/${IOMMU_GROUP} (OK)"
    elif [ -c "/dev/vfio/noiommu-${IOMMU_GROUP}" ]; then
        echo "  VFIO device:    /dev/vfio/noiommu-${IOMMU_GROUP} (no-IOMMU OK)"
    else
        echo "  VFIO device:    NOT FOUND"
        echo "  Check: ls -la /dev/vfio/"
    fi
fi

FINAL_DRIVER=$(basename "$(readlink "${SYSFS_DEV}/driver" 2>/dev/null)" 2>/dev/null || echo "none")
echo "  Driver:         ${FINAL_DRIVER}"
echo "  Hugepages:      $(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages) × 2MB"
echo ""

if [ "$FINAL_DRIVER" = "vfio-pci" ]; then
    echo "=========================================="
    echo "  Setup COMPLETE"
    echo "=========================================="
    echo ""
    echo "  Next steps:"
    echo "    zig build hw-test"
    echo "    sudo zig-out/bin/zig-dpdk-hw-test ${PCI_ADDR}"
    echo ""
else
    echo "=========================================="
    echo "  Setup INCOMPLETE"
    echo "=========================================="
    echo ""
    echo "  The NIC is not bound to vfio-pci."
    echo "  Manual steps:"
    echo "    echo '${PCI_ADDR}' > /sys/bus/pci/drivers/${FINAL_DRIVER}/unbind"
    echo "    echo 'vfio-pci' > ${SYSFS_DEV}/driver_override"
    echo "    echo '${PCI_ADDR}' > /sys/bus/pci/drivers/vfio-pci/bind"
    echo ""
fi
