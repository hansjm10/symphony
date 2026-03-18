# Symphony Rust

This directory contains a Rust implementation of Symphony based on the repository root
[`SPEC.md`](../SPEC.md).

## Status

This implementation targets the core Symphony service contract:

- `WORKFLOW.md` parsing with YAML front matter + prompt body
- dynamic workflow reloads
- Linear polling and normalization
- workspace management and hooks
- Codex app-server session startup and turn streaming
- orchestration, retries, reconciliation, and optional HTTP observability

## Run

```bash
cd rust
cargo run -- /path/to/WORKFLOW.md
```

Optional flags:

- `--logs-root /path/to/logs`
- `--port 8080`
- `--host 127.0.0.1`
