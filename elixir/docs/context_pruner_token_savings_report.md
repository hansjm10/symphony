# Context-Pruner Token Savings Reports

The primary proof for the current constrained blank-state lookup design is the
IDL-1149 measurement:

- latest report:
  [`measurements/idl-1149-constrained-blank-state-context-pruner-2026-03-18.md`](measurements/idl-1149-constrained-blank-state-context-pruner-2026-03-18.md)
- latest JSON:
  [`measurements/idl-1149-constrained-blank-state-context-pruner-2026-03-18.json`](measurements/idl-1149-constrained-blank-state-context-pruner-2026-03-18.json)
- measurement script:
  [`../scripts/measure_context_pruner_token_savings.exs`](../scripts/measure_context_pruner_token_savings.exs)

## What IDL-1149 Measures

This benchmark is about main-thread context cleanliness, not just helper
latency.

It compares:

- a broad inline main-thread read of `elixir/docs/context_pruner.md:94-179`
- an out-of-band constrained blank-state Codex lookup over that same bounded
  source, followed by a fresh main-thread run that receives only the lookup
  result

The latest captured result shows:

- source window: `86` lines / `3111` bytes
- returned lookup payload: `5` lines / `194` bytes
- main-thread savings: `+724` total tokens (`5.06%`)

The same run also proves the constraint boundary:

- `lookup --command` is rejected under `CONTEXT_PRUNER_BACKEND=codex`
- a scope-escape read against `SPEC.md` fails before the helper is launched

## Rerun

If the environment does not already expose auth through passthrough env, point
the measurement at an explicit Codex auth file:

```bash
export MEASURE_CONTEXT_PRUNER_LOOKUP_CODEX_AUTH_FILE="$HOME/.codex/auth.json"
cd elixir
mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs
```

Optional overrides:

- `MEASURE_CONTEXT_PRUNER_LOOKUP_MODEL`
- `MEASURE_CONTEXT_PRUNER_LOOKUP_REASONING_EFFORT`
- `MEASURE_CONTEXT_PRUNER_LOOKUP_CODEX_BIN`

## Historical References

Older reports still answer narrower questions and remain useful as background:

- IDL-1144 workflow-shape comparison:
  [`measurements/idl-1144-context-pruner-token-savings-2026-03-18.json`](measurements/idl-1144-context-pruner-token-savings-2026-03-18.json)
- IDL-1147 remote `{ code, query }` payload benchmark:
  [`measurements/idl-1147-remote-pruner-token-savings-2026-03-18.md`](measurements/idl-1147-remote-pruner-token-savings-2026-03-18.md)

Those artifacts should not be read as proof of the new blank-state Codex scope
contract. IDL-1149 is the current source of truth for that question.
