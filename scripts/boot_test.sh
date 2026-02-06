#!/usr/bin/env bash
# Minimal Firecracker boot test for the Cloud uKernel.
# Tests that the kernel boots and produces expected serial output.
#
# Usage:
#   scripts/boot_test.sh [--firecracker /path/to/firecracker]
#
# Requires: Firecracker binary, KVM access

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

FC_BIN="${1:-${FIRECRACKER:-/usr/local/bin/firecracker}}"
KERNEL="${PROJECT_DIR}/zig-out/bin/ukernel"
SOCK="/tmp/ukernel-boot-test.sock"
LOG="/tmp/ukernel-boot-test.log"
TIMEOUT=5

# --- Preflight checks ---

if [ ! -x "$FC_BIN" ]; then
    echo "FAIL: Firecracker not found at $FC_BIN"
    echo "  Set FIRECRACKER env var or pass path as argument"
    exit 1
fi

if [ ! -f "$KERNEL" ]; then
    echo "FAIL: Kernel binary not found at $KERNEL"
    echo "  Run 'zig build' first"
    exit 1
fi

if [ ! -w /dev/kvm ] 2>/dev/null; then
    echo "FAIL: /dev/kvm not accessible (need KVM for Firecracker)"
    exit 1
fi

# --- Setup ---

ROOTFS="/tmp/ukernel-boot-test.rootfs"
TAP_DEV="tap_test$$"

cleanup() {
    if [ -n "${FC_PID:-}" ] && kill -0 "$FC_PID" 2>/dev/null; then
        kill "$FC_PID" 2>/dev/null || true
        wait "$FC_PID" 2>/dev/null || true
    fi
    rm -f "$SOCK" "$LOG" "$ROOTFS" /tmp/ukernel-empty.ext4
    # Clean up TAP device
    ip link del "$TAP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

rm -f "$SOCK" "$LOG"

# --- Setup TAP device for networking ---

setup_tap() {
    ip tuntap add dev "$TAP_DEV" mode tap
    ip addr add 172.16.0.1/24 dev "$TAP_DEV"
    ip link set "$TAP_DEV" up
    echo "  TAP device: $TAP_DEV (172.16.0.1/24)"
}

setup_tap

# Create rootfs: tar archive with src/main.py for MicroPython
# The kernel reads this as a raw block device via virtio-block and parses as tar
if [ -f "${PROJECT_DIR}/src/main.py" ]; then
    tar cf "$ROOTFS" -C "$PROJECT_DIR" src/main.py
    echo "  Rootfs: tar with src/main.py"
else
    # Fallback: empty file
    dd if=/dev/zero of="$ROOTFS" bs=1M count=1 status=none 2>/dev/null
    echo "  Rootfs: empty (no src/main.py found)"
fi

echo "=== Boot Test ==="
echo "  Firecracker: $FC_BIN"
echo "  Kernel:      $KERNEL"
echo ""

# --- Launch Firecracker ---

"$FC_BIN" --api-sock "$SOCK" > "$LOG" 2>&1 &
FC_PID=$!

# Wait for API socket
for i in $(seq 1 20); do
    [ -S "$SOCK" ] && break
    sleep 0.05
done

if [ ! -S "$SOCK" ]; then
    echo "FAIL: Firecracker API socket did not appear"
    cat "$LOG" 2>/dev/null || true
    exit 1
fi

# Configure machine
curl -s --unix-socket "$SOCK" -X PUT 'http://localhost/machine-config' \
    -H 'Content-Type: application/json' \
    -d '{"vcpu_count":1,"mem_size_mib":256,"smt":false}' > /dev/null

# Configure boot source (kernel only, serial console)
curl -s --unix-socket "$SOCK" -X PUT 'http://localhost/boot-source' \
    -H 'Content-Type: application/json' \
    -d "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}" > /dev/null

# Configure rootfs drive (tar archive for virtio-block)
curl -s --unix-socket "$SOCK" -X PUT 'http://localhost/drives/rootfs' \
    -H 'Content-Type: application/json' \
    -d "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":true}" > /dev/null

# Configure network interface
curl -s --unix-socket "$SOCK" -X PUT 'http://localhost/network-interfaces/eth0' \
    -H 'Content-Type: application/json' \
    -d "{\"iface_id\":\"eth0\",\"host_dev_name\":\"$TAP_DEV\",\"guest_mac\":\"AA:FC:00:00:00:01\"}" > /dev/null

# Start the VM
RESP=$(curl -s --unix-socket "$SOCK" -X PUT 'http://localhost/actions' \
    -H 'Content-Type: application/json' \
    -d '{"action_type":"InstanceStart"}')

# Check for start errors
if echo "$RESP" | grep -q "fault_message"; then
    echo "FAIL: VM failed to start"
    echo "  Response: $RESP"
    cat "$LOG" 2>/dev/null || true
    exit 1
fi

# --- Wait for output ---

echo "  VM started (pid $FC_PID), waiting ${TIMEOUT}s for output..."

# Wait for the kernel to finish (it halts after workload) or timeout
sleep "$TIMEOUT"

# --- Check results ---

echo ""
echo "=== Serial Output ==="
cat "$LOG" 2>/dev/null || true
echo ""
echo "=== Results ==="

PASS=0
FAIL=0

check() {
    local label="$1"
    local pattern="$2"
    if grep -q "$pattern" "$LOG" 2>/dev/null; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected: '$pattern')"
        FAIL=$((FAIL + 1))
    fi
}

check "kernel boot message" "Cloud uKernel: booting"
check "workload started" "workload: starting"
check "sandbox entered" "workload: entered sandbox"
check "heartbeat output" "heartbeat"
check "io_open serial" "io_open serial ok"
check "io_poll writable" "io_poll got events=0x2"
check "io_write via ABI" "hello via io_write"
check "io_write ok" "io_write ok"
check "workload completed" "workload: done"
check "virtio_net init" "virtio_net: ready"
check "micropython init" "micropython: init"
check "micropython boot" "python asyncio starting"
check "python heartbeat" "python heartbeat"
check "python net demo" "python net: sent UDP packet"
check "python net done" "python net: done"
check "python complete" "python asyncio done"
check "micropython done" "micropython: done"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "ALL $PASS CHECKS PASSED"
    exit 0
else
    echo "$FAIL CHECK(S) FAILED ($PASS passed)"
    exit 1
fi
