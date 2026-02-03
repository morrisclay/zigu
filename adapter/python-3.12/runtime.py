import asyncio
import os
import runpy
import selectors
import sys
import time
try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover
    try:
        import tomli as tomllib  # type: ignore
    except ModuleNotFoundError:  # pragma: no cover
        tomllib = None

from ukernel_abi import CAP_LOG, UkernelAbi, OK


class UkernelSelector(selectors.BaseSelector):
    def __init__(self, abi):
        super().__init__()
        self._abi = abi
        self._base = selectors.DefaultSelector()

    def register(self, fileobj, events, data=None):
        return self._base.register(fileobj, events, data)

    def unregister(self, fileobj):
        return self._base.unregister(fileobj)

    def modify(self, fileobj, events, data=None):
        return self._base.modify(fileobj, events, data)

    def select(self, timeout=None):
        if self.get_map() and len(self.get_map()) > 0:
            return self._base.select(timeout)

        if timeout is None:
            timeout_ns = 1_000_000_000
        else:
            timeout_ns = max(0, int(timeout * 1_000_000_000))

        if self._abi and self._abi.available:
            self._abi.io_poll(timeout_ns)
        else:
            time.sleep(timeout or 0)

        return []

    def close(self):
        return self._base.close()

    def get_map(self):
        return self._base.get_map()


class UkernelEventLoopPolicy(asyncio.DefaultEventLoopPolicy):
    def __init__(self, abi):
        super().__init__()
        self._abi = abi

    def new_event_loop(self):
        selector = UkernelSelector(self._abi)
        return asyncio.SelectorEventLoop(selector)


def _read_config(root):
    path = os.path.join(root, "ukernel.toml")
    with open(path, "rb") as f:
        data = f.read()
    if tomllib is not None:
        return tomllib.loads(data)
    return _parse_toml_min(data.decode("utf-8", errors="replace"))


def _parse_toml_min(text):
    project = {}
    in_project = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            in_project = stripped == "[project]"
            continue
        if not in_project:
            continue
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        project[key] = value
    return {"project": project}


def _resolve_entry(cfg):
    override = os.environ.get("UKERNEL_ENTRY")
    if override:
        return override
    project = cfg.get("project", {})
    return project.get("entry") or "src/main.py"


def _log(abi, msg):
    if abi and abi.available:
        res = abi.log_write(msg)
        if res == OK:
            return
    sys.stdout.write(msg)


def _enable_caps(abi):
    if not abi or not abi.available:
        return
    _ = abi.cap_exit()
    res, cap = abi.cap_acquire(CAP_LOG)
    if res == OK:
        _ = abi.cap_enter([cap])


def main():
    root = os.environ.get("UKERNEL_ROOT") or os.getcwd()
    cfg = _read_config(root)
    entry = _resolve_entry(cfg)
    entry_path = os.path.join(root, entry)

    sys.path.insert(0, root)
    src_dir = os.path.join(root, "src")
    if os.path.isdir(src_dir):
        sys.path.insert(0, src_dir)

    abi = UkernelAbi()
    _enable_caps(abi)
    _log(abi, f"adapter: entrypoint {entry} (python)\n")
    asyncio.set_event_loop_policy(UkernelEventLoopPolicy(abi))

    runpy.run_path(entry_path, run_name="__main__")


if __name__ == "__main__":
    main()
