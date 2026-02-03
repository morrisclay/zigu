# Cloud µKernel ABI (Draft v0.2)

This document defines the initial ABI surface for the Cloud µKernel guest. The goal is a tiny, explicit, language-agnostic interface that supports async workloads and adapter runtimes (Python/Go/TS), while enabling native Rust/Zig paths later.

## Design goals

- Small, stable surface area with explicit capabilities.
- Async-first, event-driven I/O.
- Deterministic memory behavior and predictable latency.
- Language-neutral ABI with a C-compatible layer.
- Forward-compatible versioning and feature negotiation.

## ABI form

- **Primary ABI:** C-compatible functions with opaque handles and fixed-width integers.
- **Calling convention:** platform-default C ABI.
- **Error model:** integer error codes; optional extended error info via `err.get_last()`.
- **Versioning:** `abi.version()` returns semantic version (major, minor, patch).
- **Feature negotiation:** `abi.features()` returns a bitset of optional features.
- **Python adapter:** see `docs/python-adapter.md` for the initial ctypes bridge and
  `asyncio` mapping plan.

## Type system (C-style)

```c
typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef unsigned long long u64;
typedef signed int         i32;
typedef signed long long   i64;
typedef unsigned long long size_t;
typedef unsigned long long time_ns;
typedef unsigned long long handle_t;
typedef unsigned long long ptr_t;
typedef u32                result_t;
```

## Handle model

- `handle_t` is opaque, 64-bit.
- Upper 8 bits encode a type tag; lower bits are an index or pointer.
- All functions validate handle type tag and ownership.

Type tags (initial):

- `HANDLE_TASK = 0x01`
- `HANDLE_IO = 0x02`
- `HANDLE_IPC = 0x03`
- `HANDLE_NET = 0x04`
- `HANDLE_CAP = 0x05`
- `HANDLE_SPAN = 0x06`

## Error model

- `result_t == 0` means success.
- Non-zero values are errors.
- `err.get_last()` returns an extended error struct (optional).

Error codes (initial):

- `OK = 0`
- `ERR_INVALID = 1`
- `ERR_NOENT = 2`
- `ERR_NOMEM = 3`
- `ERR_BUSY = 4`
- `ERR_TIMEOUT = 5`
- `ERR_IO = 6`
- `ERR_UNSUPPORTED = 7`
- `ERR_PERMISSION = 8`
- `ERR_WOULD_BLOCK = 9`
- `ERR_CLOSED = 10`

Extended error (optional):

```c
typedef struct {
  result_t code;
  u32      detail;
  u64      arg0;
  u64      arg1;
} err_info_t;
```

## Feature flags

- `FEAT_VSOCK = 1 << 0`
- `FEAT_RNG = 1 << 1`
- `FEAT_BALLOON = 1 << 2`
- `FEAT_SNAPSHOT = 1 << 3`
- `FEAT_TRACING = 1 << 4`

## Capability model

- Kernel resources are accessed via explicit capabilities.
- `cap_t` is an opaque handle; acquisition is explicit via `cap.acquire`.
- Caps can be passed to child tasks at spawn.

Capability API (initial):

```c
result_t cap_acquire(u32 kind, handle_t* handle_out);
result_t cap_drop(handle_t cap);
result_t cap_enter(handle_t* caps, u32 cap_count);
result_t cap_exit(void);
```

`cap_enter` activates a set of capabilities for the current execution context.
Calls that require capabilities return `ERR_PERMISSION` unless the relevant cap
is active.

Capability policy:

- The kernel defines which capability kinds are acquirable.
- `cap_acquire` returns `ERR_PERMISSION` if the policy forbids the kind.
- Workloads start with an empty active cap set.

Capability kinds:

- `CAP_LOG = 1`
- `CAP_TIME = 2`
- `CAP_TASK = 3`
- `CAP_MEM = 4`
- `CAP_IO = 5`
- `CAP_IPC = 6`
- `CAP_NET = 7`
- `CAP_TRACE = 8`

Capability lifecycle:

- Each capability kind has a generation counter.
- Dropped caps invalidate older handles for that kind.
- `cap_enter` fails if the handle generation is stale.

Capability inheritance:

- `task_spawn` validates that requested caps are a subset of the caller's
  active capabilities.

## ABI namespaces

### 1) ABI

```c
result_t abi_version(u32* major, u32* minor, u32* patch);
result_t abi_features(u64* bitset_out);
result_t abi_feature_enabled(u32 feature_id, u32* enabled_out);
```

### 2) Capabilities

```c
result_t cap_acquire(u32 kind, handle_t* handle_out);
result_t cap_drop(handle_t cap);
result_t cap_enter(handle_t* caps, u32 cap_count);
result_t cap_exit(void);
```

### 3) Task + Scheduler

```c
result_t task_spawn(ptr_t entry_ptr, ptr_t arg_ptr,
                    handle_t* caps, u32 cap_count,
                    u32 flags, handle_t* handle_out);
result_t task_yield(void);
result_t task_sleep(time_ns duration);
result_t task_set_priority(handle_t task, u32 priority);
result_t task_get_stats(handle_t task, ptr_t stats_out);
result_t task_exit(i32 code);
```

Task flags:

- `TASK_DETACHED`
- `TASK_PINNED`

Scheduling modes (runtime configurable):

- `SCHED_LATENCY`
- `SCHED_THROUGHPUT`
- `SCHED_ENERGY`

Task stats:

```c
typedef struct {
  u64 cpu_time_ns;
  u64 sched_ticks;
  u64 context_switches;
} task_stats_t;
```

### 3) Time

```c
result_t time_now(time_ns* out);
result_t time_deadline(time_ns abs, handle_t* handle_out);
```

### 4) Memory

```c
result_t mem_alloc(size_t bytes, u32 flags, ptr_t* out_ptr);
result_t mem_free(ptr_t ptr);
result_t mem_map(ptr_t ptr, size_t bytes, u32 flags);
result_t mem_share(ptr_t ptr, size_t bytes, handle_t* handle_out);
result_t mem_unshare(handle_t shared);
```

Memory flags:

- `MEM_READ`, `MEM_WRITE`, `MEM_EXEC`, `MEM_ZEROED`, `MEM_PINNED`

### 5) I/O

```c
result_t io_open(ptr_t path_ptr, u32 flags, handle_t* handle_out);
result_t io_read(handle_t io, ptr_t buf_ptr, size_t len, size_t* read_out);
result_t io_write(handle_t io, ptr_t buf_ptr, size_t len, size_t* wrote_out);
result_t io_close(handle_t io);
result_t io_poll(handle_t* handles, u32 count, time_ns timeout,
                 ptr_t events_out, u32* count_out);
```

I/O flags:

- `IO_READABLE`, `IO_WRITABLE`, `IO_HANGUP`, `IO_ERROR`

I/O event struct:

```c
typedef struct {
  handle_t handle;
  u32      events;
  u32      reserved;
} io_event_t;
```

### 6) IPC

```c
result_t ipc_channel_create(u32 flags, handle_t* handle_out);
result_t ipc_send(handle_t ch, ptr_t buf_ptr, size_t len, u32 flags);
result_t ipc_recv(handle_t ch, ptr_t buf_ptr, size_t len, size_t* read_out, u32 flags);
result_t ipc_close(handle_t ch);
```

### 7) Networking

```c
result_t net_socket(u32 domain, u32 type, u32 protocol, handle_t* handle_out);
result_t net_bind(handle_t sock, ptr_t addr_ptr, u32 addr_len);
result_t net_connect(handle_t sock, ptr_t addr_ptr, u32 addr_len);
result_t net_send(handle_t sock, ptr_t buf_ptr, size_t len, u32 flags, size_t* wrote_out);
result_t net_recv(handle_t sock, ptr_t buf_ptr, size_t len, u32 flags, size_t* read_out);
result_t net_close(handle_t sock);
```

Minimal network address types:

```c
typedef struct {
  u32 ip4;
  u16 port;
  u16 reserved;
} net_addr_v4_t;
```

### 8) Observability

```c
result_t log_write(u32 level, ptr_t msg_ptr, size_t len);
result_t trace_span_begin(ptr_t name_ptr, size_t name_len, handle_t* span_out);
result_t trace_span_end(handle_t span);
result_t trace_event(handle_t span, ptr_t name_ptr, size_t name_len, ptr_t kv_ptr, size_t kv_len);
```

Log levels:

- `LOG_DEBUG`, `LOG_INFO`, `LOG_WARN`, `LOG_ERROR`

## Blocking and async behavior

- All I/O calls can return `ERR_WOULD_BLOCK` if used in non-blocking mode.
- `io_poll` is the primary async primitive; adapter runtimes map their loop onto it.

## Versioning and stability

- Breaking changes bump major version.
- Feature flags enable optional extensions without ABI breaks.
- Each handle type encodes a type tag for validation.

## Adapter runtime considerations

- Python adapter maps `asyncio` loop to `io_poll`.
- Go adapter provides custom netpoll hooks and task scheduling integration.
- TS adapter uses embedded runtime (Deno or V8) with native bindings.

## Open questions

- Is `io_open` path-based or purely capability-based?
- Do we require async-only APIs, or allow synchronous fallbacks?
- What is the minimum networking surface for worker + streaming workloads?
