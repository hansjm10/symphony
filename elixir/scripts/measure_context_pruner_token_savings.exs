defmodule ContextPrunerTokenSavingsMeasurement do
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.ContextPruner.{CLI, Pruner}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  @artifact_slug "idl-1149-constrained-blank-state-context-pruner"
  @default_lookup_model "gpt-5.3-codex-spark"
  @default_lookup_reasoning_effort "low"
  @default_main_codex_command "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server"

  def main do
    repo_root = Path.expand("../..", __DIR__)
    elixir_root = Path.expand("..", __DIR__)
    output_dir = Path.join(elixir_root, "docs/measurements")
    captured_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    captured_date = Date.utc_today() |> Date.to_iso8601()
    current_head = git_output!(repo_root, ["rev-parse", "HEAD"])
    current_short_head = git_output!(repo_root, ["rev-parse", "--short", "HEAD"])
    benchmark_case = benchmark_case()
    lookup_env = lookup_env(repo_root)
    {lookup_config, lookup_warnings} = Pruner.config(Map.merge(System.get_env(), lookup_env))

    if lookup_config.kind != :codex or not lookup_config.enabled do
      raise """
      Codex-backed lookup measurement requires an available Codex backend.
      Set `CONTEXT_PRUNER_CODEX_BIN` or `MEASURE_CONTEXT_PRUNER_LOOKUP_CODEX_BIN` to a working Codex CLI binary if `codex` is not on PATH.
      """
    end

    comparison = measure_main_thread_case(repo_root, benchmark_case, lookup_env)
    command_probe = measure_command_probe(repo_root, lookup_env)
    scope_probe = measure_scope_probe(repo_root, lookup_env)

    json_file_name = "#{@artifact_slug}-#{captured_date}.json"
    markdown_file_name = "#{@artifact_slug}-#{captured_date}.md"
    json_path = Path.join(output_dir, json_file_name)
    markdown_path = Path.join(output_dir, markdown_file_name)

    report = %{
      "measurementId" => "IDL-1149",
      "capturedAt" => captured_at,
      "workspace" => repo_root,
      "workspaceTree" => current_short_head,
      "workspaceTreeRef" => current_head,
      "artifacts" => %{
        "jsonPath" => Path.relative_to(json_path, repo_root),
        "markdownPath" => Path.relative_to(markdown_path, repo_root),
        "scriptPath" => "elixir/scripts/measure_context_pruner_token_savings.exs"
      },
      "rerun" => %{
        "defaultCommand" => "cd elixir && mise exec -- mix run --no-start scripts/measure_context_pruner_token_savings.exs",
        "lookupAuthFileEnv" => "MEASURE_CONTEXT_PRUNER_LOOKUP_CODEX_AUTH_FILE",
        "lookupModelEnv" => "MEASURE_CONTEXT_PRUNER_LOOKUP_MODEL",
        "lookupReasoningEnv" => "MEASURE_CONTEXT_PRUNER_LOOKUP_REASONING_EFFORT",
        "lookupCodexBinEnv" => "MEASURE_CONTEXT_PRUNER_LOOKUP_CODEX_BIN"
      },
      "lookupBackend" => %{
        "kind" => Atom.to_string(lookup_config.kind),
        "model" => get_in(lookup_config, [:codex, :model]),
        "reasoningEffort" => get_in(lookup_config, [:codex, :reasoning_effort]),
        "scope" => %{
          "allowedRoots" => split_csv(Map.get(lookup_env, "CONTEXT_PRUNER_ALLOWED_ROOTS"))
        },
        "isolationContract" => %{
          "passedIn" => [
            "bounded query text",
            "bounded source text from the local selector",
            "explicit Codex model selection",
            "explicit auth material through passthrough env or CONTEXT_PRUNER_CODEX_AUTH_FILE",
            "narrow env passthrough list for auth/network only"
          ],
          "notInherited" => [
            "the parent Codex session id",
            "the parent workflow prompt",
            "the parent repo working directory",
            "the parent HOME/.codex config tree"
          ],
          "workerCwd" => "fresh temporary directory outside the repository",
          "forbidden" => [
            "repo reads outside the local selector result",
            "arbitrary `lookup --command` sources",
            "file reads outside `CONTEXT_PRUNER_ALLOWED_ROOTS`/`PATHS`/`GLOBS`"
          ]
        },
        "warnings" => lookup_warnings
      },
      "mainThreadComparison" => comparison,
      "constraintProbes" => %{
        "commandSourceProbe" => normalize_cli_result(command_probe),
        "scopeEscapeProbe" => normalize_cli_result(scope_probe)
      }
    }

    File.mkdir_p!(output_dir)
    File.write!(json_path, Jason.encode!(report, pretty: true))
    File.write!(markdown_path, render_markdown(report))

    IO.puts(json_path)
    IO.puts(markdown_path)
  end

  defp benchmark_case do
    %{
      id: "env_contract_lookup",
      source_file_path: "elixir/docs/context_pruner.md",
      source_start_line: 94,
      source_end_line: 179,
      inline_source_command: "sed -n '94,179p' elixir/docs/context_pruner.md",
      lookup_query: "Keep only the preferred remote env vars, the compatibility alias rule, the request body shape, and the primary response field.",
      lookup_command:
        "context-pruner lookup --query \"Keep only the preferred remote env vars, the compatibility alias rule, the request body shape, and the primary response field.\" --file-path elixir/docs/context_pruner.md --start-line 94 --end-line 179",
      questions: [
        "Bullet 1: the primary remote environment variables.",
        "Bullet 2: the compatibility alias and when it is accepted.",
        "Bullet 3: the remote request body shape.",
        "Bullet 4: the primary response field."
      ]
    }
  end

  defp lookup_env(repo_root) do
    auth_file =
      System.get_env("MEASURE_CONTEXT_PRUNER_LOOKUP_CODEX_AUTH_FILE") ||
        default_codex_auth_file()

    %{
      "CONTEXT_PRUNER_ALLOWED_ROOTS" => "elixir/docs",
      "CONTEXT_PRUNER_BACKEND" => "codex",
      "CONTEXT_PRUNER_CODEX_AUTH_FILE" => auth_file,
      "CONTEXT_PRUNER_CODEX_BIN" =>
        System.get_env("MEASURE_CONTEXT_PRUNER_LOOKUP_CODEX_BIN") ||
          System.get_env("CONTEXT_PRUNER_CODEX_BIN"),
      "CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH" =>
        System.get_env("MEASURE_CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH") ||
          System.get_env("CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH") || "",
      "CONTEXT_PRUNER_MODEL" => System.get_env("MEASURE_CONTEXT_PRUNER_LOOKUP_MODEL") || @default_lookup_model,
      "CONTEXT_PRUNER_REASONING_EFFORT" =>
        System.get_env("MEASURE_CONTEXT_PRUNER_LOOKUP_REASONING_EFFORT") ||
          @default_lookup_reasoning_effort,
      "PATH" => repo_root <> ":" <> (System.get_env("PATH") || "")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp measure_main_thread_case(repo_root, benchmark_case, lookup_env) do
    workspace_root = Path.dirname(repo_root)
    issue = measurement_issue()
    inline_source = read_source_window!(repo_root, benchmark_case)
    lookup_result = run_lookup_preparation!(repo_root, benchmark_case, lookup_env)

    with_measurement_workflow(repo_root, workspace_root, fn ->
      inline_variant =
        run_prompt_variant(
          "#{benchmark_case.id}_inline",
          inline_prompt(benchmark_case, inline_source),
          repo_root,
          issue,
          [benchmark_case.inline_source_command]
        )

      lookup_variant =
        run_prompt_variant(
          "#{benchmark_case.id}_lookup",
          lookup_prompt(benchmark_case, lookup_result.stdout),
          repo_root,
          issue,
          [benchmark_case.lookup_command]
        )

      inline_total = inline_variant["finalThreadTotal"]["totalTokens"]
      lookup_total = lookup_variant["finalThreadTotal"]["totalTokens"]
      token_savings = inline_total - lookup_total

      if token_savings <= 0 do
        raise """
        Expected the lookup-assisted benchmark to reduce main-thread token usage, but measured #{token_savings} tokens.
        Adjust the bounded source window or query so the lookup worker returns materially less context than the inline broad read.
        """
      end

      %{
        "caseId" => benchmark_case.id,
        "sourceWindow" => %{
          "filePath" => benchmark_case.source_file_path,
          "startLine" => benchmark_case.source_start_line,
          "endLine" => benchmark_case.source_end_line,
          "inlineSourceCommand" => benchmark_case.inline_source_command,
          "sourceByteCount" => byte_size(inline_source),
          "sourceLineCount" => line_count(inline_source)
        },
        "lookupPreparation" => %{
          "command" => benchmark_case.lookup_command,
          "exitCode" => lookup_result.exit_code,
          "stderr" => sanitize_text(lookup_result.stderr),
          "returnedByteCount" => byte_size(lookup_result.stdout),
          "returnedLineCount" => line_count(lookup_result.stdout),
          "returnedText" => sanitize_text(lookup_result.stdout),
          "tokenSavingsRequires" => "The lookup worker runs before the measured main-thread turn; only the returned excerpt enters the measured prompt."
        },
        "inlineVariant" => inline_variant,
        "lookupVariant" => lookup_variant,
        "comparison" => %{
          "inlineTotalTokens" => inline_total,
          "lookupTotalTokens" => lookup_total,
          "tokenSavings" => token_savings,
          "percentageSavings" => percentage_savings(inline_total, token_savings)
        }
      }
    end)
  end

  defp measure_command_probe(repo_root, lookup_env) do
    with_temporary_env(
      Map.merge(lookup_env, %{"CONTEXT_PRUNER_CWD" => repo_root}),
      fn ->
        CLI.evaluate([
          "lookup",
          "--query",
          "Summarize alpha.",
          "--command",
          "printf 'alpha'"
        ])
      end
    )
  end

  defp measure_scope_probe(repo_root, lookup_env) do
    with_temporary_env(
      Map.merge(lookup_env, %{"CONTEXT_PRUNER_CWD" => repo_root}),
      fn ->
        CLI.evaluate([
          "lookup",
          "--query",
          "Keep only the backend config.",
          "--file-path",
          "SPEC.md",
          "--start-line",
          "1",
          "--end-line",
          "5"
        ])
      end
    )
  end

  defp inline_prompt(benchmark_case, inline_source) do
    questions = Enum.map_join(benchmark_case.questions, "\n", &"- #{&1}")

    measurement_prompt(
      "broad inline repository read",
      benchmark_case.inline_source_command,
      inline_source,
      questions
    )
  end

  defp lookup_prompt(benchmark_case, lookup_output) do
    questions = Enum.map_join(benchmark_case.questions, "\n", &"- #{&1}")

    measurement_prompt(
      "constrained blank-state lookup result",
      benchmark_case.lookup_command,
      lookup_output,
      questions
    )
  end

  defp measurement_prompt(context_kind, source_hint, excerpt, questions) do
    """
    You are running a synthetic single-turn main-thread token measurement.

    Task:
    - Use only the supplied repository excerpt.
    - Do not run tools or shell commands.
    - Do not inspect the repository beyond the supplied excerpt.
    - Answer in exactly 4 bullet points and end the turn immediately afterward.

    Context kind: #{context_kind}
    Source hint: `#{source_hint}`

    Repository excerpt:
    ```text
    #{excerpt}
    ```

    Questions:
    #{questions}
    """
  end

  defp measurement_issue do
    %Issue{
      id: "measurement-context-pruner-low-context-lookup",
      identifier: "MEASURE-CP-LOOKUP-1",
      title: "Context-pruner blank-state lookup measurement",
      state: "Measurement",
      url: "https://example.invalid/MEASURE-CP-LOOKUP-1",
      labels: ["measurement", "dry-run"],
      description: """
      Synthetic single-turn measurement task used only for comparing broad inline repository reads versus constrained blank-state context-pruner lookup.
      """
    }
  end

  defp with_measurement_workflow(repo_root, workspace_root, fun) when is_function(fun, 0) do
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

      with_temporary_env(%{"CONTEXT_PRUNER_CWD" => repo_root}, fn ->
        fun.()
      end)
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(workflow_dir)
    end
  end

  defp run_prompt_variant(name, prompt, workspace, issue, command_hints) do
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
      "durationMs" => duration_ms,
      "promptByteCount" => byte_size(prompt),
      "promptLineCount" => line_count(prompt),
      "result" => normalize_run_result(result),
      "methodsSeen" => message_method_counts(messages),
      "threadTotalSnapshots" => thread_updates,
      "finalThreadTotal" => final_thread_total,
      "turnCompletedUsage" => extract_turn_completed_usage(messages),
      "commandHints" => Enum.uniq(command_hints ++ extract_command_hints(messages))
    }
  end

  defp render_markdown(report) do
    comparison = report["mainThreadComparison"]
    inline_variant = comparison["inlineVariant"]
    lookup_variant = comparison["lookupVariant"]
    comparison_summary = comparison["comparison"]
    source_window = comparison["sourceWindow"]
    lookup_preparation = comparison["lookupPreparation"]
    lookup_backend = report["lookupBackend"]
    scope_probe = get_in(report, ["constraintProbes", "scopeEscapeProbe"])
    command_probe = get_in(report, ["constraintProbes", "commandSourceProbe"])

    [
      "# IDL-1149 Constrained Blank-State Context-Pruner Report\n\n",
      "Captured on #{report["capturedAt"]} from workspace tree `#{report["workspaceTree"]}`.\n\n",
      "## Goal\n\n",
      "Compare a broad inline main-thread discovery path with a constrained blank-state lookup path that returns only the minimal result.\n\n",
      "## Lookup Backend\n\n",
      "- Backend: `#{lookup_backend["kind"]}`\n",
      "- Model: `#{lookup_backend["model"]}`\n",
      "- Reasoning effort: `#{lookup_backend["reasoningEffort"]}`\n",
      "- Allowed roots: `#{Enum.join(get_in(lookup_backend, ["scope", "allowedRoots"]), "`, `")}`\n",
      "- Not inherited: `#{Enum.join(get_in(lookup_backend, ["isolationContract", "notInherited"]), "`, `")}`\n\n",
      "## Main-Thread Comparison\n\n",
      "- Shared bounded source window: `#{source_window["filePath"]}:#{source_window["startLine"]}-#{source_window["endLine"]}`\n",
      "- Inline broad-read source: `#{source_window["inlineSourceCommand"]}` (#{source_window["sourceLineCount"]} lines, #{source_window["sourceByteCount"]} bytes)\n",
      "- Lookup worker command: `#{lookup_preparation["command"]}`\n",
      "- Lookup worker return payload: #{lookup_preparation["returnedLineCount"]} lines, #{lookup_preparation["returnedByteCount"]} bytes\n",
      "- Lookup staging rule: #{lookup_preparation["tokenSavingsRequires"]}\n\n",
      "| Variant | Total tokens | Command hints |\n",
      "| --- | ---: | --- |\n",
      "| inline broad reads | #{inline_variant["finalThreadTotal"]["totalTokens"]} | `#{Enum.join(inline_variant["commandHints"], "`, `")}` |\n",
      "| lookup-assisted | #{lookup_variant["finalThreadTotal"]["totalTokens"]} | `#{Enum.join(lookup_variant["commandHints"], "`, `")}` |\n\n",
      "- Savings on the main thread: #{display_signed_metric(comparison_summary["tokenSavings"])} tokens (#{display_percent(comparison_summary["percentageSavings"])}).\n",
      "- Inline prompt bytes: #{inline_variant["promptByteCount"]}; lookup prompt bytes: #{lookup_variant["promptByteCount"]}.\n",
      "- Inline methods seen: `#{Enum.join(Map.keys(inline_variant["methodsSeen"]) |> Enum.sort(), "`, `")}`.\n",
      "- Lookup methods seen: `#{Enum.join(Map.keys(lookup_variant["methodsSeen"]) |> Enum.sort(), "`, `")}`.\n",
      "- Lookup worker stderr during staging: `#{lookup_preparation["stderr"]}`.\n\n",
      "## Constraint Probes\n\n",
      "- Command source probe: exit #{command_probe["exitCode"]}, stderr `#{command_probe["stderr"]}`.\n",
      "- Scope escape probe: exit #{scope_probe["exitCode"]}, stderr `#{scope_probe["stderr"]}`.\n\n",
      "## Rerun\n\n",
      "```bash\n",
      report["rerun"]["defaultCommand"],
      "\n```\n"
    ]
    |> IO.iodata_to_binary()
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
      command: #{measurement_codex_command()}
      approval_policy: never
      thread_sandbox: danger-full-access
      turn_sandbox_policy:
        type: dangerFullAccess
    ---
    measurement
    """
  end

  defp measurement_codex_command do
    System.get_env("MEASURE_CONTEXT_PRUNER_MAIN_CODEX_COMMAND") || @default_main_codex_command
  end

  defp default_codex_auth_file do
    auth_path = Path.join(System.user_home!(), ".codex/auth.json")
    if File.regular?(auth_path), do: auth_path, else: nil
  end

  defp read_source_window!(repo_root, benchmark_case) do
    source_path = Path.join(repo_root, benchmark_case.source_file_path)
    content = File.read!(source_path)

    content
    |> String.split(~r/\r\n|\n|\r/, trim: false)
    |> drop_trailing_empty_line()
    |> render_line_window(benchmark_case.source_start_line, benchmark_case.source_end_line)
  end

  defp render_line_window(lines, start_line, end_line) do
    bounded_start = max(start_line, 1)
    bounded_end = min(end_line, length(lines))

    if lines == [] or bounded_start > bounded_end do
      "(no lines in range)"
    else
      bounded_start..bounded_end
      |> Enum.map_join("\n", fn line_no -> "#{line_no}: #{Enum.at(lines, line_no - 1, "")}" end)
      |> Kernel.<>("\n")
    end
  end

  defp run_lookup_preparation!(repo_root, benchmark_case, lookup_env) do
    env = Map.merge(lookup_env, %{"CONTEXT_PRUNER_CWD" => repo_root})

    result =
      with_temporary_env(env, fn ->
        CLI.evaluate([
          "lookup",
          "--query",
          benchmark_case.lookup_query,
          "--file-path",
          benchmark_case.source_file_path,
          "--start-line",
          Integer.to_string(benchmark_case.source_start_line),
          "--end-line",
          Integer.to_string(benchmark_case.source_end_line)
        ])
      end)

    if result.exit_code != 0 do
      raise """
      Lookup preparation failed with exit #{result.exit_code}.
      stderr: #{result.stderr}
      stdout: #{result.stdout}
      """
    end

    result
  end

  defp normalize_cli_result(result) do
    %{
      "exitCode" => result.exit_code,
      "stderr" => sanitize_text(result.stderr),
      "stdout" => sanitize_text(result.stdout)
    }
  end

  defp split_csv(nil), do: []

  defp split_csv(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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

  defp display_signed_metric(nil), do: "n/a"
  defp display_signed_metric(value) when value >= 0, do: "+" <> Integer.to_string(value)
  defp display_signed_metric(value), do: Integer.to_string(value)

  defp display_percent(nil), do: "n/a"
  defp display_percent(value), do: "#{value}%"

  defp sanitize_text(value) when is_binary(value), do: String.replace_invalid(value, "ï¿½")
  defp sanitize_text(value), do: value

  defp git_output!(repo_root, args) do
    {output, 0} = System.cmd("git", args, cd: repo_root)
    String.trim(output)
  end
end

ContextPrunerTokenSavingsMeasurement.main()
