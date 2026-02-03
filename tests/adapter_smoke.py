import os
import subprocess
import sys
import tempfile


def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    runtime_py = os.path.join(repo_root, "adapter", "python-3.12", "runtime.py")
    if not os.path.exists(runtime_py):
        print("Missing adapter runtime.", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        src_dir = os.path.join(tmp, "src")
        os.makedirs(src_dir, exist_ok=True)

        entry_path = os.path.join(src_dir, "hello.py")
        with open(entry_path, "w", encoding="utf-8") as f:
            f.write("print('hello from adapter')\n")

        toml_path = os.path.join(tmp, "ukernel.toml")
        with open(toml_path, "w", encoding="utf-8") as f:
            f.write(
                "[project]\n"
                'name = "adapter-smoke"\n'
                'entry = "src/hello.py"\n'
            )

        env = os.environ.copy()
        env["UKERNEL_ROOT"] = tmp

        res = subprocess.run(
            [sys.executable, runtime_py],
            env=env,
            capture_output=True,
            text=True,
        )

        output = res.stdout + res.stderr
        if res.returncode != 0:
            print(output, file=sys.stderr)
            return res.returncode
        if "adapter: entrypoint src/hello.py (python)" not in output:
            print("Missing adapter entry log.", file=sys.stderr)
            print(output, file=sys.stderr)
            return 1
        if "hello from adapter" not in output:
            print("Missing entry output.", file=sys.stderr)
            print(output, file=sys.stderr)
            return 1

    print("adapter smoke: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

