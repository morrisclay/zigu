#include "ukernel_abi.h"

/*
 * ABI smoke test: compile-only sanity check.
 * If signatures change, this file should fail to compile.
 */

static void abi_smoke(void) {
  u32 major = 0, minor = 0, patch = 0;
  u64 features = 0;
  u32 enabled = 0;
  handle_t handle = 0;
  size_t bytes = 0;
  ptr_t ptr = 0;
  time_ns now = 0;

  (void)abi_version(&major, &minor, &patch);
  (void)abi_features(&features);
  (void)abi_feature_enabled(FEAT_TRACING, &enabled);

  (void)task_yield();
  (void)task_sleep(0);
  (void)time_now(&now);
  (void)mem_alloc(bytes, 0, &ptr);
  (void)io_close(handle);
  (void)ipc_close(handle);
  (void)net_close(handle);
  (void)log_write(0, 0, 0);
}

int main(void) {
  abi_smoke();
  return 0;
}
