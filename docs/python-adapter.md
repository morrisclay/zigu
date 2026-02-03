# Python Adapter Runtime (Draft v0.1)

This document defines the minimal Python adapter runtime for the Cloud µKernel.
It focuses on a tiny, explicit ABI bridge and a first-pass `asyncio` mapping
using `io_poll`.

## Goals

- Provide a minimal, deterministic way for Python to call the µKernel ABI.
- Keep the bridge simple (ctypes + a small shared library or direct ABI export).
- Enable an `asyncio` event loop to block on `io_poll`.

## Non-Goals (for now)

- Full CPython embedding in the kernel.
- Advanced I/O adapters (files, sockets, IPC) beyond stubs.
- Performance tuning or zero-copy pathways.

## Architecture Summary

The Python adapter is a user-space runtime that:

- Loads `ukernel.toml` from the bundle.
- Resolves the `project.entry` path (default `src/main.py`).
- Initializes the ABI bridge.
- Starts Python and runs the entrypoint.
- Hooks `asyncio` to `io_poll` for idle waits.

## ABI Bridge Options

We will start with **ctypes** as the simplest path:

- The ABI surface is exposed by a thin C shared library (`libukernel_abi.so`).
- Python loads the library via `ctypes.CDLL`.
- Each ABI function is bound with argument/return types.

If we need more control later, we can switch to **cffi** or a CPython extension
module, but ctypes is sufficient for M3.

## Proposed ABI Binding (ctypes)

Minimal bindings needed for M3:

- `cap_acquire`, `cap_enter`, `cap_exit`
- `log_write`
- `time_now`
- `io_poll`

Mapping sketch:

```python
lib = ctypes.CDLL("libukernel_abi.so")
lib.log_write.argtypes = [ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint64]
lib.log_write.restype = ctypes.c_uint32
```

## Entry Resolution

We will parse `ukernel.toml` and read:

- `[project] entry = "src/main.py"`

Rules:

- If `entry` is missing, default to `src/main.py`.
- The adapter logs the resolved entry path before executing it.

## `asyncio` Integration

Minimal integration strategy:

1. Define a custom `asyncio` event loop policy (or a loop subclass).
2. Override the idle wait phase to call `io_poll` with a timeout.
3. Map `io_poll` timeout to `select`-style blocking.

Pseudo-flow:

```
timeout = loop._get_next_ready_time()
io_poll(handles, count, timeout_ns)
```

For M3, the handles list can be empty; we use `io_poll` primarily as a
deadline-aware sleep.

## Logging & Observability

The adapter should log:

- resolved entrypoint
- Python version
- `asyncio` policy active

This is best-effort and uses `log_write`.

## Minimal Milestone Checklist

- [ ] `docs/python-adapter.md` authored
- [ ] `libukernel_abi.so` exposed in adapter runtime
- [ ] `src/main.py` is executed from bundle
- [ ] `asyncio` loop calls `io_poll` in idle waits

