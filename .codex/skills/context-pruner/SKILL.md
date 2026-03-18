---
name: context-pruner
description:
  Use the `context-pruner` CLI for bounded, low-context repository lookup
  before broad raw reads or repo sweeps.
---

# Context Pruner

## What It Is

- `context-pruner` is Symphony's lookup-only context finder.
- Its job is to keep the main task thread lean by returning only the minimum
  relevant text from a bounded source.
- The supported interface is `context-pruner lookup`.
- If you are discovering repository context, start with `context-pruner lookup`
  before broad `cat`, `sed`, `rg`, or ad hoc shell output.
- In fresh Symphony workspaces the launcher should be on `PATH` as
  `context-pruner`. In a repo checkout you can also invoke `./context-pruner`
  from the repo root.

Implementation locations:

- `context-pruner`
- `elixir/lib/symphony_elixir/context_pruner/`
- `elixir/docs/context_pruner.md`

Reuse-first references:

- `/work/jeeves/docs/mcp-pruner-cli-report.md`
- `/work/jeeves/packages/mcp-pruner/`

## Why It Exists

- The main thread pays for every broad read it keeps in context.
- `context-pruner` offloads narrow context-finding work to a cheaper helper and
  returns only the minimal handoff text.
- The Codex-backed path is intentionally constrained. It is not a second full
  repo agent.

## Supported Command Surface

- `context-pruner lookup --query <goal> --file-path <path> [--start-line <n> --end-line <n> | --around-line <n> --radius <n>]`
- `context-pruner lookup --query <goal> --pattern <regex> --path <path> [--context-lines <n>] [--max-matches <n>]`
- `context-pruner lookup --query <goal> --command <shell-command>`
- `--query` is the required retention goal.
- Primary response field: `pruned_code`
- Compatibility fallbacks: `content`, `text`
- Deprecated compatibility aliases:
  - `context-pruner read ...`
  - `context-pruner grep ...`
  - `context-pruner bash ...`
  - Do not use those in new guidance or normal behavior.

## Required Posture

- Start with the smallest file window, grep scope, or shell command that can
  answer the question.
- Refine the local selector before escalating to broader reads.
- Use `--command` only when the answer must come from shell output rather than
  directly from files.
- Treat the returned text as a bounded handoff to the main thread, not as a
  substitute for main-thread ownership of context.

## Codex Backend Contract

When `CONTEXT_PRUNER_BACKEND=codex`:

- the worker runs blank-state from a temporary directory outside the repo
- the worker does not inherit the parent session id, workflow prompt, repo cwd,
  or the full `HOME/.codex` tree
- the worker receives only:
  - the bounded selector output
  - the explicit `--query`
  - explicit backend config such as model, auth, and scope env
- `--command` is disabled
- `--file-path` requires an explicit line window
- scope must be constrained with one or more of:
  - `CONTEXT_PRUNER_ALLOWED_ROOTS`
  - `CONTEXT_PRUNER_ALLOWED_PATHS`
  - `CONTEXT_PRUNER_ALLOWED_GLOBS`

Auth is explicit:

- pass auth env through `CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH`, or
- set `CONTEXT_PRUNER_CODEX_AUTH_FILE` to a single `auth.json` file

Only that auth file is copied into the blank-state home. Sessions and other
`.codex` state are not copied.

## Query Phrasing

- broader mixed file window:
  `Keep exactly the statements that define ...`
- grep-style clustered output:
  `Which lines are relevant to ...?`
- ultra-narrow fact extraction:
  `Extract only the minimum text needed to answer ...`

Avoid negative-only phrasing such as `Drop examples, framing, and unrelated
lines.` and line-number-only instructions such as `Return only lines 49, 54,
67, and 68.`

## Copy-Paste Examples

### File-Window Lookup

```bash
context-pruner lookup \
  --query "Keep exactly the statements that define the env contract." \
  --file-path elixir/docs/context_pruner.md \
  --around-line 144 \
  --radius 14

context-pruner lookup \
  --query "Extract only the minimum text needed to answer how Codex scope is configured." \
  --file-path elixir/docs/context_pruner.md \
  --start-line 37 \
  --end-line 88
```

### Scoped Search Lookup

```bash
context-pruner lookup \
  --query "Which lines define the scope allowlist env?" \
  --pattern "CONTEXT_PRUNER_ALLOWED_(ROOTS|PATHS|GLOBS)" \
  --path elixir/lib \
  --context-lines 1 \
  --max-matches 20

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
  --query "Keep only files related to the current branch diff." \
  --command "git diff --stat origin/main...HEAD"
```

Use that shell form only when the configured backend allows it. The Codex
backend rejects `--command`.

## Environment And Verification

- Prefer `PRUNER_URL`
- Treat `JEEVES_PRUNER_URL` only as a compatibility alias when `PRUNER_URL` is
  unset
- The remote verification target currently referenced in `/work/jeeves/.env` is
  `JEEVES_PRUNER_URL=http://192.168.1.15:8000/prune`
- Use that host only through environment variables. Do not hardcode it.

Example remote verification:

```bash
PRUNER_URL="${PRUNER_URL:-$JEEVES_PRUNER_URL}" \
context-pruner lookup \
  --query "Keep only the pruner contract." \
  --file-path elixir/docs/context_pruner.md \
  --around-line 144 \
  --radius 14
```

## Fallback Behavior

- If `context-pruner` is unavailable or cannot express the search, fall back to
  smaller raw commands such as:
  - `sed -n '120,160p' path/to/file`
  - `rg -n "pattern" path/to/search/root`
  - `bash -lc "<command>"`
- Keep fallback commands bounded.
- Do not replace a failed lookup with a repo-wide sweep unless there is no
  narrower alternative.
- If the backend is disabled or fails, `lookup` falls back to the original
  bounded source and warns on stderr.
