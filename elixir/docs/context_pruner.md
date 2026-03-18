# Context Pruner CLI

Symphony now ships a direct shell-facing `context-pruner` launcher for the
common `read`, `grep`, and `bash` context-gathering flows.

This implementation is intentionally small. It adapts the useful behavior and
HTTP prune contract from the Jeeves reference work under:

- `/work/jeeves/docs/mcp-pruner-cli-report.md`
- `/work/jeeves/packages/mcp-pruner/src/pruner.ts`
- `/work/jeeves/packages/mcp-pruner/src/platform.ts`
- `/work/jeeves/packages/mcp-pruner/src/tools/read.ts`
- `/work/jeeves/packages/mcp-pruner/src/tools/bash.ts`
- `/work/jeeves/packages/mcp-pruner/src/tools/grep.ts`

Symphony does not depend on the Jeeves repo at runtime. The code lives entirely
in this repository under:

- `context-pruner`
- `elixir/lib/symphony_elixir/context_pruner/*`

## Workspace availability

The checked-in `elixir/WORKFLOW.md` bootstrap now:

1. clones the repo into the fresh workspace
2. copies the launcher to `~/.local/bin/context-pruner`
3. prepends `~/.local/bin` to the Codex PATH

That makes `context-pruner` directly callable from agent shells inside fresh
Symphony workspaces created by the default `after_create` flow.

## Commands

```bash
context-pruner read --file-path path/to/file.ex --start-line 10 --end-line 30
context-pruner read --file-path path/to/file.ex --around-line 120 --radius 12
context-pruner grep --pattern "context-pruner" --path elixir/lib --context-lines 2 --max-matches 40
context-pruner bash --command "git status --short"
```

Add `--focus "<question>"` to any command to request remote pruning before the
content enters model context.

## Pruner environment contract

Primary variables:

- `PRUNER_URL`
- `PRUNER_TIMEOUT_MS`

Compatibility alias:

- `JEEVES_PRUNER_URL` is accepted only when `PRUNER_URL` is unset.

Timeout defaults to `30000` ms and is clamped to `100..300000`.

If pruning is disabled or the remote call fails, the CLI falls back to the
original unpruned output and emits a warning on stderr.

## Verified request and response shape

Verified on 2026-03-18 against the remote service referenced in
`/work/jeeves/.env`:

- endpoint: `http://192.168.1.15:8000/prune`
- request body: `{ "code": "...", "query": "..." }`
- primary response field: `pruned_code`

Symphony also accepts `content` or `text` as compatibility fallbacks, but the
documented primary contract is `pruned_code`.

## Exit codes

- `read`: `0` success, `1` file/runtime failure, `2` invalid CLI arguments
- `grep`: `0` matches found, `1` no matches, `2` invalid regex or filesystem/runtime failure
- `bash`: child exit code when the command runs, `1` launcher/runtime failure, `2` invalid CLI arguments, `127` no usable shell
