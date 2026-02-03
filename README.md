# Cloud µKernel MVP

This repo contains the early MVP for a Cloud µKernel guest designed to run on Firecracker with a minimal ABI and a flox-like developer experience.

## Quickstart (Agent Primer)

### 1) Key docs
- `MVP.md` for scope, milestones, and acceptance criteria
- `docs/mvp-architecture.md` for the system overview
- `docs/kernel-abi.md` for ABI surface and semantics
- `docs/firecracker-integration.md` for VMM configuration
- `docs/dx-blueprint.md` for CLI and workflow intent

### 2) Important assets
- ABI header: `include/ukernel_abi.h`
- ABI smoke test: `tests/kernel/abi_smoke.c`
- Firecracker helper: `scripts/run_fc.sh`
- Golden workload: `src/main.py`

### 3) Suggested early steps
1. Implement ABI functions in the µKernel and keep signatures aligned with `include/ukernel_abi.h`.
2. Get a serial log to print from the guest (M1).
3. Boot the guest in Firecracker and capture `logs/console.log`.
4. Wire the Python adapter to run `src/main.py` and log heartbeats.

## Local notes
- `scripts/run_fc.sh` expects Firecracker, kernel image, and rootfs image paths.
- Output logs should land in `logs/console.log`.

## Real Firecracker run (optional)
Use `ukernel run --real` to invoke Firecracker via `scripts/run_fc.sh`.
Set the required environment variables first:

```text
export UKERNEL_FIRECRACKER=/path/to/firecracker
export UKERNEL_KERNEL=/path/to/vmlinux
export UKERNEL_ROOTFS=/path/to/rootfs.ext4
export UKERNEL_TAP=tap0
```

Then run:

```text
scripts/ukernel run --real
```

## Repo layout (current)
- `docs/` specs and architecture references
- `include/` ABI contract headers
- `scripts/` local tools
- `src/` workload sources
- `tests/` test skeletons
- `build/`, `dist/`, `logs/` build/run outputs
