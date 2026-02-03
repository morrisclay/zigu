# Implementation Plan (Detailed)

This plan consolidates the MVP scope, architecture, ABI, DX blueprint, and Firecracker integration documents into an executable sequence. It is organized by milestones with concrete tasks and deliverables.

## Status Legend
- TODO: not started
- IN PROGRESS: active work
- DONE: completed

## M1: Bootable µKernel With Serial Logs In Firecracker
Status: IN PROGRESS (kernel/logging ready; full Firecracker boot not yet verified)

1. Kernel boot path (Zig freestanding)
- Task: keep `_start` minimal and deterministic (serial init, caps reset, workload call)
- Deliverable: `kernel/main.zig` boots and prints at least one line to serial
- Status: DONE

2. Serial driver (COM1)
- Task: basic init + polling TX
- Deliverable: `kernel/serial.zig` supports `writeByte` and `writeAll`
- Status: DONE

3. ABI stubs + capability gating (log/time/task)
- Task: implement core ABI stubs with `ERR_UNSUPPORTED` for non-MVP functions
- Task: enforce cap policy and active caps
- Deliverable: `kernel/abi.zig` compiles and passes tests
- Status: DONE

4. Workload entry and heartbeat
- Task: workload acquires caps, logs, yields, and emits heartbeat loop
- Deliverable: serial output includes repeated heartbeat lines
- Status: DONE

5. Firecracker run helper
- Task: local script to boot Firecracker with kernel/rootfs and serial logs
- Deliverable: `scripts/run_fc.sh`
- Status: DONE

6. CLI real run wiring
- Task: allow `ukernel run` to invoke Firecracker when env vars are provided
- Deliverable: `ukernel run` uses `scripts/run_fc.sh` when `UKERNEL_FIRECRACKER`, `UKERNEL_KERNEL`, `UKERNEL_ROOTFS` are set
- Status: DONE

7. Real run flag
- Task: add explicit `--real` flag to `ukernel run`
- Deliverable: `ukernel run --real` requires env vars and runs Firecracker
- Status: DONE

## M2: Async Worker Demo With Basic IPC And Networking
Status: IN PROGRESS (scaffolding in place; no real async demo yet)

1. Minimal IPC scaffolding
- Task: define IPC handle table and placeholder channel state
- Task: `ipc_channel_create`, `ipc_send`, `ipc_recv`, `ipc_close` return meaningful errors or stub events
- Deliverable: IPC calls no longer `ERR_UNSUPPORTED` for basic channel lifecycle
- Status: DONE

2. Minimal net scaffolding
- Task: define socket handle table and placeholder socket state
- Task: `net_socket`, `net_bind`, `net_connect`, `net_send`, `net_recv`, `net_close` return meaningful errors or stub events
- Deliverable: networking calls no longer `ERR_UNSUPPORTED` for basic socket lifecycle
- Status: DONE

3. Async worker loop integration
- Task: expose a simple event loop primitive via `io_poll` (even if stubbed to wake periodically)
- Deliverable: an async worker-like loop runs with periodic ticks
- Status: DONE (io_poll stub w/ timeout)

4. Observability
- Task: add structured log prefix for workload events (task id or capability mask)
- Deliverable: serial logs show readable event stream
- Status: DONE

5. IO handle scaffolding
- Task: implement handle table and lifecycle for `io_open/io_read/io_write/io_close`
- Deliverable: basic IO calls return meaningful results (no longer `ERR_UNSUPPORTED`)
- Status: DONE

## M3: Python Adapter Runtime With `asyncio` Mapping

1. Adapter runtime stub
- Task: define adapter build directory and metadata file
- Deliverable: `build/adapter/python-3.12` includes minimal runtime metadata
- Status: DONE (placeholder)

2. Adapter ABI bridge plan
- Task: define how Python runtime will call ABI functions (C-FFI or embedded)
- Deliverable: design doc section in `docs/kernel-abi.md` or new `docs/python-adapter.md`
- Status: TODO

3. Bundle load + entrypoint
- Task: define guest-side load of `src/main.py` from rootfs/bundle
- Deliverable: runtime resolves entrypoint and starts Python main
- Status: IN PROGRESS (stub announcement + adapter metadata emitted on build + generated entrypoint constant)

4. `asyncio` event loop mapping
- Task: map `asyncio` selectors to `io_poll`
- Deliverable: a Python async worker runs and uses `io_poll`
- Status: TODO

## M4: CLI Pipeline For Build/Pack/Run/Logs
Status: DONE (simulated outputs; not yet wired to real Firecracker runs)

1. `ukernel init`
- Task: generate `ukernel.toml`, `src/main.py`, `env/ukernel.env`
- Deliverable: `scripts/ukernel` init command
- Status: DONE

2. `ukernel build`
- Task: produce `build/bundle.tgz` and adapter placeholder
- Deliverable: `scripts/ukernel` build command
- Status: DONE

3. `ukernel pack`
- Task: create `dist/<name>.img` placeholder
- Deliverable: `scripts/ukernel` pack command
- Status: DONE

4. `ukernel run`
- Task: emit simulated Firecracker logs to `logs/console.log`
- Deliverable: `scripts/ukernel` run command
- Status: DONE

5. `ukernel logs`
- Task: tail or show recent console logs
- Deliverable: `scripts/ukernel` logs command
- Status: DONE

## Cross-Cutting Tasks

1. ABI header alignment
- Task: keep `include/ukernel_abi.h` and `kernel/abi.zig` signatures in sync
- Deliverable: `tests/kernel/abi_smoke.c` compiles
- Status: DONE

2. Build/test workflow
- Task: ensure `zig build` and `zig build test` work
- Deliverable: `build.zig` wires tests and kernel binary
- Status: DONE

3. Documentation alignment
- Task: update docs when ABI or CLI changes
- Deliverable: all docs reflect actual behavior
- Status: TODO

## Immediate Next Steps (Proposed)

1. Implement basic handle tables for IPC and networking in `kernel/abi.zig` and return non-`ERR_UNSUPPORTED` results for lifecycle calls.
2. Add a minimal `io_poll` stub that can wake after a deadline or yield count.
3. Write a tiny guest-side adapter loader stub to formalize how `src/main.py` would be found and invoked.
