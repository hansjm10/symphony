# Context-Pruner Token Savings Reports

This repository now keeps two separate measurements under `elixir/docs/measurements/` because they answer different questions.

## Workflow-Shape Measurement

- Historical artifact: [`measurements/idl-1144-context-pruner-token-savings-2026-03-18.json`](measurements/idl-1144-context-pruner-token-savings-2026-03-18.json)
- What it measures: end-to-end Codex thread totals for two repository-discovery workflows, one with ordinary shell reads and one with `context-pruner` guidance
- What it does not measure: the remote pruner model's own reduction on the same submitted `{ code, query }` payload

That IDL-1144 result is still useful for evaluating local context-gathering strategy, but it should not be read as a benchmark of the remote prune step itself.

## Remote-Pruner Measurement

- Latest report: [`measurements/idl-1147-remote-pruner-token-savings-2026-03-18.md`](measurements/idl-1147-remote-pruner-token-savings-2026-03-18.md)
- Latest JSON artifact: [`measurements/idl-1147-remote-pruner-token-savings-2026-03-18.json`](measurements/idl-1147-remote-pruner-token-savings-2026-03-18.json)
- Measurement script: [`../scripts/measure_context_pruner_token_savings.exs`](../scripts/measure_context_pruner_token_savings.exs)

The IDL-1147 benchmark keeps the layers explicit:

- Layer 1: remote-pruner savings on the submitted payload itself
- Layer 2: optional downstream Codex thread-total impact when the pruned payload is supplied to a full run

For Layer 1, local `context-pruner read` and `context-pruner grep` commands are only input producers. The remote benchmark target is the live `PRUNER_URL` transformation applied to the same `{ code, query }` payload.

## Current Takeaways

- Already narrow file windows and already clustered grep results often come back unchanged.
- Broader file windows that mix multiple contract sections do show meaningful remote reduction.
- Grep outputs can also reduce meaningfully when the submitted payload still mixes env guidance, request-shape text, and score metadata, even within `elixir/docs/`.
- The remote benchmark is opt-in and requires `PRUNER_URL`; it is not a default CI gate.

## Rerun

```bash
export PRUNER_URL=...
cd elixir
mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs

# Optional downstream Codex thread-total layer
MEASURE_CONTEXT_PRUNER_INCLUDE_CODEX=1 \
  mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs
```

`JEEVES_PRUNER_URL` is accepted only as a compatibility alias when `PRUNER_URL` is unset. Each run writes dated JSON and Markdown artifacts under `elixir/docs/measurements/`.
