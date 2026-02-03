# DX Blueprint (Flox-like) (Draft v0.2)

This document defines a developer experience that feels like flox: fast setup, pinned environments, and reproducible builds while targeting the Cloud µKernel.

## Principles

- One command to run locally.
- Environments are deterministic and shareable.
- Same build output runs locally and in production.
- Clear introspection for logs, traces, and performance.

## CLI design (proposed)

### `ukernel init`

Create a new project scaffold.

```text
ukernel init --name example-worker --lang python --template worker
```

Output:

```text
Created ukernel.toml
Created src/main.py
Created env/ukernel.env
```

### `ukernel env`

Manage pinned environments.

```text
ukernel env lock
ukernel env add requests==2.32
ukernel env add --system libssl
ukernel env show
```

Output:

```text
Locked environment: env/ukernel.lock
```

### `ukernel build`

Build workload bundle and adapter runtime.

```text
ukernel build --release
```

Output:

```text
Built workload bundle: build/bundle.tgz
Adapter runtime: build/adapter/python-3.12
```

### `ukernel pack`

Produce a bootable guest image.

```text
ukernel pack --image dist/example-worker.img
```

Output:

```text
Image created: dist/example-worker.img
```

### `ukernel run`

Run locally in Firecracker.

```text
ukernel run --vcpu 1 --memory 256 --net tap:tap0
```

Output:

```text
Firecracker started (pid 12345)
VM console: logs/console.log
```

### `ukernel deploy`

Ship to a remote host (phase 2).

```text
ukernel deploy --host 10.0.0.5 --image dist/example-worker.img
```

### `ukernel inspect`

Show image metadata and ABI versions.

```text
ukernel inspect dist/example-worker.img
```

Output:

```text
Image: dist/example-worker.img
ABI: 0.2.0
Adapter: python-3.12
Size: 46 MB
```

### `ukernel logs`

Tail logs from the guest console.

```text
ukernel logs --follow
```

## Project layout (proposal)

- `ukernel.toml` — project config
- `env/` — pinned environment manifest
- `env/ukernel.lock` — locked environment
- `src/` — workload source
- `build/` — build output (ignored in VCS)
- `dist/` — packaged images (ignored in VCS)
- `logs/` — local run logs

## `ukernel.toml` (sketch)

```toml
[project]
name = "example-worker"
language = "python"
entry = "src/main.py"

[env]
base = "python-3.12"

[build]
adapter = "python"

[run]
vcpu = 1
memory_mb = 256
net = "tap"
```

## Command flags (initial)

- `ukernel build`
  - `--release` for optimized build
  - `--target` to override adapter target

- `ukernel run`
  - `--vcpu N`
  - `--memory MB`
  - `--net tap:IFACE`
  - `--image PATH`

- `ukernel pack`
  - `--image PATH`
  - `--readonly` to force immutable image

## Environment model

- Env is pinned (runtime + deps) and stored in `env/`.
- `ukernel env lock` creates a deterministic lockfile.
- Optional per-project cache for fast rebuilds.

## Adapter toolchain

- Adapter runtimes are versioned artifacts.
- `ukernel build` pulls or builds the adapter runtime for the project.

## Local run flow

1. Build workload bundle.
2. Assemble guest image.
3. Launch Firecracker.
4. Tail logs + traces from console.

## Observability

- `ukernel logs` for console output.
- `ukernel trace` for spans + events.
- `ukernel perf` for cold-start timing and IO latency.

## Future extensions

- `ukernel shell` to open a guest debug session.
- `ukernel diff` for comparing images and envs.
- Remote cache for CI/CD.

