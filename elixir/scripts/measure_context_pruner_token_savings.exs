defmodule ContextPrunerTokenSavingsMeasurement do
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.ContextPruner.{CLI, Pruner}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  @artifact_slug "idl-1147-remote-pruner-token-savings"
  @codex_command "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server"
  @downstream_env "MEASURE_CONTEXT_PRUNER_INCLUDE_CODEX"
  @direct_probe_timeout_ms 10_000

  def main do
    repo_root = Path.expand("../..", __DIR__)
    elixir_root = Path.expand("..", __DIR__)
    output_dir = Path.join(elixir_root, "docs/measurements")
    captured_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    captured_date = Date.utc_today() |> Date.to_iso8601()
    current_head = git_output!(repo_root, ["rev-parse", "HEAD"])
    current_short_head = git_output!(repo_root, ["rev-parse", "--short", "HEAD"])
    selected_cases = selected_cases()
    {pruner_url, pruner_warnings} = pruner_url!()

    {:ok, _started} = Application.ensure_all_started(:req)

    remote_cases =
      Enum.map(selected_cases, fn benchmark_case ->
        measure_remote_case(pruner_url, repo_root, benchmark_case)
      end)

    downstream_codex_impact =
      maybe_measure_downstream_codex_impact(repo_root, pruner_url, selected_cases, remote_cases)

    json_file_name = "#{@artifact_slug}-#{captured_date}.json"
    markdown_file_name = "#{@artifact_slug}-#{captured_date}.md"
    json_path = Path.join(output_dir, json_file_name)
    markdown_path = Path.join(output_dir, markdown_file_name)

    report = %{
      "measurementId" => "IDL-1147",
      "capturedAt" => captured_at,
      "workspace" => repo_root,
      "workspaceTree" => current_short_head,
      "workspaceTreeRef" => current_head,
      "benchmarkTarget" => %{
        "name" => "remote_pruner_payload_reduction",
        "endpoint" => pruner_url,
        "requestShape" => %{"code" => "...", "query" => "..."},
        "producerNote" =>
          "Local `context-pruner read` and `context-pruner grep` commands only produced the submitted payloads. The benchmark target is the remote transformation applied to the same `{code, query}` input.",
        "prunerConfigWarnings" => pruner_warnings
      },
      "artifacts" => %{
        "jsonPath" => Path.relative_to(json_path, repo_root),
        "markdownPath" => Path.relative_to(markdown_path, repo_root),
        "scriptPath" => "elixir/scripts/measure_context_pruner_token_savings.exs"
      },
      "rerun" => %{
        "requiredEnv" => ["PRUNER_URL"],
        "compatibilityAlias" => "JEEVES_PRUNER_URL is accepted only when PRUNER_URL is unset.",
        "defaultCommand" => "cd elixir && mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs",
        "optionalDownstreamCommand" => "cd elixir && #{@downstream_env}=1 mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs"
      },
      "remotePrunerSavings" => %{
        "cases" => remote_cases,
        "summary" => summarize_remote_cases(remote_cases)
      },
      "downstreamCodexImpact" => downstream_codex_impact
    }

    File.mkdir_p!(output_dir)
    File.write!(json_path, Jason.encode!(report, pretty: true))
    File.write!(markdown_path, render_markdown(report))

    IO.puts(json_path)
    IO.puts(markdown_path)
  end

  defp measurement_cases do
    [
      %{
        id: "file_window_small_env_contract",
        producer_type: "file_window",
        label: "Small env-contract file window",
        query: "Keep only the env contract and alias behavior.",
        producer_args: [
          "read",
          "--file-path",
          "elixir/docs/context_pruner.md",
          "--around-line",
          "49",
          "--radius",
          "6"
        ],
        breakpoint_note: "This window is already query-shaped, so the remote pruner should only help if it can still trim line-number noise or section framing."
      },
      %{
        id: "file_window_mixed_contract_section",
        producer_type: "file_window",
        label: "Broader contract section file window",
        query: "Keep only the env contract, compatibility alias, request body, and primary response field.",
        producer_args: [
          "read",
          "--file-path",
          "elixir/docs/context_pruner.md",
          "--start-line",
          "35",
          "--end-line",
          "77"
        ],
        breakpoint_note: "This wider file window mixes examples, env guidance, request shape, and exit-code details, so it should show whether the remote pruner can strip surrounding sections."
      },
      %{
        id: "search_result_remote_metadata_cluster",
        producer_type: "search_result",
        label: "Already-clustered metadata grep",
        query: "Keep only the remote verification metadata and what it proved.",
        producer_args: [
          "grep",
          "--pattern",
          "origin_token_cnt|left_token_cnt|model_input_token_cnt|pruned_code|JEEVES_PRUNER_URL|PRUNER_URL",
          "--path",
          "elixir/docs",
          "--context-lines",
          "2",
          "--max-matches",
          "20"
        ],
        breakpoint_note: "This grep is already concentrated on the exact remote-verification terms, so it should reveal when the remote pruner has little left to remove."
      },
      %{
        id: "search_result_docs_remote_contract_mix",
        producer_type: "search_result",
        label: "Docs-only remote-contract grep",
        query: "Keep only the remote request shape and primary response field.",
        producer_args: [
          "grep",
          "--pattern",
          "PRUNER_URL|JEEVES_PRUNER_URL|pruned_code|request body|query|token_scores|kept_frags",
          "--path",
          "elixir/docs",
          "--context-lines",
          "2",
          "--max-matches",
          "20"
        ],
        breakpoint_note:
          "This grep stays inside the docs subtree but still mixes env guidance, request-shape text, and remote score metadata, so it should show whether the remote pruner can isolate just the request/response contract."
      }
    ]
  end

  defp selected_cases do
    case System.get_env("MEASURE_CONTEXT_PRUNER_CASES") do
      nil ->
        measurement_cases()

      raw_case_ids ->
        requested_ids =
          raw_case_ids
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        cases_by_id = Map.new(measurement_cases(), fn benchmark_case -> {benchmark_case.id, benchmark_case} end)
        unknown_ids = Enum.reject(requested_ids, &Map.has_key?(cases_by_id, &1))

        if unknown_ids != [] do
          raise "Unknown MEASURE_CONTEXT_PRUNER_CASES entries: #{Enum.join(unknown_ids, ", ")}"
        end

        Enum.map(requested_ids, &Map.fetch!(cases_by_id, &1))
    end
  end

  defp pruner_url! do
    {config, warnings} = Pruner.config(System.get_env())

    if config.enabled do
      {config.url, warnings}
    else
      raise """
      PRUNER_URL is required for this opt-in measurement.
      Set PRUNER_URL to the live prune endpoint before running the script.
      JEEVES_PRUNER_URL is accepted only as a compatibility alias when PRUNER_URL is unset.
      """
    end
  end

  defp measure_remote_case(pruner_url, repo_root, benchmark_case) do
    producer_result =
      with_temporary_env(%{"CONTEXT_PRUNER_CWD" => repo_root}, fn ->
        CLI.evaluate(benchmark_case.producer_args)
      end)

    if producer_result.exit_code != 0 do
      raise "Producer command failed for #{benchmark_case.id}: #{producer_result.stderr}"
    end

    producer_stdout = sanitize_text(producer_result.stdout)
    producer_stderr = sanitize_text(producer_result.stderr)

    payload = %{"code" => producer_stdout, "query" => benchmark_case.query}

    {:ok, response} =
      Req.post(pruner_url,
        connect_options: [timeout: @direct_probe_timeout_ms],
        receive_timeout: @direct_probe_timeout_ms,
        retry: false,
        json: payload
      )

    body = response.body
    pruned_code = body |> extract_pruned_code!(benchmark_case.id) |> sanitize_text()
    origin_token_count = maybe_integer(Map.get(body, "origin_token_cnt"))
    left_token_count = maybe_integer(Map.get(body, "left_token_cnt"))
    producer_byte_count = byte_size(producer_stdout)
    pruned_byte_count = byte_size(pruned_code)
    producer_line_count = line_count(producer_stdout)
    pruned_line_count = line_count(pruned_code)
    token_savings = subtract_if_present(origin_token_count, left_token_count)
    byte_savings = producer_byte_count - pruned_byte_count
    line_savings = producer_line_count - pruned_line_count
    reduction_class = reduction_class(token_savings, origin_token_count, byte_savings, producer_byte_count)

    %{
      "id" => benchmark_case.id,
      "label" => benchmark_case.label,
      "producerType" => benchmark_case.producer_type,
      "query" => benchmark_case.query,
      "breakpointNote" => benchmark_case.breakpoint_note,
      "producerCommand" => "context-pruner " <> shell_join(benchmark_case.producer_args),
      "producerOutput" => %{
        "exitCode" => producer_result.exit_code,
        "stderr" => producer_stderr,
        "stdout" => producer_stdout,
        "byteCount" => producer_byte_count,
        "lineCount" => producer_line_count
      },
      "remoteResponse" => %{
        "httpStatus" => response.status,
        "responseKeys" => response_keys(body),
        "score" => Map.get(body, "score"),
        "keptFrags" => Map.get(body, "kept_frags"),
        "originTokenCount" => origin_token_count,
        "leftTokenCount" => left_token_count,
        "modelInputTokenCount" => maybe_integer(Map.get(body, "model_input_token_cnt")),
        "errorMessage" => Map.get(body, "error_msg"),
        "prunedCode" => pruned_code
      },
      "reduction" => %{
        "tokenSavings" => token_savings,
        "tokenSavingsPercent" => percentage_savings(origin_token_count, token_savings),
        "byteSavings" => byte_savings,
        "byteSavingsPercent" => percentage_savings(producer_byte_count, byte_savings),
        "lineSavings" => line_savings,
        "lineSavingsPercent" => percentage_savings(producer_line_count, line_savings)
      },
      "prunedCodeChanged" => pruned_code != producer_stdout,
      "reductionClass" => reduction_class
    }
  end

  defp maybe_measure_downstream_codex_impact(repo_root, pruner_url, benchmark_cases, remote_cases) do
    if truthy_env?(@downstream_env) do
      workspace_root = Path.dirname(repo_root)
      issue = downstream_measurement_issue()

      cases_by_id = Map.new(benchmark_cases, fn benchmark_case -> {benchmark_case.id, benchmark_case} end)

      measured_cases =
        with_measurement_workflow(repo_root, workspace_root, fn ->
          Enum.map(remote_cases, fn remote_case ->
            benchmark_case = Map.fetch!(cases_by_id, remote_case["id"])

            measure_downstream_case(
              repo_root,
              issue,
              benchmark_case,
              remote_case["producerOutput"]["stdout"],
              remote_case["remoteResponse"]["prunedCode"]
            )
          end)
        end)

      %{
        "enabled" => true,
        "prunerEndpoint" => pruner_url,
        "cases" => measured_cases,
        "summary" => summarize_downstream_cases(measured_cases)
      }
    else
      %{
        "enabled" => false,
        "skipReason" => "Set #{@downstream_env}=1 to run the optional raw-vs-pruned Codex thread-total comparison.",
        "measurementPromptShape" => "Single-turn prompt that supplies the raw or pruned payload directly and forbids repository inspection or tool use.",
        "cases" => []
      }
    end
  end

  defp with_measurement_workflow(_repo_root, workspace_root, fun) when is_function(fun, 0) do
    workflow_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-context-pruner-measure-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workflow_dir)

    workflow_path = Path.join(workflow_dir, "WORKFLOW.measurement.md")
    File.write!(workflow_path, measurement_workflow(workspace_root))
    original_workflow_path = Workflow.workflow_file_path()

    try do
      Workflow.set_workflow_file_path(workflow_path)
      fun.()
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(workflow_dir)
    end
  end

  defp measure_downstream_case(repo_root, issue, benchmark_case, raw_payload, pruned_payload) do
    raw_variant =
      run_prompt_variant(
        "#{benchmark_case.id}_raw",
        downstream_prompt(repo_root, benchmark_case, raw_payload),
        repo_root,
        issue
      )

    pruned_variant =
      run_prompt_variant(
        "#{benchmark_case.id}_pruned",
        downstream_prompt(repo_root, benchmark_case, pruned_payload),
        repo_root,
        issue
      )

    raw_total = raw_variant["finalThreadTotal"]["totalTokens"]
    pruned_total = pruned_variant["finalThreadTotal"]["totalTokens"]
    token_savings = raw_total - pruned_total

    %{
      "id" => benchmark_case.id,
      "label" => benchmark_case.label,
      "producerType" => benchmark_case.producer_type,
      "query" => benchmark_case.query,
      "rawVariant" => raw_variant,
      "prunedVariant" => pruned_variant,
      "comparison" => %{
        "rawTotalTokens" => raw_total,
        "prunedTotalTokens" => pruned_total,
        "tokenSavings" => token_savings,
        "percentageSavings" => percentage_savings(raw_total, token_savings)
      }
    }
  end

  defp downstream_measurement_issue do
    %Issue{
      id: "measurement-context-pruner-remote-savings",
      identifier: "MEASURE-CP-REMOTE-1",
      title: "Remote pruner downstream token measurement",
      state: "Measurement",
      url: "https://example.invalid/MEASURE-CP-REMOTE-1",
      labels: ["measurement", "dry-run"],
      description: """
      Synthetic single-turn measurement task used only for comparing raw versus pruned downstream token usage.
      """
    }
  end

  defp downstream_prompt(repo_root, benchmark_case, supplied_context) do
    """
    You are running a synthetic single-turn downstream token measurement inside the repository at `#{repo_root}`.

    Task:
    - Use only the supplied context block.
    - Do not inspect the repository.
    - Do not call tools.
    - Do not change files.
    - Answer the question in exactly 3 bullet points and end the turn immediately.

    Local producer type: #{benchmark_case.producer_type}
    Local producer command: context-pruner #{shell_join(benchmark_case.producer_args)}
    Question: #{benchmark_case.query}

    Supplied context:
    ```text
    #{supplied_context}
    ```
    """
  end

  defp run_prompt_variant(name, prompt, workspace, issue) do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    start_ms = System.monotonic_time(:millisecond)

    result =
      AppServer.run(
        workspace,
        prompt,
        issue,
        on_message: fn message ->
          Agent.update(collector, &[message | &1])
        end
      )

    duration_ms = System.monotonic_time(:millisecond) - start_ms
    messages = Agent.get(collector, &Enum.reverse/1)
    Agent.stop(collector)

    thread_updates = extract_thread_totals(messages)

    final_thread_total =
      case List.last(thread_updates) do
        nil -> raise "missing thread/tokenUsage/updated total for #{name}"
        usage -> usage
      end

    %{
      "variant" => name,
      "promptByteCount" => byte_size(prompt),
      "promptLineCount" => line_count(prompt),
      "durationMs" => duration_ms,
      "result" => normalize_run_result(result),
      "methodsSeen" => message_method_counts(messages),
      "threadTotalSnapshots" => thread_updates,
      "finalThreadTotal" => final_thread_total,
      "turnCompletedUsage" => extract_turn_completed_usage(messages),
      "commandHints" => extract_command_hints(messages)
    }
  end

  defp render_markdown(report) do
    remote_cases = get_in(report, ["remotePrunerSavings", "cases"])
    remote_summary = get_in(report, ["remotePrunerSavings", "summary"])
    downstream_impact = report["downstreamCodexImpact"]

    meaningful_ids = remote_summary["meaningfulReductionCaseIds"]
    low_or_no_ids = remote_summary["lowOrNoReductionCaseIds"]

    [
      "# IDL-1147 Remote Pruner Token Savings Report\n\n",
      "Captured on #{report["capturedAt"]} from workspace tree `#{report["workspaceTree"]}`.\n\n",
      "## Scope\n\n",
      report["benchmarkTarget"]["producerNote"],
      "\n\n",
      "Endpoint under test: `#{report["benchmarkTarget"]["endpoint"]}`\n\n",
      "## Rerun\n\n",
      "```bash\n",
      "export PRUNER_URL=...\n",
      report["rerun"]["defaultCommand"],
      "\n\n",
      "# Optional downstream Codex thread-total comparison\n",
      report["rerun"]["optionalDownstreamCommand"],
      "\n```\n\n",
      report["rerun"]["compatibilityAlias"],
      "\n\n",
      "The script writes dated JSON and Markdown artifacts under `elixir/docs/measurements/`.\n\n",
      "## Remote-Pruner Savings\n\n",
      "| Case | Producer | Origin tokens | Left tokens | Savings | Classification |\n",
      "| --- | --- | ---: | ---: | ---: | --- |\n",
      Enum.map_join(remote_cases, "", &render_remote_case_row/1),
      "\n",
      "## Observations\n\n",
      "- Meaningful reduction (`>=20%` token savings in the remote metadata) appeared in: `#{Enum.join(meaningful_ids, "`, `")}`.\n",
      "- Low or no reduction appeared in: `#{Enum.join(low_or_no_ids, "`, `")}`.\n",
      "- The deciding factor was not whether the producer was `read` or `grep`; it was how much extra surrounding context still survived in the submitted payload before the remote prune step.\n",
      "- Already-narrow inputs often came back unchanged, while broader mixed sections or cross-file grep sweeps were where the remote model removed the most text.\n\n",
      "## Case Details\n\n",
      Enum.map_join(remote_cases, "\n", &render_remote_case_details/1),
      render_downstream_markdown(downstream_impact),
      "## Artifacts\n\n",
      "- JSON artifact: `#{report["artifacts"]["jsonPath"]}`\n",
      "- Markdown artifact: `#{report["artifacts"]["markdownPath"]}`\n",
      "- Measurement script: `#{report["artifacts"]["scriptPath"]}`\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp render_remote_case_row(remote_case) do
    origin_token_count = get_in(remote_case, ["remoteResponse", "originTokenCount"])
    left_token_count = get_in(remote_case, ["remoteResponse", "leftTokenCount"])
    token_savings = get_in(remote_case, ["reduction", "tokenSavings"])

    "| `#{remote_case["id"]}` | `#{remote_case["producerType"]}` | #{display_metric(origin_token_count)} | #{display_metric(left_token_count)} | #{display_signed_metric(token_savings)} | `#{remote_case["reductionClass"]}` |\n"
  end

  defp render_remote_case_details(remote_case) do
    [
      "### `#{remote_case["id"]}`\n\n",
      "- Label: #{remote_case["label"]}\n",
      "- Producer command: `#{remote_case["producerCommand"]}`\n",
      "- Query: `#{remote_case["query"]}`\n",
      "- Breakpoint note: #{remote_case["breakpointNote"]}\n",
      "- Producer payload: #{get_in(remote_case, ["producerOutput", "byteCount"])} bytes, #{get_in(remote_case, ["producerOutput", "lineCount"])} lines\n",
      "- Remote metadata: `origin_token_cnt=#{display_metric(get_in(remote_case, ["remoteResponse", "originTokenCount"]))}`, `left_token_cnt=#{display_metric(get_in(remote_case, ["remoteResponse", "leftTokenCount"]))}`, `model_input_token_cnt=#{display_metric(get_in(remote_case, ["remoteResponse", "modelInputTokenCount"]))}`\n",
      "- Reduction: #{display_signed_metric(get_in(remote_case, ["reduction", "tokenSavings"]))} tokens (#{display_percent(get_in(remote_case, ["reduction", "tokenSavingsPercent"]))}), #{display_signed_metric(get_in(remote_case, ["reduction", "byteSavings"]))} bytes (#{display_percent(get_in(remote_case, ["reduction", "byteSavingsPercent"]))})\n",
      "- Response keys: `#{Enum.join(get_in(remote_case, ["remoteResponse", "responseKeys"]), "`, `")}`\n\n",
      "Pruned output excerpt:\n\n",
      "```text\n",
      excerpt(get_in(remote_case, ["remoteResponse", "prunedCode"]), 600),
      "\n```\n"
    ]
  end

  defp render_downstream_markdown(%{"enabled" => false} = downstream_impact) do
    [
      "\n## Optional Downstream Codex Impact\n\n",
      downstream_impact["skipReason"],
      "\n\n",
      downstream_impact["measurementPromptShape"],
      "\n\n"
    ]
  end

  defp render_downstream_markdown(%{"enabled" => true} = downstream_impact) do
    cases = downstream_impact["cases"]

    [
      "\n## Optional Downstream Codex Impact\n\n",
      "This layer compared raw versus pruned payloads by supplying the same context directly to Codex in a single-turn prompt.\n\n",
      "| Case | Raw total | Pruned total | Savings |\n",
      "| --- | ---: | ---: | ---: |\n",
      Enum.map_join(cases, "", fn downstream_case ->
        comparison = downstream_case["comparison"]

        "| `#{downstream_case["id"]}` | #{comparison["rawTotalTokens"]} | #{comparison["prunedTotalTokens"]} | #{display_signed_metric(comparison["tokenSavings"])} |\n"
      end),
      "\n"
    ]
  end

  defp summarize_remote_cases(remote_cases) do
    meaningful_reduction_ids =
      remote_cases
      |> Enum.filter(&(&1["reductionClass"] == "meaningful"))
      |> Enum.map(& &1["id"])

    low_or_no_reduction_ids =
      remote_cases
      |> Enum.reject(&(&1["reductionClass"] == "meaningful"))
      |> Enum.map(& &1["id"])

    largest_case =
      Enum.max_by(
        remote_cases,
        fn remote_case -> get_in(remote_case, ["reduction", "tokenSavings"]) || -1 end,
        fn -> nil end
      )

    %{
      "caseCount" => length(remote_cases),
      "meaningfulReductionCaseIds" => meaningful_reduction_ids,
      "lowOrNoReductionCaseIds" => low_or_no_reduction_ids,
      "largestTokenSavingsCaseId" => if(largest_case, do: largest_case["id"], else: nil)
    }
  end

  defp summarize_downstream_cases(downstream_cases) do
    total_token_savings =
      downstream_cases
      |> Enum.map(fn downstream_case -> get_in(downstream_case, ["comparison", "tokenSavings"]) || 0 end)
      |> Enum.sum()

    %{
      "caseCount" => length(downstream_cases),
      "aggregateTokenSavings" => total_token_savings
    }
  end

  defp extract_pruned_code!(body, case_id) when is_map(body) do
    case Map.get(body, "pruned_code") do
      value when is_binary(value) ->
        value

      _ ->
        raise "Remote pruner response for #{case_id} did not include a string pruned_code field."
    end
  end

  defp response_keys(body) when is_map(body) do
    body
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp reduction_class(token_savings, origin_token_count, byte_savings, producer_byte_count) do
    cond do
      meaningful_savings?(token_savings, origin_token_count) ->
        "meaningful"

      positive_savings?(token_savings) or meaningful_savings?(byte_savings, producer_byte_count) ->
        "limited"

      true ->
        "none"
    end
  end

  defp meaningful_savings?(savings, base)
       when is_integer(savings) and is_integer(base) and base > 0 do
    savings >= 0 and savings / base >= 0.20
  end

  defp meaningful_savings?(_, _), do: false

  defp positive_savings?(value) when is_integer(value), do: value > 0
  defp positive_savings?(_value), do: false

  defp truthy_env?(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]

      _ ->
        false
    end
  end

  defp with_temporary_env(overrides, fun) when is_function(fun, 0) do
    previous =
      Enum.into(overrides, %{}, fn {key, _value} ->
        {key, System.get_env(key)}
      end)

    Enum.each(overrides, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp extract_thread_totals(messages) do
    messages
    |> Enum.flat_map(fn message ->
      with "thread/tokenUsage/updated" <- payload_method(message),
           usage when is_map(usage) <- payload_path(message, ["params", "tokenUsage", "total"]) do
        [normalize_usage(usage)]
      else
        _ -> []
      end
    end)
  end

  defp extract_turn_completed_usage(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      case payload_method(message) do
        "turn/completed" ->
          payload_path(message, ["usage"])
          |> case do
            usage when is_map(usage) -> normalize_usage(usage)
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      "inputTokens" => int_value(usage, ["inputTokens", "input_tokens"]),
      "outputTokens" => int_value(usage, ["outputTokens", "output_tokens"]),
      "totalTokens" => int_value(usage, ["totalTokens", "total_tokens"])
    }
  end

  defp int_value(map, keys) do
    keys
    |> Enum.find_value(fn key ->
      case Map.get(map, key) || maybe_get_existing_atom_key(map, key) do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {parsed, ""} -> parsed
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp payload_method(message) do
    payload = Map.get(message, :payload) || Map.get(message, "payload")

    case payload do
      payload when is_map(payload) ->
        Map.get(payload, "method") || Map.get(payload, :method)

      _ ->
        nil
    end
  end

  defp payload_path(message, [first | rest]) do
    payload = Map.get(message, :payload) || Map.get(message, "payload")
    payload_path_segments(payload, [first | rest])
  end

  defp payload_path_segments(current, []) do
    current
  end

  defp payload_path_segments(current, [segment | rest]) when is_map(current) do
    case Map.get(current, segment) || maybe_get_existing_atom_key(current, segment) do
      nil -> nil
      next -> payload_path_segments(next, rest)
    end
  end

  defp payload_path_segments(_current, _segments), do: nil

  defp maybe_get_existing_atom_key(map, segment) when is_map(map) and is_binary(segment) do
    try do
      segment
      |> String.to_existing_atom()
      |> then(&Map.get(map, &1))
    rescue
      ArgumentError ->
        nil
    end
  end

  defp maybe_get_existing_atom_key(_map, _segment), do: nil

  defp message_method_counts(messages) do
    messages
    |> Enum.reduce(%{}, fn message, counts ->
      case payload_method(message) do
        method when is_binary(method) -> Map.update(counts, method, 1, &(&1 + 1))
        _ -> counts
      end
    end)
  end

  defp extract_command_hints(messages) do
    messages
    |> Enum.flat_map(&collect_command_strings/1)
    |> Enum.uniq()
  end

  defp collect_command_strings(value) when is_struct(value), do: []

  defp collect_command_strings(value) when is_map(value) do
    current =
      value
      |> Enum.flat_map(fn {key, nested} ->
        cond do
          key in [:command, "command", :cmd, "cmd", :shellCommand, "shellCommand"] and is_binary(nested) ->
            [nested]

          key in [:argv, "argv"] and is_list(nested) ->
            [Enum.join(Enum.map(nested, &to_string/1), " ")]

          true ->
            []
        end
      end)

    current ++ Enum.flat_map(Map.values(value), &collect_command_strings/1)
  end

  defp collect_command_strings(value) when is_list(value) do
    Enum.flat_map(value, &collect_command_strings/1)
  end

  defp collect_command_strings(_value), do: []

  defp normalize_run_result({:ok, result}) when is_map(result) do
    %{"status" => "ok", "result" => normalize_term(result)}
  end

  defp normalize_run_result({:error, reason}) do
    %{"status" => "error", "reason" => inspect(reason)}
  end

  defp normalize_term(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_term(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested} ->
      normalized_key =
        case key do
          atom when is_atom(atom) -> Atom.to_string(atom)
          other -> other
        end

      {normalized_key, normalize_term(nested)}
    end)
  end

  defp normalize_term(value) when is_list(value), do: Enum.map(value, &normalize_term/1)
  defp normalize_term(value) when is_binary(value), do: sanitize_text(value)
  defp normalize_term(value), do: value

  defp maybe_integer(value) when is_integer(value), do: value

  defp maybe_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp maybe_integer(_value), do: nil

  defp subtract_if_present(left, right) when is_integer(left) and is_integer(right), do: left - right
  defp subtract_if_present(_left, _right), do: nil

  defp percentage_savings(base, savings) when is_integer(base) and is_integer(savings) and base > 0 do
    Float.round(savings / base * 100.0, 2)
  end

  defp percentage_savings(_base, _savings), do: nil

  defp line_count(text) when text in [nil, ""], do: 0

  defp line_count(text) when is_binary(text) do
    text
    |> String.split(~r/\r\n|\n|\r/, trim: false)
    |> drop_trailing_empty_line()
    |> length()
  end

  defp drop_trailing_empty_line(lines) do
    case Enum.reverse(lines) do
      ["" | rest] -> Enum.reverse(rest)
      _ -> lines
    end
  end

  defp display_metric(nil), do: "n/a"
  defp display_metric(value), do: Integer.to_string(value)

  defp display_signed_metric(nil), do: "n/a"
  defp display_signed_metric(value) when value >= 0, do: "+" <> Integer.to_string(value)
  defp display_signed_metric(value), do: Integer.to_string(value)

  defp display_percent(nil), do: "n/a"
  defp display_percent(value), do: "#{value}%"

  defp excerpt(text, max_bytes) when is_binary(text) do
    text = sanitize_text(text)

    if byte_size(text) <= max_bytes do
      text
    else
      binary_part(text, 0, max_bytes) <> "\n(truncated)"
    end
  end

  defp sanitize_text(value) when is_binary(value), do: String.replace_invalid(value, "�")
  defp sanitize_text(value), do: value

  defp shell_join(argv) do
    Enum.map_join(argv, " ", &shell_escape/1)
  end

  defp shell_escape(value) when is_binary(value) do
    if Regex.match?(~r|^[A-Za-z0-9_@%+=:,./-]+$|, value) do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end

  defp measurement_workflow(workspace_root) do
    """
    ---
    tracker:
      kind: linear
      api_key: dummy
      project_slug: dummy
    workspace:
      root: #{workspace_root}
    codex:
      command: #{@codex_command}
      approval_policy: never
      thread_sandbox: danger-full-access
      turn_sandbox_policy:
        type: dangerFullAccess
    ---
    measurement
    """
  end

  defp git_output!(repo_root, args) do
    {output, 0} = System.cmd("git", args, cd: repo_root)
    String.trim(output)
  end
end

ContextPrunerTokenSavingsMeasurement.main()
