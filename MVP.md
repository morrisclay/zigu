# MVP Scope and Milestones (Draft)

## Goals
- Boot the Cloud µKernel inside Firecracker with serial logs.
- Run a real async worker workload (Python first).
- Provide a deterministic build/pack/run flow via `ukernel` CLI.
- Keep the ABI surface minimal and explicit.

## Non-goals (MVP)
- Multi-tenant scheduling or isolation features.
- Multiple runtime adapters (Python only).
- Remote deploy or CI/CD integration.
- Advanced devices (vsock, rng, balloon).

## Acceptance Criteria
- `ukernel build` produces `build/bundle.tgz` for the workload.
- `ukernel pack` produces a bootable guest image in `dist/`.
- `ukernel run` boots Firecracker and writes serial logs to `logs/console.log`.
- Guest starts the workload entrypoint and logs a heartbeat.
- ABI functions in `include/ukernel_abi.h` compile cleanly with the adapter.

## Milestones
- M1: Bootable µKernel with serial logs in Firecracker.
- M2: Async worker demo with basic IPC and networking.
- M3: Python adapter runtime with `asyncio` mapped to `io_poll`.
- M4: CLI pipeline: `init`, `build`, `pack`, `run`, `logs`.

## Risks and Mitigations
- Runtime adapter complexity: implement Python only and keep adapters thin.
- Virtio drivers scope: start with net + block + serial only.
- Scope creep: only ship commands listed in the acceptance criteria.
