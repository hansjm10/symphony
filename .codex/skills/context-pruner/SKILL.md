---
name: context-pruner
description:
  Use the local `context-pruner` CLI to keep file reads, searches, and
  shell-derived context small and focused. Prefer it when broad raw reads or
  grep sweeps would pull in more context than needed.
---

# Context Pruner

## What It Is

- `context-pruner` is a local CLI for bounded file reads, targeted recursive
  search, and optional prune-focused command output capture.
- This skill exists to change agent behavior, not just to document a command:
  prefer smaller, intentional context pulls over broad `cat`, `sed`, `rg`, or
  ad hoc shell output when the CLI can answer the question directly.
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

## Command Surface

- `context-pruner read --file-path <path> [--start-line <n> --end-line <n> | --around-line <n> --radius <n>] [--focus <query>]`
- `context-pruner grep --pattern <regex> [--path <path>] [--context-lines <n>] [--max-matches <n>] [--focus <query>]`
- `context-pruner bash --command <shell-command> [--focus <query>]`
- `--focus` sends `{ code, query }` to the configured pruner service.
  - Primary response field: `pruned_code`
  - Compatibility fallbacks: `content`, `text`

## Writing `--focus`

- Treat `--focus` as the remote pruner model's task description, not as a
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
- Avoid negative-only phrasing like `Drop examples, framing, and unrelated
  lines.` In the current benchmark it tended to retain more text than the
  clearer question-style or keep-only prompts.
- Avoid line-number-only instructions such as `Return only lines 49, 54, 67,
  and 68`. The model often kept neighboring material anyway.
- Keep the query concrete and anchored to the fields, behaviors, or contract
  you actually need from the returned text.

## When To Prefer It

- Use `read` instead of broad `cat` or `sed` when you know the file and can
  bound the window by line range or by line-plus-radius.
- Use `grep` instead of wide `rg` or `grep -R` sweeps when you want matching
  lines plus bounded nearby context and a match cap.
- Use `bash` when you need shell-derived output but want to keep the final
  model-facing text small and focused.
- Add `--focus` only after you have already narrowed the scope with
  `--file-path`, `--start-line`, `--end-line`, `--around-line`, `--radius`,
  `--path`, `--context-lines`, or `--max-matches`.
- Prefer plain bounded output without pruning when the result is already small
  enough to inspect directly.

## When Not To Prefer It

- Tiny one-line reads or obviously small outputs such as `git status --short`
  can use ordinary shell commands directly.
- Interactive commands, streaming output, or cases where you need exact raw
  bytes should stay with normal shell tooling.
- If the CLI cannot express the search you need, use a targeted fallback such
  as `rg -n` or `sed -n`, but keep it narrow.

## Workflow

1. Start with the smallest file/path window that can answer the question.
2. Prefer `read` or `grep` before `bash` when the data already lives in files.
3. Use line windows, context lines, and match caps before reaching for
   pruning.
4. Add `--focus "<question>"` only when the bounded output is still noisier
   than needed.
5. Write `--focus` to describe the target facts precisely:
   - broader mixed file window -> `Keep exactly the statements that define ...`
   - grep-style clustered output -> `Which lines are relevant to ...?`
   - ultra-narrow fact lookup -> `Extract only the minimum text needed to answer ...`
6. If pruning fails, keep going with the unpruned output instead of retrying
   in a loop or widening the read.

## Copy-Paste Examples

### Focused File Reads

```bash
context-pruner read \
  --file-path elixir/lib/symphony_elixir/context_pruner/cli.ex \
  --start-line 707 \
  --end-line 753

context-pruner read \
  --file-path elixir/docs/context_pruner.md \
  --around-line 31 \
  --radius 12
```

### Targeted Search With Context

```bash
context-pruner grep \
  --pattern "context-pruner" \
  --path elixir \
  --context-lines 2 \
  --max-matches 20

context-pruner grep \
  --pattern "PRUNER_URL|JEEVES_PRUNER_URL" \
  --path elixir/lib \
  --context-lines 1 \
  --max-matches 12
```

### Optional Prune-Focused Commands

```bash
context-pruner read \
  --file-path elixir/docs/context_pruner.md \
  --start-line 35 \
  --end-line 77 \
  --focus "Keep exactly the statements that define PRUNER_URL, the JEEVES_PRUNER_URL alias behavior, the request body, and the primary response field pruned_code."

context-pruner grep \
  --pattern "PRUNER_URL|JEEVES_PRUNER_URL" \
  --path elixir/lib \
  --context-lines 1 \
  --max-matches 12 \
  --focus "Which lines are relevant to the env variable contract and alias behavior?"

context-pruner bash \
  --command "git diff --stat origin/main...HEAD" \
  --focus "Extract only the minimum text needed to answer: which files are related to current context-pruner skill work?"
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
context-pruner read \
  --file-path elixir/docs/context_pruner.md \
  --start-line 35 \
  --end-line 77 \
  --focus "Keep exactly the statements that define the pruner env contract, request body, and primary response field."
```

## Fallback Behavior

- If `context-pruner` is unavailable or cannot start, fall back to smaller raw
  commands:
  - `sed -n '120,160p' path/to/file`
  - `rg -n "pattern" path/to/search/root`
  - `bash -lc "<command>"`
- Keep fallback commands bounded. Do not replace a failed `context-pruner`
  call with a full-file `cat` or an unbounded repo-wide sweep unless there is
  no narrower alternative.
- If pruning is disabled because `PRUNER_URL` and `JEEVES_PRUNER_URL` are both
  unset, `--focus` simply returns the original content.
- If the remote prune call fails or the endpoint is disabled, the CLI falls
  back to the original content and warns on stderr. Treat that as a soft
  failure and continue with the returned text.
- If bounded output is still too large, refine the file window, regex, path,
  or match limit before escalating to broader raw reads.
