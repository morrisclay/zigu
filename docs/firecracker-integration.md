# Firecracker Integration Plan (Draft v0.2)

This document describes how the Cloud µKernel guest boots and runs on Firecracker, keeping Linux only in the host VMM and fully out of the guest hot path.

## Goals

- Minimal device surface while enabling worker + streaming workloads.
- Fast boot and low memory footprint.
- Clear separation between host control plane and guest kernel.

## Host/Guest boundary

- Host runs Firecracker (VMM) on Linux.
- Guest is the Zig Cloud µKernel (no Linux inside guest).
- Guest communicates via virtio devices only.

## Device model (initial)

- `virtio-net`: networking for worker and streaming data paths.
- `virtio-block`: guest root image containing kernel + runtime adapters.
- `serial console`: debug output and early boot logs.

Planned expansion path (not enabled initially):

- `virtio-rng` for entropy
- `virtio-balloon` for memory hints
- `virtio-vsock` for host-guest control channel

## Firecracker lifecycle (MVP)

1. Build a guest disk image (`ukernel pack`).
2. Create Firecracker VM with:
   - vCPU count
   - memory size
   - network interface tap
   - root block device
3. Start the VM with the µKernel boot entry.
4. Attach logging to serial console.

## Guest boot flow

1. Firecracker loads the kernel image from the root block device.
2. µKernel initializes:
   - memory arenas
   - scheduler
   - virtio drivers
   - event loop
3. µKernel loads an adapter runtime (Python first).
4. µKernel starts the workload entrypoint.

## Control plane responsibilities

- Build + package guest images.
- Manage Firecracker VM lifecycle.
- Provide minimal config injection (env vars, args, secrets).
- Collect logs and traces.

## Networking plan

- Tap interface on host bridged into host network.
- Static IP for initial simplicity.
- Long-term: CNI integration for cloud deployment.

## Image format

- Minimal rootfs containing:
  - µKernel binary
  - runtime adapter(s)
  - workload bundle

- Immutable by default. Optional overlay in later phases.

## Performance targets

- Boot to workload start: microseconds to low milliseconds.
- Resident memory: tens of MB for initial adapters.
- Latency overhead vs bare host: minimal and measured.

## Concrete Firecracker config example

This example shows the minimal JSON objects a control plane would send to the Firecracker API. Paths are illustrative.

### 1) Machine config

```json
{
  "vcpu_count": 1,
  "mem_size_mib": 256,
  "smt": false
}
```

### 2) Boot source

```json
{
  "kernel_image_path": "/var/lib/ukernel/vmlinux",
  "boot_args": "console=ttyS0 reboot=k panic=1"
}
```

### 3) Rootfs drive

```json
{
  "drive_id": "rootfs",
  "path_on_host": "/var/lib/ukernel/rootfs.ext4",
  "is_root_device": true,
  "is_read_only": true
}
```

### 4) Network interface

```json
{
  "iface_id": "eth0",
  "host_dev_name": "tap0",
  "guest_mac": "AA:FC:00:00:00:01"
}
```

## Proposed boot args

- `console=ttyS0` for serial console output.
- `panic=1` for fast fail in early dev.
- `reboot=k` to reboot on panic for rapid iteration.

## Open questions

- Should we adopt `vsock` early for host-guest control?
- How will we expose a debug shell without reintroducing Linux concepts?
- Do we need a custom init format, or raw entrypoint is enough?

