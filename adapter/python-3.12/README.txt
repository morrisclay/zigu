Python adapter runtime (stub)

Files:
- runtime.py: loads ukernel.toml, resolves entrypoint, installs asyncio policy
- ukernel_abi.py: ctypes bridge to libukernel_abi.so
- __main__.py: module entrypoint

Expected shared library:
- libukernel_abi.so in the same directory or set UKERNEL_ABI_PATH

