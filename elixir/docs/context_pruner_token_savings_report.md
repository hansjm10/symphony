# Context-Pruner Token Savings Report

Captured on 2026-03-18 from workspace tree `e1adf13`.

## Result

For the measured dry-run repository investigation, the CLI-guided variant was not worth adopting as the default.

- Baseline thread total: `57,973` tokens
- Context-pruner thread total: `112,509` tokens
- Absolute delta: `+54,536` tokens
- Percentage delta: `+94.07%`

In this run, the context-pruner-guided workflow nearly doubled total thread token usage instead of reducing it.

## Comparison Setup

- Workspace tree for both runs: `e1adf13`
- Baseline guidance source: `24b6e23:elixir/WORKFLOW.md` before the context-pruner instructions existed
- Context-pruner guidance source: `e1adf13:elixir/WORKFLOW.md` context-discovery block
- Runtime: `codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server`
- Accounting source: thread-level cumulative totals from `thread/tokenUsage/updated.params.tokenUsage.total`
- Reproduction command:

```bash
cd elixir && mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs
```

The raw artifact from the completed run is checked in at:

- [`elixir/docs/measurements/idl-1144-context-pruner-token-savings-2026-03-18.json`](/home/jordan/code/symphony-workspaces/IDL-1144/elixir/docs/measurements/idl-1144-context-pruner-token-savings-2026-03-18.json)
- [`elixir/scripts/measure_context_pruner_token_savings.exs`](/home/jordan/code/symphony-workspaces/IDL-1144/elixir/scripts/measure_context_pruner_token_savings.exs)

## Observed Run Shape

The baseline variant used ordinary shell reads:

- `rg -n --hidden -S ... .`
- `sed -n '140,310p' elixir/docs/token_accounting.md`
- `sed -n '150,220p' elixir/docs/context_pruner.md`
- `sed -n '1,220p' elixir/lib/symphony_elixir/context_pruner/pruner.ex`

The context-pruner variant used the new CLI as intended:

- `context-pruner grep --pattern 'cumulative token event|...' --path . --context-lines 2 --max-matches 40`
- `context-pruner grep --pattern 'cumulative token|response.completed|...' --path . --context-lines 2 --max-matches 40`
- `context-pruner read --file-path SPEC.md --start-line 1318 --end-line 1337`

The expensive part was not the launcher itself. The expensive part was what it pulled in:

- the first `context-pruner grep --path .` searched the entire repo root, including `.codex`
- the second `context-pruner grep --path .` also surfaced noise from `elixir/_build` compiled artifacts
- the model then spent extra turns digesting that broader output before answering

That run shape explains why the measured token total went up instead of down.

## Remote Prune Verification

Real prune-path verification used the documented remote endpoint:

- Endpoint: `http://192.168.1.15:8000/prune`
- Request payload exercised:

```json
{
  "code": "function alpha() {}\nfunction beta() {}\nconst target = beta;",
  "query": "What mentions beta?"
}
```

- Primary response field used: `pruned_code`
- Observed HTTP status: `200`
- Response keys included: `pruned_code`, `score`, `token_scores`, `kept_frags`, `origin_token_cnt`, `left_token_cnt`, `model_input_token_cnt`, and `error_msg`

The same run also verified the shipped CLI path with:

- `context-pruner read --file-path elixir/docs/context_pruner.md --around-line 49 --radius 6 --focus "Keep only the env contract and the primary response field."`

That returned the documented env contract centered on `PRUNER_URL`, with `JEEVES_PRUNER_URL` accepted only as a compatibility alias.

## Caveats

- This comparison used a normalized single-turn measurement scaffold instead of the full unattended ticket-management prompt, because the full workflow instructions strongly bias the model to keep working while an issue remains active and made synthetic runs hard to terminate cleanly.
- This was one task shape and one completed run pair, not a broader benchmark suite.
- Both runs used the current repository tree, so the baseline still had the new files available; the measured difference came from the guidance and command path, not from removing the feature from the workspace.
- The current prompt as written encouraged repo-root `context-pruner grep --path .` calls. If the workflow is kept, it likely needs tighter default search roots and stronger exclusions for `.codex`, `_build`, and other low-signal directories before it is cost-effective.
