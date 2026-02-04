# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zigu is a Cloud microkernel (uKernel) designed to run inside Firecracker VMs. It provides a minimal, explicit ABI for async workloads, bypassing Linux in the guest entirely. The kernel is written in Zig and targets x86_64 freestanding. Python workloads run via a runtime adapter that maps `asyncio` to the kernel's `io_poll` primitive.

## Build Commands

```bash
# Build the kernel (debug)
zig build

# Build the kernel (release)
zig build -Doptimize=ReleaseSmall

# Run kernel unit tests
zig test kernel/abi.zig
# or
zig build test
```

## CLI Workflow

The `scripts/ukernel` Python script provides the development workflow:

```bash
scripts/ukernel init              # Create ukernel.toml and src/main.py
scripts/ukernel build             # Build kernel + workload bundle
scripts/ukernel build --release   # Release build
scripts/ukernel pack              # Create bootable rootfs image in dist/
scripts/ukernel run               # Boot in Firecracker (requires env vars)
scripts/ukernel logs              # View console output
scripts/ukernel adapter           # Run Python adapter locally for testing
```

## Remote Development

Firecracker requires Linux with KVM. For development on macOS, use the remote development setup to run on a Linux VM.

### Setup

1. Create `.remote` file with your remote host:
   ```bash
   ZIGU_REMOTE=user@hostname
   ZIGU_REMOTE_DIR=/path/to/zigu
   ```

2. Run initial setup on the remote (installs Zig, Firecracker, configures KVM/TAP):
   ```bash
   ./scripts/remote setup
   ```

3. Start file sync with Mutagen:
   ```bash
   ./scripts/remote sync-start
   ```

### Commands

```bash
./scripts/remote shell          # SSH into remote project directory
./scripts/remote build          # Run zig build on remote
./scripts/remote test           # Run zig build test on remote
./scripts/remote run            # Boot kernel in Firecracker
./scripts/remote logs           # View Firecracker console output
./scripts/remote ukernel <cmd>  # Run any ukernel subcommand
./scripts/remote exec <cmd>     # Run arbitrary command on remote
./scripts/remote sync-status    # Check Mutagen sync status
./scripts/remote sync-stop      # Stop file sync
```

### Requirements

- Remote: Linux x86_64 or aarch64 with KVM support
- Local: [Mutagen](https://mutagen.io/) for file sync (`brew install mutagen-io/mutagen/mutagen`)

## Architecture

### Layers

1. **Kernel** (`kernel/`): Zig freestanding kernel targeting x86_64
   - `main.zig`: Entry point, capability policy setup, workload invocation
   - `abi.zig`: Full ABI implementation with capability system
   - `serial.zig`: Serial console output
   - `workload.zig`: Workload dispatch
   - `linker.ld`: Custom linker script for kernel layout

2. **ABI Surface** (`include/ukernel_abi.h`, `kernel/abi.zig`): C-compatible interface
   - Capability-gated access (CAP_LOG, CAP_TIME, CAP_TASK, CAP_IO, CAP_NET, etc.)
   - Handle-based resource management with generation counters
   - Async I/O via `io_poll`

3. **Python Adapter** (`adapter/python-3.12/`): Maps Python asyncio to kernel ABI
   - `runtime.py`: Entry point, installs custom event loop policy
   - `ukernel_abi.py`: ctypes bindings to kernel ABI functions
   - Custom selector that delegates to `io_poll`

### Capability Model

Workloads start with no active capabilities. They must:
1. `cap_acquire(kind)` to get a capability handle
2. `cap_enter(handles, count)` to activate capabilities
3. Operations check `active_mask` and return `ERR_PERMISSION` if capability not active

Policies are set per-workload in `kernel/main.zig:policies`.

### Key Files

- `ukernel.toml`: Project config (entry point, runtime, VM settings)
- `docs/kernel-abi.md`: Full ABI specification
- `docs/mvp-architecture.md`: System architecture overview
- `tests/kernel/abi_smoke.c`: C smoke test for ABI
