# Context Pruner CLI

Symphony ships `context-pruner` as a remote-model-backed context lookup CLI.

The supported interface is `context-pruner lookup`. It captures a bounded local
source, submits `{ code, query }` to the configured remote pruner, and returns
the pruned result. If the remote prune step is unavailable, the CLI falls back
to the original bounded source and emits a warning on stderr.

Direct `read`, `grep`, and `bash` subcommands are deprecated compatibility
entrypoints and are no longer the intended long-term interface.

## Workspace availability

The checked-in `elixir/WORKFLOW.md` bootstrap now:

1. clones the repo into the fresh workspace
2. copies the launcher to `~/.local/bin/context-pruner`
3. prepends `~/.local/bin` to the Codex PATH

That makes `context-pruner` directly callable from agent shells inside fresh
Symphony workspaces created by the default `after_create` flow.

## Supported lookup flow

Use `lookup` with a required remote query and one bounded source selector:

```bash
context-pruner lookup \
  --query "Keep exactly the statements that define the env contract." \
  --file-path elixir/docs/context_pruner.md \
  --around-line 45 \
  --radius 12

context-pruner lookup \
  --query "Which lines are relevant to the env variable alias behavior?" \
  --pattern "PRUNER_URL|JEEVES_PRUNER_URL" \
  --path elixir/lib \
  --context-lines 1 \
  --max-matches 12

context-pruner lookup \
  --query "Keep only the files related to the current branch diff." \
  --command "git diff --stat origin/main...HEAD"
```

Guidance:

- start with the smallest file window, grep scope, or shell command that can
  answer the question
- use `--command` only when the answer must come from shell output rather than
  directly from files
- phrase `--query` as the exact retention goal for the remote pruner

Examples of effective query phrasing:

- broader mixed file window: `Keep exactly the statements that define ...`
- grep-style clustered output: `Which lines are relevant to ...?`
- ultra-narrow fact lookup: `Extract only the minimum text needed to answer ...`

Avoid negative-only phrasing such as `Drop examples, framing, and unrelated
lines.` and avoid line-number-only phrasing such as `Return only lines 49, 54,
67, and 68.`

## Focus-query guidance

Treat `--focus` as the remote pruner model's task description.

- For broader mixed file windows, prefer exact field-definition prompts such
  as `Keep exactly the statements that define PRUNER_URL, the alias behavior,
  request body, and primary response field.`
- For grep-style clustered output, prefer question-style relevance prompts
  such as `Which lines are relevant to the request shape and primary response
  field?`
- For ultra-narrow fact extraction, prefer answer-target prompts such as
  `Extract only the minimum text needed to answer: what is the request payload
  shape and what is the primary response field?`
- Avoid negative-only phrasing such as `Drop examples, framing, and unrelated
  lines.` The current benchmark retained more text with that wording than with
  clearer query templates.
- Avoid line-number-only instructions such as `Return only lines 49, 54, 67,
  and 68.` The model often kept nearby material anyway.

The practical rule is:

- broader mixed file window -> `Keep exactly the statements that define ...`
- grep-style clustered output -> `Which lines are relevant to ...?`
- ultra-narrow fact lookup -> `Extract only the minimum text needed to answer ...`

## Pruner environment contract

Primary variables:

- `PRUNER_URL`
- `PRUNER_TIMEOUT_MS`

Compatibility alias:

- `JEEVES_PRUNER_URL` is accepted only when `PRUNER_URL` is unset.

Timeout defaults to `30000` ms and is clamped to `100..300000`.

If pruning is disabled or the remote call fails, the CLI falls back to the
original bounded output and emits a warning on stderr.

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
remote prune step:

- file-window lookup: `0` success, `1` file/runtime failure, `2` invalid CLI arguments
- grep lookup: `0` matches found, `1` no matches, `2` invalid regex or filesystem/runtime failure
- command lookup: child exit code when the command runs, `1` launcher/runtime failure, `2` invalid CLI arguments, `127` no usable shell
