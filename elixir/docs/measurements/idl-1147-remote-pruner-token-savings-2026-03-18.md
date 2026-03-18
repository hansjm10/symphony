# IDL-1147 Remote Pruner Token Savings Report

Captured on 2026-03-18T14:20:46Z from workspace tree `9c08d99`.

## Scope

Local `context-pruner read` and `context-pruner grep` commands only produced the submitted payloads. The benchmark target is the remote transformation applied to the same `{code, query}` input.

Endpoint under test: `http://192.168.1.15:8000/prune`

## Rerun

```bash
export PRUNER_URL=...
cd elixir && mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs

# Optional downstream Codex thread-total comparison
cd elixir && MEASURE_CONTEXT_PRUNER_INCLUDE_CODEX=1 mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs
```

JEEVES_PRUNER_URL is accepted only when PRUNER_URL is unset.

The script writes dated JSON and Markdown artifacts under `elixir/docs/measurements/`.

## Remote-Pruner Savings

| Case | Producer | Origin tokens | Left tokens | Savings | Classification |
| --- | --- | ---: | ---: | ---: | --- |
| `file_window_small_env_contract` | `file_window` | 100 | 100 | +0 | `none` |
| `file_window_mixed_contract_section` | `file_window` | 571 | 248 | +323 | `meaningful` |
| `search_result_remote_metadata_cluster` | `search_result` | 397 | 397 | +0 | `none` |
| `search_result_docs_remote_contract_mix` | `search_result` | 370 | 252 | +118 | `meaningful` |

## Observations

- Meaningful reduction (`>=20%` token savings in the remote metadata) appeared in: `file_window_mixed_contract_section`, `search_result_docs_remote_contract_mix`.
- Low or no reduction appeared in: `file_window_small_env_contract`, `search_result_remote_metadata_cluster`.
- The deciding factor was not whether the producer was `read` or `grep`; it was how much extra surrounding context still survived in the submitted payload before the remote prune step.
- Already-narrow inputs often came back unchanged, while broader mixed sections or cross-file grep sweeps were where the remote model removed the most text.

## Case Details

### `file_window_small_env_contract`

- Label: Small env-contract file window
- Producer command: `context-pruner read --file-path elixir/docs/context_pruner.md --around-line 49 --radius 6`
- Query: `Keep only the env contract and alias behavior.`
- Breakpoint note: This window is already query-shaped, so the remote pruner should only help if it can still trim line-number noise or section framing.
- Producer payload: 263 bytes, 13 lines
- Remote metadata: `origin_token_cnt=100`, `left_token_cnt=100`, `model_input_token_cnt=181`
- Reduction: +0 tokens (0.0%), +1 bytes (0.38%)
- Response keys: `error_msg`, `kept_frags`, `left_token_cnt`, `model_input_token_cnt`, `origin_token_cnt`, `pruned_code`, `score`, `token_scores`

Pruned output excerpt:

```text
43: content enters model context.
44: 
45: ## Pruner environment contract
46: 
47: Primary variables:
48: 
49: - `PRUNER_URL`
50: - `PRUNER_TIMEOUT_MS`
51: 
52: Compatibility alias:
53: 
54: - `JEEVES_PRUNER_URL` is accepted only when `PRUNER_URL` is unset.
55: 
```

### `file_window_mixed_contract_section`

- Label: Broader contract section file window
- Producer command: `context-pruner read --file-path elixir/docs/context_pruner.md --start-line 35 --end-line 77`
- Query: `Keep only the env contract, compatibility alias, request body, and primary response field.`
- Breakpoint note: This wider file window mixes examples, env guidance, request shape, and exit-code details, so it should show whether the remote pruner can strip surrounding sections.
- Producer payload: 1679 bytes, 43 lines
- Remote metadata: `origin_token_cnt=571`, `left_token_cnt=248`, `model_input_token_cnt=660`
- Reduction: +323 tokens (56.57%), +1007 bytes (59.98%)
- Response keys: `error_msg`, `kept_frags`, `left_token_cnt`, `model_input_token_cnt`, `origin_token_cnt`, `pruned_code`, `score`, `token_scores`

Pruned output excerpt:

```text
(filtered 12 lines)
47: Primary variables:
48: 
49: - `PRUNER_URL`
50: - `PRUNER_TIMEOUT_MS`
51: 
52: Compatibility alias:
53: 
54: - `JEEVES_PRUNER_URL` is accepted only when `PRUNER_URL` is unset.
55: 
56: Timeout defaults to `30000` ms and is clamped to `100..300000`.
57: 
(filtered 2 lines)
60: 
61: ## Verified request and response shape
62: 
(filtered 3 lines)
66: - endpoint: `http://192.168.1.15:8000/prune`
67: - request body: `{ "code": "...", "query": "..." }`
68: - primary response field: `pruned_code`
69: 
70: Symphony also accepts `content` or `text` as compatibility fallbacks, but 
(truncated)
```

### `search_result_remote_metadata_cluster`

- Label: Already-clustered metadata grep
- Producer command: `context-pruner grep --pattern 'origin_token_cnt|left_token_cnt|model_input_token_cnt|pruned_code|JEEVES_PRUNER_URL|PRUNER_URL' --path elixir/docs --context-lines 2 --max-matches 20`
- Query: `Keep only the remote verification metadata and what it proved.`
- Breakpoint note: This grep is already concentrated on the exact remote-verification terms, so it should reveal when the remote pruner has little left to remove.
- Producer payload: 1268 bytes, 21 lines
- Remote metadata: `origin_token_cnt=397`, `left_token_cnt=397`, `model_input_token_cnt=480`
- Reduction: +0 tokens (0.0%), +0 bytes (0.0%)
- Response keys: `error_msg`, `kept_frags`, `left_token_cnt`, `model_input_token_cnt`, `origin_token_cnt`, `pruned_code`, `score`, `token_scores`

Pruned output excerpt:

```text
elixir/docs/context_pruner.md-47-Primary variables:
elixir/docs/context_pruner.md-48-
elixir/docs/context_pruner.md:49:- `PRUNER_URL`
elixir/docs/context_pruner.md-50-- `PRUNER_TIMEOUT_MS`
elixir/docs/context_pruner.md-51-
elixir/docs/context_pruner.md-52-Compatibility alias:
elixir/docs/context_pruner.md-53-
elixir/docs/context_pruner.md:54:- `JEEVES_PRUNER_URL` is accepted only when `PRUNER_URL` is unset.
elixir/docs/context_pruner.md-55-
elixir/docs/context_pruner.md-56-Timeout defaults to `30000` ms and is clamped to `100..300000`.
--
elixir/docs/context_pruner.md-66-- endpoint: `http://19
(truncated)
```

### `search_result_docs_remote_contract_mix`

- Label: Docs-only remote-contract grep
- Producer command: `context-pruner grep --pattern 'PRUNER_URL|JEEVES_PRUNER_URL|pruned_code|request body|query|token_scores|kept_frags' --path elixir/docs --context-lines 2 --max-matches 20`
- Query: `Keep only the remote request shape and primary response field.`
- Breakpoint note: This grep stays inside the docs subtree but still mixes env guidance, request-shape text, and remote score metadata, so it should show whether the remote pruner can isolate just the request/response contract.
- Producer payload: 1141 bytes, 21 lines
- Remote metadata: `origin_token_cnt=370`, `left_token_cnt=252`, `model_input_token_cnt=453`
- Reduction: +118 tokens (31.89%), +330 bytes (28.92%)
- Response keys: `error_msg`, `kept_frags`, `left_token_cnt`, `model_input_token_cnt`, `origin_token_cnt`, `pruned_code`, `score`, `token_scores`

Pruned output excerpt:

```text
(filtered 3 lines)
elixir/docs/context_pruner.md-50-- `PRUNER_TIMEOUT_MS`
elixir/docs/context_pruner.md-51-
(filtered 2 lines)
elixir/docs/context_pruner.md:54:- `JEEVES_PRUNER_URL` is accepted only when `PRUNER_URL` is unset.
elixir/docs/context_pruner.md-55-
elixir/docs/context_pruner.md-56-Timeout defaults to `30000` ms and is clamped to `100..300000`.
(filtered 3 lines)
elixir/docs/context_pruner.md:67:- request body: `{ "code": "...", "query": "..." }`
elixir/docs/context_pruner.md:68:- primary response field: `pruned_code`
elixir/docs/context_pruner.md-69-
elixir/docs/context_pruner.md-7
(truncated)
```

## Optional Downstream Codex Impact

This layer compared raw versus pruned payloads by supplying the same context directly to Codex in a single-turn prompt.

| Case | Raw total | Pruned total | Savings |
| --- | ---: | ---: | ---: |
| `file_window_small_env_contract` | 13483 | 13457 | +26 |
| `file_window_mixed_contract_section` | 14118 | 13637 | +481 |
| `search_result_remote_metadata_cluster` | 13822 | 14197 | -375 |
| `search_result_docs_remote_contract_mix` | 13852 | 13673 | +179 |

## Artifacts

- JSON artifact: `elixir/docs/measurements/idl-1147-remote-pruner-token-savings-2026-03-18.json`
- Markdown artifact: `elixir/docs/measurements/idl-1147-remote-pruner-token-savings-2026-03-18.md`
- Measurement script: `elixir/scripts/measure_context_pruner_token_savings.exs`
