---
name: context-pruner
description:
  Use the `context-pruner` CLI for remote-model-backed context lookup
  before broad raw reads or repo sweeps.
---

# Context Pruner

## What It Is

- `context-pruner` is Symphony's remote-model-backed context lookup CLI.
- The supported interface is `context-pruner lookup`, which:
  - captures a bounded local source window
  - submits `{ code, query }` to the configured pruner service
  - returns the pruned result, or the original bounded source with a warning if the remote prune step is unavailable
- This skill exists to change agent behavior, not just to document a command:
  when you are trying to find repository context, start with
  `context-pruner lookup` instead of broad `cat`, `sed`, `rg`, or ad hoc shell
  output.
- In fresh Symphony workspaces the launcher should be on `PATH` as
  `context-pruner`. In a repo checkout you can also invoke `./context-pruner`
  from the repo root.
- Reuse-first references:
  - `/work/jeeves/docs/mcp-pruner-cli-report.md`
  - `/work/jeeves/packages/mcp-pruner/`
- Symphony's implementation lives in:
  - `context-pruner`
  - `elixir/lib/symphony_elixir/context_pruner/`
  - `elixir/docs/context_pruner.md`

## Supported Command Surface

- `context-pruner lookup --query <goal> --file-path <path> [--start-line <n> --end-line <n> | --around-line <n> --radius <n>]`
- `context-pruner lookup --query <goal> --pattern <regex> --path <path> [--context-lines <n>] [--max-matches <n>]`
- `context-pruner lookup --query <goal> --command <shell-command>`
- `--query` is the required remote retention goal.
- Primary response field: `pruned_code`
- Compatibility fallbacks: `content`, `text`
- Deprecated compatibility aliases:
  - `context-pruner read ...`
  - `context-pruner grep ...`
  - `context-pruner bash ...`
  - Do not use those in new workflow guidance or normal agent behavior.

## Required Posture

- If you are discovering context, use `context-pruner lookup` first.
- Do not start with full-file reads or broad repo sweeps while the lookup flow
  can express the request.
- Start with the smallest file window, grep scope, or shell command that can
  answer the question.
- Use `--command` only when the answer must come from shell output rather than
  directly from files.

## Query Phrasing

- Treat `--query` as the remote pruner model's task description, not as a
  generic "make this shorter" hint.
- For broader mixed file windows, prefer exact field-definition prompts such as
  `Keep exactly the statements that define PRUNER_URL, the alias behavior,
  request body, and primary response field.`
- For grep-style clustered output, prefer question-style relevance prompts such
  as `Which lines are relevant to the request shape and primary response
  field?`
- For ultra-narrow fact extraction, prefer answer-target prompts such as
  `Extract only the minimum text needed to answer: what is the request payload
  shape and what is the primary response field?`
- Avoid negative-only phrasing such as `Drop examples, framing, and unrelated
  lines.` In the current benchmark it tended to retain more text than the
  clearer question-style or keep-only prompts.
- Avoid line-number-only instructions such as `Return only lines 49, 54, 67,
  and 68`. The model often kept neighboring material anyway.
- Keep the query concrete and anchored to the fields, behaviors, or contract
  you actually need from the returned text.

## Exceptions

- Tiny one-line reads or obviously small outputs such as `git status --short`
  can use ordinary shell commands directly when you are not performing
  repository context discovery.
- Interactive commands, streaming output, or cases where you need exact raw
  bytes should stay with normal shell tooling.
- If the CLI cannot express the search you need, use a targeted fallback such
  as `rg -n` or `sed -n`, but keep it narrow.

## Copy-Paste Examples

### File-Window Lookup

```bash
context-pruner lookup \
  --query "Keep exactly the statements that define the env contract." \
  --file-path elixir/docs/context_pruner.md \
  --around-line 49 \
  --radius 6

context-pruner lookup \
  --query "Extract only the minimum text needed to answer how grep lookups are scoped." \
  --file-path elixir/WORKFLOW.md \
  --start-line 93 \
  --end-line 108
```

### Scoped Search Lookup

```bash
context-pruner lookup \
  --query "Which lines are relevant to the env variable contract?" \
  --pattern "PRUNER_URL|JEEVES_PRUNER_URL" \
  --path elixir/lib \
  --context-lines 1 \
  --max-matches 12

context-pruner lookup \
  --query "Which lines define the deprecated local subcommand surface?" \
  --pattern "context-pruner (read|grep|bash)" \
  --path .codex/skills/context-pruner/SKILL.md \
  --context-lines 1 \
  --max-matches 20
```

### Exception-Only Shell Lookup

```bash
context-pruner lookup \
  --query "Keep only files related to the current context-pruner branch diff." \
  --command "git diff --stat origin/main...HEAD"
```

## Pruner Environment And Verification

- Keep Symphony env-driven:
  - Prefer `PRUNER_URL`
  - Treat `JEEVES_PRUNER_URL` only as a compatibility alias when
    `PRUNER_URL` is unset
- The existing remote verification target currently referenced in
  `/work/jeeves/.env` is
  `JEEVES_PRUNER_URL=http://192.168.1.15:8000/prune`.
- Use that host only through environment variables for manual verification. Do
  not hardcode it into Symphony source, workflow prompts, or examples that
  imply it is required.

Example verification:

```bash
PRUNER_URL="${PRUNER_URL:-$JEEVES_PRUNER_URL}" \
context-pruner lookup \
  --query "Keep only the pruner contract." \
  --file-path elixir/docs/context_pruner.md \
  --around-line 45 \
  --radius 12
```

## Fallback Behavior

- If `context-pruner` is unavailable or cannot start, fall back to smaller raw
  commands:
  - `sed -n '120,160p' path/to/file`
  - `rg -n "pattern" path/to/search/root`
  - `bash -lc "<command>"`
- Keep fallback commands bounded. Do not replace a failed `context-pruner`
  lookup with a full-file `cat` or an unbounded repo-wide sweep unless there is
  no narrower alternative.
- If the remote prune step is disabled because `PRUNER_URL` and
  `JEEVES_PRUNER_URL` are both unset, `lookup` returns the original bounded
  source.
- If the remote prune call fails or the endpoint is disabled, the CLI falls
  back to the original bounded source and warns on stderr. Treat that as a soft
  failure and continue with the returned text.
- If bounded output is still too large, refine the file window, regex, path, or
  match limit before escalating to broader raw reads.
