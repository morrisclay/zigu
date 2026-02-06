#ifndef UKERNEL_ABI_H
#define UKERNEL_ABI_H

#ifdef __cplusplus
extern "C" {
#endif

/* Fixed-width typedefs */
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

/* Error codes */
enum {
  OK = 0,
  ERR_INVALID = 1,
  ERR_NOENT = 2,
  ERR_NOMEM = 3,
  ERR_BUSY = 4,
  ERR_TIMEOUT = 5,
  ERR_IO = 6,
  ERR_UNSUPPORTED = 7,
  ERR_PERMISSION = 8,
  ERR_WOULD_BLOCK = 9,
  ERR_CLOSED = 10
};

/* Feature flags */
enum {
  FEAT_VSOCK = 1 << 0,
  FEAT_RNG = 1 << 1,
  FEAT_BALLOON = 1 << 2,
  FEAT_SNAPSHOT = 1 << 3,
  FEAT_TRACING = 1 << 4
};

/* Capability kinds */
enum {
  CAP_LOG = 1,
  CAP_TIME = 2,
  CAP_TASK = 3,
  CAP_MEM = 4,
  CAP_IO = 5,
  CAP_IPC = 6,
  CAP_NET = 7,
  CAP_TRACE = 8
};

/* Handle tags (upper 8 bits) */
enum {
  HANDLE_TASK = 0x01,
  HANDLE_IO = 0x02,
  HANDLE_IPC = 0x03,
  HANDLE_NET = 0x04,
  HANDLE_CAP = 0x05,
  HANDLE_SPAN = 0x06
};

/* Extended error info (optional) */
typedef struct {
  result_t code;
  u32      detail;
  u64      arg0;
  u64      arg1;
} err_info_t;

/* ABI namespace */
result_t abi_version(u32* major, u32* minor, u32* patch);
result_t abi_features(u64* bitset_out);
result_t abi_feature_enabled(u32 feature_id, u32* enabled_out);

/* Capabilities */
result_t cap_acquire(u32 kind, handle_t* handle_out);
result_t cap_drop(handle_t cap);
result_t cap_enter(handle_t* caps, u32 cap_count);
result_t cap_exit(void);

/* Task + Scheduler */
result_t task_spawn(ptr_t entry_ptr, ptr_t arg_ptr,
                    handle_t* caps, u32 cap_count,
                    u32 flags, handle_t* handle_out);
result_t task_yield(void);
result_t task_sleep(time_ns duration);
result_t task_set_priority(handle_t task, u32 priority);
result_t task_get_stats(handle_t task, ptr_t stats_out);
result_t task_exit(i32 code);

/* Time */
result_t time_now(time_ns* out);
result_t time_deadline(time_ns abs, handle_t* handle_out);

/* Memory */
result_t mem_alloc(size_t bytes, u32 flags, ptr_t* out_ptr);
result_t mem_free(ptr_t ptr);
result_t mem_map(ptr_t ptr, size_t bytes, u32 flags);
result_t mem_share(ptr_t ptr, size_t bytes, handle_t* handle_out);
result_t mem_unshare(handle_t shared);

/* I/O event flags */
#define IO_READABLE 0x01
#define IO_WRITABLE 0x02
#define IO_HANGUP   0x04
#define IO_ERROR    0x08

typedef struct {
    handle_t handle;
    u32      events;
    u32      reserved;
} io_event_t;

/* I/O */
result_t io_open(ptr_t path_ptr, u32 flags, handle_t* handle_out);
result_t io_read(handle_t io, ptr_t buf_ptr, size_t len, size_t* read_out);
result_t io_write(handle_t io, ptr_t buf_ptr, size_t len, size_t* wrote_out);
result_t io_close(handle_t io);
result_t io_poll(handle_t* handles, u32 count, time_ns timeout,
                 ptr_t events_out, u32* count_out);

/* IPC */
result_t ipc_channel_create(u32 flags, handle_t* handle_out);
result_t ipc_send(handle_t ch, ptr_t buf_ptr, size_t len, u32 flags);
result_t ipc_recv(handle_t ch, ptr_t buf_ptr, size_t len, size_t* read_out, u32 flags);
result_t ipc_close(handle_t ch);

/* Networking */
result_t net_socket(u32 domain, u32 type, u32 protocol, handle_t* handle_out);
result_t net_bind(handle_t sock, ptr_t addr_ptr, u32 addr_len);
result_t net_connect(handle_t sock, ptr_t addr_ptr, u32 addr_len);
result_t net_send(handle_t sock, ptr_t buf_ptr, size_t len, u32 flags, size_t* wrote_out);
result_t net_recv(handle_t sock, ptr_t buf_ptr, size_t len, u32 flags, size_t* read_out);
result_t net_close(handle_t sock);

/* Observability */
result_t log_write(u32 level, ptr_t msg_ptr, size_t len);
result_t trace_span_begin(ptr_t name_ptr, size_t name_len, handle_t* span_out);
result_t trace_span_end(handle_t span);
result_t trace_event(handle_t span, ptr_t name_ptr, size_t name_len, ptr_t kv_ptr, size_t kv_len);

#ifdef __cplusplus
}
#endif

#endif /* UKERNEL_ABI_H */
