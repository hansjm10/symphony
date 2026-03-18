defmodule ContextPrunerTokenSavingsMeasurement do
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.ContextPruner.CLI
  alias SymphonyElixir.Linear.Issue

  @baseline_workflow_ref "24b6e23"
  @default_pruner_url "http://192.168.1.15:8000/prune"
  @direct_probe_timeout_ms 10_000
  @codex_command "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server"

  def main do
    repo_root = Path.expand("../..", __DIR__)
    elixir_root = Path.expand("..", __DIR__)
    workspace_root = Path.dirname(repo_root)
    workspace = repo_root
    current_head = git_output!(repo_root, ["rev-parse", "HEAD"])
    current_short_head = git_output!(repo_root, ["rev-parse", "--short", "HEAD"])
    baseline_short_head = git_output!(repo_root, ["rev-parse", "--short", @baseline_workflow_ref])
    pruner_url = pruner_url()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    workflow_dir = Path.join(System.tmp_dir!(), "symphony-context-pruner-measure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workflow_dir)

    workflow_path = Path.join(workflow_dir, "WORKFLOW.measurement.md")
    File.write!(workflow_path, measurement_workflow(workspace_root))

    output_path = Path.join(elixir_root, "docs/measurements/idl-1144-context-pruner-token-savings-2026-03-18.json")
    issue = measurement_issue()
    original_workflow_path = Workflow.workflow_file_path()

    try do
      Workflow.set_workflow_file_path(workflow_path)

      baseline_run =
        run_variant(
          "baseline",
          baseline_prompt(repo_root),
          workspace,
          issue,
          %{
            "PRUNER_URL" => pruner_url,
            "JEEVES_PRUNER_URL" => "",
            "PATH" => System.get_env("PATH")
          }
        )

      current_run =
        run_variant(
          "context_pruner",
          context_pruner_prompt(repo_root),
          workspace,
          issue,
          %{
            "PRUNER_URL" => pruner_url,
            "JEEVES_PRUNER_URL" => "",
            "PATH" => prepend_to_path(repo_root, System.get_env("PATH"))
          }
        )

      remote_verification = verify_remote_pruner(pruner_url, repo_root)

      baseline_total = baseline_run["finalThreadTotal"]["totalTokens"]
      current_total = current_run["finalThreadTotal"]["totalTokens"]
      saved_tokens = baseline_total - current_total

      report = %{
        "capturedAt" => timestamp,
        "workspace" => workspace,
        "workspaceRoot" => workspace_root,
        "baselineWorkflowRef" => @baseline_workflow_ref,
        "baselineWorkflowShortRef" => baseline_short_head,
        "currentWorkflowRef" => current_head,
        "currentWorkflowShortRef" => current_short_head,
        "codexModelCommand" => @codex_command,
        "accountingMethod" => %{
          "authoritativeEvent" => "thread/tokenUsage/updated",
          "authoritativePayloadPath" => "params.tokenUsage.total",
          "ignoredFieldsForCumulativeAccounting" => [
            "params.tokenUsage.last",
            "TokenCountEvent.info.last_token_usage",
            "generic usage maps",
            "turn/completed usage"
          ]
        },
        "comparisonSetup" => %{
          "workspaceTree" => current_short_head,
          "baselineGuidanceSource" => "#{@baseline_workflow_ref}:elixir/WORKFLOW.md (pre-context-pruner workflow)",
          "currentGuidanceSource" => "#{current_short_head}:elixir/WORKFLOW.md (context discovery and reads block)",
          "taskIssue" => issue_to_map(issue),
          "notes" => [
            "Both runs used the same workspace tree at the current checkout head.",
            "Both runs used the same minimal single-turn measurement scaffold and identical task prompt.",
            "The baseline variant used ordinary shell-tool guidance with no context-pruner instructions.",
            "The context-pruner variant added the current workflow's context-pruner guidance so the experiment isolated the context-gathering change instead of ticket-lifecycle behavior.",
            "For the current run only, PATH was prefixed with the checked-in repo root so `context-pruner` was discoverable the same way a fresh Symphony workspace would expose it after `after_create`."
          ]
        },
        "runs" => [baseline_run, current_run],
        "comparison" => %{
          "baselineTotalTokens" => baseline_total,
          "contextPrunerTotalTokens" => current_total,
          "absoluteDeltaTokens" => current_total - baseline_total,
          "absoluteSavingsTokens" => saved_tokens,
          "percentageDelta" => percentage_delta(baseline_total, current_total - baseline_total),
          "percentageSavings" => percentage_delta(baseline_total, saved_tokens)
        },
        "remoteVerification" => remote_verification
      }

      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, Jason.encode!(report, pretty: true))
      IO.puts(output_path)
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(workflow_dir)
    end
  end

  defp measurement_issue do
    %Issue{
      id: "measurement-context-pruner-token-savings",
      identifier: "MEASURE-CP-1",
      title: "Dry-run context gathering measurement",
      state: "Measurement",
      url: "https://example.invalid/MEASURE-CP-1",
      labels: ["measurement", "dry-run"],
      description: """
      Single-turn dry-run measurement task used only for comparing context discovery token usage.
      """
    }
  end

  defp issue_to_map(%Issue{} = issue) do
    issue
    |> Map.from_struct()
    |> Enum.into(%{}, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp run_variant(name, prompt, workspace, issue, env_overrides) do
    {:ok, collector} = Agent.start_link(fn -> [] end)

    start_ms = System.monotonic_time(:millisecond)

    result =
      with_temporary_env(env_overrides, fn ->
        AppServer.run(
          workspace,
          prompt,
          issue,
          on_message: fn message ->
            Agent.update(collector, &[message | &1])
          end
        )
      end)

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
      "commandHints" => extract_command_hints(messages),
      "usedContextPruner" => used_context_pruner?(messages),
      "messages" => encode_messages(messages)
    }
  end

  defp verify_remote_pruner(pruner_url, repo_root) do
    {:ok, _started} = Application.ensure_all_started(:req)

    payload = %{
      "code" => "function alpha() {}\nfunction beta() {}\nconst target = beta;",
      "query" => "What mentions beta?"
    }

    {:ok, response} =
      Req.post(pruner_url,
        connect_options: [timeout: @direct_probe_timeout_ms],
        receive_timeout: @direct_probe_timeout_ms,
        retry: false,
        json: payload
      )

    body = response.body

    cli_result =
      with_temporary_env(%{"PRUNER_URL" => pruner_url, "JEEVES_PRUNER_URL" => ""}, fn ->
        CLI.evaluate([
          "read",
          "--file-path",
          Path.join(repo_root, "elixir/docs/context_pruner.md"),
          "--around-line",
          "49",
          "--radius",
          "6",
          "--focus",
          "Keep only the env contract and the primary response field."
        ])
      end)

    %{
      "endpoint" => pruner_url,
      "requestPayloadShape" => payload,
      "httpStatus" => response.status,
      "responseKeys" => body |> Map.keys() |> Enum.sort(),
      "primaryResponseField" => "pruned_code",
      "primaryResponseFieldPresent" => is_binary(body["pruned_code"]),
      "responseExcerpt" => %{
        "pruned_code" => body["pruned_code"],
        "origin_token_cnt" => body["origin_token_cnt"],
        "left_token_cnt" => body["left_token_cnt"],
        "model_input_token_cnt" => body["model_input_token_cnt"]
      },
      "cliFocusVerification" => %{
        "exitCode" => cli_result.exit_code,
        "stderr" => cli_result.stderr,
        "stdout" => cli_result.stdout
      }
    }
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

  defp payload_path(_message, []), do: nil

  defp payload_path_segments(current, []), do: current

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

  defp collect_command_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_command_strings/1)
  defp collect_command_strings(_value), do: []

  defp used_context_pruner?(messages) do
    messages
    |> extract_command_hints()
    |> Enum.any?(fn command ->
      String.starts_with?(command, "context-pruner ") or
        String.contains?(command, "-lc \"context-pruner ") or
        String.contains?(command, "-lc 'context-pruner ")
    end)
  end

  defp encode_messages(messages) do
    Enum.map(messages, fn message ->
      message
      |> normalize_term()
      |> maybe_limit_raw()
    end)
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
  defp normalize_term(value), do: value

  defp maybe_limit_raw(%{"raw" => raw} = message) when is_binary(raw) and byte_size(raw) > 5_000 do
    Map.put(message, "raw", String.slice(raw, 0, 5_000) <> "\n(truncated)")
  end

  defp maybe_limit_raw(message), do: message

  defp normalize_run_result({:ok, result}) when is_map(result) do
    %{"status" => "ok", "result" => normalize_term(result)}
  end

  defp normalize_run_result({:error, reason}) do
    %{"status" => "error", "reason" => inspect(reason)}
  end

  defp prepend_to_path(prefix, current_path) when is_binary(current_path) and current_path != "" do
    prefix <> ":" <> current_path
  end

  defp prepend_to_path(prefix, _current_path), do: prefix

  defp pruner_url do
    case System.get_env("PRUNER_URL") || System.get_env("JEEVES_PRUNER_URL") do
      value when is_binary(value) and value != "" -> value
      _ -> @default_pruner_url
    end
  end

  defp inject_measurement_override(workflow_content) when is_binary(workflow_content) do
    lines = String.split(workflow_content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front_matter, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] ->
            Enum.join(
              ["---" | front_matter] ++
                [
                  "---",
                  "",
                  measurement_override_prompt(),
                  ""
                ] ++ prompt_lines,
              "\n"
            )

          _ ->
            measurement_override_prompt() <> "\n\n" <> workflow_content
        end

      _ ->
        measurement_override_prompt() <> "\n\n" <> workflow_content
    end
  end

  defp measurement_override_prompt do
    """
    Synthetic measurement override:

    - This prompt is being executed only to measure repository-context token usage.
    - Do not use `linear_graphql`.
    - Skip workpad maintenance, issue state changes, PR handling, review flow, and any other tracker lifecycle steps.
    - Inspect repository files and shell output only as needed to answer the ticket description.
    - End the turn immediately after a short Markdown answer to the ticket description.
    """
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

  defp baseline_prompt(repo_root) do
    """
    You are running a synthetic single-turn measurement inside the repository at `#{repo_root}`.

    Task:
    - Inspect the repository only.
    - Do not use `linear_graphql`.
    - Do not change files.
    - Do not send progress updates or plans.
    - Use at most 3 shell commands total.
    - Use ordinary shell tools such as `rg`, `sed`, and short `bash` commands when you need context.
    - Keep reads and searches narrow.
    - Answer in exactly 4 bullet points and end the turn immediately afterward.

    Questions:
    - Bullet 1: the authoritative cumulative token event and payload path.
    - Bullet 2: the delta or generic usage fields to ignore.
    - Bullet 3: the preferred context-pruner environment variable and compatibility alias.
    - Bullet 4: the remote prune request payload shape and primary response field.
    """
  end

  defp context_pruner_prompt(repo_root) do
    """
    You are running a synthetic single-turn measurement inside the repository at `#{repo_root}`.

    Task:
    - Inspect the repository only.
    - Do not use `linear_graphql`.
    - Do not change files.
    - Do not send progress updates or plans.
    - Use at most 3 shell commands total.
    - Prefer `context-pruner` before broad `cat`, `sed`, `rg`, or ad hoc shell output when you need repository context.
    - Start with the narrowest command that can answer the question:
      - `context-pruner read --file-path <path> --start-line <n> --end-line <n>` or `--around-line <n> --radius <n>` for known files.
      - `context-pruner grep --pattern <regex> --path <path> --context-lines <n> --max-matches <n>` for bounded search.
      - `context-pruner bash --command "<command>"` only when the answer must come from shell output rather than directly from files.
    - Add `--focus` only after the file window, search path, and match counts are already narrow enough that pruning has a clear target.
    - Prefer `PRUNER_URL`; use `JEEVES_PRUNER_URL` only as a compatibility alias when `PRUNER_URL` is unset.
    - Answer in exactly 4 bullet points and end the turn immediately afterward.

    Questions:
    - Bullet 1: the authoritative cumulative token event and payload path.
    - Bullet 2: the delta or generic usage fields to ignore.
    - Bullet 3: the preferred context-pruner environment variable and compatibility alias.
    - Bullet 4: the remote prune request payload shape and primary response field.
    """
  end

  defp percentage_delta(0, _value), do: nil

  defp percentage_delta(base, value) when is_integer(base) and is_integer(value) do
    Float.round(value / base * 100.0, 2)
  end

  defp line_count(text) when is_binary(text) do
    text
    |> String.split(~r/\R/, trim: false)
    |> length()
  end

  defp git_output!(repo_root, args) do
    {output, 0} = System.cmd("git", args, cd: repo_root)
    String.trim(output)
  end
end

ContextPrunerTokenSavingsMeasurement.main()
