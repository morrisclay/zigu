import ctypes
import os


OK = 0
ERR_INVALID = 1
ERR_NOENT = 2
ERR_NOMEM = 3
ERR_BUSY = 4
ERR_TIMEOUT = 5
ERR_IO = 6
ERR_UNSUPPORTED = 7
ERR_PERMISSION = 8
ERR_WOULD_BLOCK = 9
ERR_CLOSED = 10

CAP_LOG = 1
CAP_TIME = 2
CAP_TASK = 3
CAP_MEM = 4
CAP_IO = 5
CAP_IPC = 6
CAP_NET = 7
CAP_TRACE = 8


class UkernelAbi:
    def __init__(self, lib_path=None):
        self._lib = None
        self.available = False
        self.error = None
        self._load(lib_path)

    def _load(self, lib_path):
        search = []
        if lib_path:
            search.append(lib_path)
        env_path = os.environ.get("UKERNEL_ABI_PATH")
        if env_path:
            search.append(env_path)
        local_dir = os.path.dirname(os.path.abspath(__file__))
        search.append(os.path.join(local_dir, "libukernel_abi.so"))

        for path in search:
            try:
                lib = ctypes.CDLL(path)
            except OSError as exc:
                self.error = str(exc)
                continue

            self._lib = lib
            self._bind()
            self.available = True
            self.error = None
            return

        self.available = False

    def _bind(self):
        lib = self._lib
        lib.cap_acquire.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint64)]
        lib.cap_acquire.restype = ctypes.c_uint32

        lib.cap_enter.argtypes = [ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32]
        lib.cap_enter.restype = ctypes.c_uint32

        lib.cap_exit.argtypes = []
        lib.cap_exit.restype = ctypes.c_uint32

        lib.log_write.argtypes = [ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint64]
        lib.log_write.restype = ctypes.c_uint32

        lib.time_now.argtypes = [ctypes.POINTER(ctypes.c_uint64)]
        lib.time_now.restype = ctypes.c_uint32

        lib.io_poll.argtypes = [
            ctypes.POINTER(ctypes.c_uint64),
            ctypes.c_uint32,
            ctypes.c_uint64,
            ctypes.c_uint64,
            ctypes.POINTER(ctypes.c_uint32),
        ]
        lib.io_poll.restype = ctypes.c_uint32

    def cap_acquire(self, kind):
        if not self.available:
            return ERR_UNSUPPORTED, None
        out = ctypes.c_uint64(0)
        res = self._lib.cap_acquire(ctypes.c_uint32(kind), ctypes.byref(out))
        return res, out.value

    def cap_enter(self, caps):
        if not self.available:
            return ERR_UNSUPPORTED
        arr = (ctypes.c_uint64 * len(caps))(*caps)
        return self._lib.cap_enter(arr, ctypes.c_uint32(len(caps)))

    def cap_exit(self):
        if not self.available:
            return ERR_UNSUPPORTED
        return self._lib.cap_exit()

    def log_write(self, msg, level=0):
        if not self.available:
            return ERR_UNSUPPORTED
        if isinstance(msg, str):
            data = msg.encode("utf-8")
        else:
            data = bytes(msg)
        buf = ctypes.create_string_buffer(data)
        ptr = ctypes.cast(buf, ctypes.c_void_p).value or 0
        return self._lib.log_write(
            ctypes.c_uint32(level),
            ctypes.c_uint64(ptr),
            ctypes.c_uint64(len(data)),
        )

    def time_now(self):
        if not self.available:
            return ERR_UNSUPPORTED, 0
        out = ctypes.c_uint64(0)
        res = self._lib.time_now(ctypes.byref(out))
        return res, out.value

    def io_poll(self, timeout_ns):
        if not self.available:
            return ERR_UNSUPPORTED
        count_out = ctypes.c_uint32(0)
        return self._lib.io_poll(
            None,
            ctypes.c_uint32(0),
            ctypes.c_uint64(timeout_ns),
            ctypes.c_uint64(0),
            ctypes.byref(count_out),
        )

