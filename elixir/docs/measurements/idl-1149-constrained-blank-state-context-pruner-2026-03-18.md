# IDL-1149 Constrained Blank-State Context-Pruner Report

Captured on 2026-03-18T16:25:58Z from workspace tree `520508e`.

## Goal

Compare a broad inline main-thread discovery path with a constrained blank-state lookup path that returns only the minimal result.

## Lookup Backend

- Backend: `codex`
- Model: `gpt-5.3-codex-spark`
- Reasoning effort: `low`
- Allowed roots: `elixir/docs`
- Not inherited: `the parent Codex session id`, `the parent workflow prompt`, `the parent repo working directory`, `the parent HOME/.codex config tree`

## Main-Thread Comparison

- Shared bounded source window: `elixir/docs/context_pruner.md:94-179`
- Inline broad-read source: `sed -n '94,179p' elixir/docs/context_pruner.md` (86 lines, 3111 bytes)
- Lookup worker command: `context-pruner lookup --query "Keep only the preferred remote env vars, the compatibility alias rule, the request body shape, and the primary response field." --file-path elixir/docs/context_pruner.md --start-line 94 --end-line 179`
- Lookup worker return payload: 5 lines, 194 bytes
- Lookup staging rule: The lookup worker runs before the measured main-thread turn; only the returned excerpt enters the measured prompt.

| Variant | Total tokens | Command hints |
| --- | ---: | --- |
| inline broad reads | 14312 | `sed -n '94,179p' elixir/docs/context_pruner.md` |
| lookup-assisted | 13588 | `context-pruner lookup --query "Keep only the preferred remote env vars, the compatibility alias rule, the request body shape, and the primary response field." --file-path elixir/docs/context_pruner.md --start-line 94 --end-line 179` |

- Savings on the main thread: +724 tokens (5.06%).
- Inline prompt bytes: 3758; lookup prompt bytes: 1035.
- Inline methods seen: `item/agentMessage/delta`, `item/completed`, `item/started`, `thread/status/changed`, `thread/tokenUsage/updated`, `turn/completed`, `turn/started`.
- Lookup methods seen: `item/agentMessage/delta`, `item/completed`, `item/started`, `thread/status/changed`, `thread/tokenUsage/updated`, `turn/completed`, `turn/started`.
- Lookup worker stderr during staging: ``.

## Constraint Probes

- Command source probe: exit 2, stderr ``context-pruner lookup --command ...` is disabled when `CONTEXT_PRUNER_BACKEND=codex`; use bounded --file-path or --pattern lookups instead.

Usage:
  context-pruner lookup --query <query> --file-path <path> [--start-line <n> --end-line <n>]
  context-pruner lookup --query <query> --file-path <path> [--around-line <n> --radius <n>]
  context-pruner lookup --query <query> --pattern <regex> --path <path> [--context-lines <n>] [--max-matches <n>]
  context-pruner lookup --query <query> --command <shell-command>

Options:
  --query <query>       Required remote retention goal submitted as { code, query }.
  --file-path <path>    File source for a bounded lookup window.
  --start-line <n>      1-based inclusive start line for file-window lookups.
  --end-line <n>        1-based inclusive end line for file-window lookups.
  --around-line <n>     1-based anchor line for around/radius file-window lookups.
  --radius <n>          Context radius used with --around-line. Default: 20
  --pattern <regex>     Grep-style source selector used before remote lookup.
  --path <path>         Required explicit file or directory scope for grep lookups.
  --context-lines <n>   Number of surrounding lines to include. Max: 50
  --max-matches <n>     Maximum output lines before truncation. Default: 200
  --command <command>   Exception-only shell source when the answer cannot come directly from files.
  --focus <query>       Deprecated compatibility alias for --query.
`.
- Scope escape probe: exit 1, stderr `Path is outside the configured context-pruner scope: /home/jordan/code/symphony-workspaces/IDL-1149/SPEC.md. Allowed scope: roots=elixir/docs`.

## Rerun

```bash
cd elixir && mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs
```
