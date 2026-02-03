#!/usr/bin/env bash
set -euo pipefail

# Minimal Firecracker run helper for local debugging.
# Usage:
#   scripts/run_fc.sh /path/to/firecracker /path/to/vmlinux /path/to/rootfs.ext4 tap0 logs/console.log

FC_BIN="${1:?firecracker binary path required}"
KERNEL_IMG="${2:?kernel image path required}"
ROOTFS_IMG="${3:?rootfs image path required}"
TAP_DEV="${4:?tap device name required}"
CONSOLE_LOG="${5:?console log path required}"

SOCK="/tmp/ukernel-fc.sock"

rm -f "$SOCK"

"$FC_BIN" --api-sock "$SOCK" > "$CONSOLE_LOG" 2>&1 &
FC_PID=$!

# Give Firecracker time to start
sleep 0.1

curl --unix-socket "$SOCK" -i \
  -X PUT 'http://localhost/machine-config' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{"vcpu_count":1,"mem_size_mib":256,"smt":false}'

curl --unix-socket "$SOCK" -i \
  -X PUT 'http://localhost/boot-source' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{\"kernel_image_path\":\"$KERNEL_IMG\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}"

curl --unix-socket "$SOCK" -i \
  -X PUT 'http://localhost/drives/rootfs' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS_IMG\",\"is_root_device\":true,\"is_read_only\":true}"

curl --unix-socket "$SOCK" -i \
  -X PUT 'http://localhost/network-interfaces/eth0' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{\"iface_id\":\"eth0\",\"host_dev_name\":\"$TAP_DEV\",\"guest_mac\":\"AA:FC:00:00:00:01\"}"

curl --unix-socket "$SOCK" -i \
  -X PUT 'http://localhost/actions' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{"action_type":"InstanceStart"}'

echo "Firecracker started (pid $FC_PID). Console: $CONSOLE_LOG"
wait "$FC_PID"
