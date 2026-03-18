# Context Pruner CLI

`context-pruner` exists to keep the main Codex thread lean.

It is a lookup-only helper: capture a bounded local source, optionally prune it
with a cheaper backend, and return only the minimum text the main thread needs
next. It is not a full task executor, and the Codex-backed path is explicitly
isolated so it does not inherit hidden parent context.

The supported interface is `context-pruner lookup`. Direct `read`, `grep`, and
`bash` entrypoints remain deprecated compatibility shims only.

## Lookup posture

- start with `context-pruner lookup` before broad `cat`, `sed`, `rg`, or ad hoc
  shell output when the task is repository context discovery
- keep the local selector narrow first, then use `--query` to retain only the
  fields or statements the main thread needs
- treat the returned text as a bounded context handoff to the main thread, not
  as permission for the helper to keep exploring

## Backend selection

`context-pruner lookup` always starts with a bounded local selector and then
dispatches to one backend:

- default backend: `CONTEXT_PRUNER_BACKEND=remote` or unset
  - submits `{ code, query }` to `PRUNER_URL`
  - accepts `JEEVES_PRUNER_URL` only as a compatibility alias when
    `PRUNER_URL` is unset
- optional backend: `CONTEXT_PRUNER_BACKEND=codex`
  - runs a blank-state `codex exec --ephemeral` worker
  - supports alternative low-cost models through `CONTEXT_PRUNER_MODEL`
  - defaults to `gpt-5.3-codex-spark` with `CONTEXT_PRUNER_REASONING_EFFORT=low`
  - uses `CONTEXT_PRUNER_CODEX_BIN` when `codex` is not the correct binary

## Codex isolation contract

The Codex-backed lookup path is intentionally narrower than a normal task
thread.

Passed in:

- the explicit `--query` text
- the bounded selector output and nothing else
- explicit backend config such as model, auth, and scope env

Intentionally not inherited:

- parent Codex session id
- parent workflow prompt or prompt history
- parent repository working directory
- parent `HOME/.codex` config tree, including session history

Execution rules:

- the worker runs from a fresh temporary directory outside the repository
- the worker uses a read-only sandbox
- the worker may not inspect the filesystem beyond the bounded source already
  captured by the local selector
- `--command` sources are disabled for `CONTEXT_PRUNER_BACKEND=codex`
- `--file-path` lookups under the Codex backend require an explicit
  `--start-line/--end-line` or `--around-line/--radius` window

Auth is explicit:

- pass `OPENAI_API_KEY` or related auth env through
  `CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH`, or
- point `CONTEXT_PRUNER_CODEX_AUTH_FILE` at a single `auth.json` file to copy
  into the blank-state home

The backend copies only that auth file when configured. It does not copy the
rest of `.codex`, including sessions or prompt history.

## Scope controls

Codex-backed lookups must stay inside caller-defined read scope.

Supported scope env:

- `CONTEXT_PRUNER_ALLOWED_ROOTS`
- `CONTEXT_PRUNER_ALLOWED_PATHS`
- `CONTEXT_PRUNER_ALLOWED_GLOBS`

Behavior:

- file-window lookups fail if `--file-path` resolves outside the configured
  scope
- grep lookups fail if `--path` resolves outside the configured scope
- grep enumeration is filtered down to allowed files before content is read
- scope applies before the Codex worker is launched, so out-of-scope paths
  never reach the blank-state worker

## Supported lookup flow

Use `lookup` with a required remote query and one bounded source selector:

```bash
context-pruner lookup \
  --query "Keep exactly the statements that define the env contract." \
  --file-path elixir/docs/context_pruner.md \
  --around-line 144 \
  --radius 14

context-pruner lookup \
  --query "Which lines are relevant to the scope allowlist env?" \
  --pattern "CONTEXT_PRUNER_ALLOWED_(ROOTS|PATHS|GLOBS)" \
  --path elixir/lib \
  --context-lines 1 \
  --max-matches 20

context-pruner lookup \
  --query "Keep only the files related to the current branch diff." \
  --command "git diff --stat origin/main...HEAD"
```

Notes:

- use `--command` only when the answer must come from shell output rather than
  directly from files
- `--command` is valid only for non-Codex backends; the Codex backend rejects
  it
- `--focus` remains a deprecated compatibility alias for `--query`

## Query phrasing

Treat `--query` as the retention target for the returned text.

- broader mixed file window: `Keep exactly the statements that define ...`
- grep-style clustered output: `Which lines are relevant to ...?`
- ultra-narrow fact lookup:
  `Extract only the minimum text needed to answer ...`

Avoid negative-only phrasing such as `Drop examples, framing, and unrelated
lines.` and avoid line-number-only phrasing such as `Return only lines 49, 54,
67, and 68.`

## Remote backend contract

Primary remote env:

- `PRUNER_URL`
- `PRUNER_TIMEOUT_MS`

Compatibility alias:

- `JEEVES_PRUNER_URL` is accepted only when `PRUNER_URL` is unset

Timeout defaults to `30000` ms and is clamped to `100..300000`.

If the remote backend is disabled or the call fails, the CLI falls back to the
original bounded source and emits a warning on stderr.

## Verified request and response shape

Verified on 2026-03-18 against the remote service referenced in
`/work/jeeves/.env`:

- endpoint: `http://192.168.1.15:8000/prune`
- request body: `{ "code": "...", "query": "..." }`
- primary response field: `pruned_code`

Symphony also accepts `content` or `text` as compatibility fallbacks, but the
documented primary contract is `pruned_code`.

## Exit behavior

`lookup` preserves the exit behavior of the bounded source selector that fed the
backend:

- file-window lookup: `0` success, `1` file/runtime failure, `2` invalid CLI
  arguments
- grep lookup: `0` matches found, `1` no matches, `2` invalid regex or
  filesystem/runtime failure
- command lookup: child exit code when the command runs, `1` launcher/runtime
  failure, `2` invalid CLI arguments, `127` no usable shell

For `CONTEXT_PRUNER_BACKEND=codex`, invalid `--command` usage is rejected up
front with exit `2`.
