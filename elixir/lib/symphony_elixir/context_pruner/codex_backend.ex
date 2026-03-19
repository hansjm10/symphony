defmodule SymphonyElixir.ContextPruner.CodexBackend do
  @moduledoc false

  alias SymphonyElixir.HostShell

  @default_env_passthrough [
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "OPENAI_ORG_ID",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE"
  ]
  @default_model "gpt-5.3-codex-spark"
  @default_reasoning_effort "low"
  @default_timeout_kill_after "2s"

  @type config :: %{
          auth_file: String.t() | nil,
          executable: String.t() | nil,
          executable_hint: String.t(),
          model: String.t(),
          reasoning_effort: String.t(),
          timeout_ms: pos_integer(),
          passthrough_env: [String.t()]
        }

  @spec config(pos_integer(), map()) :: {config(), [String.t()]}
  def config(timeout_ms, env \\ System.get_env())
      when is_integer(timeout_ms) and timeout_ms > 0 and is_map(env) do
    executable_hint =
      env["CONTEXT_PRUNER_CODEX_BIN"]
      |> normalize_string()
      |> case do
        nil -> "codex"
        value -> value
      end

    executable = resolve_executable(executable_hint)
    auth_file = resolve_auth_file(env["CONTEXT_PRUNER_CODEX_AUTH_FILE"])
    model = normalize_string(env["CONTEXT_PRUNER_MODEL"]) || @default_model
    reasoning_effort = normalize_string(env["CONTEXT_PRUNER_REASONING_EFFORT"]) || @default_reasoning_effort

    passthrough_env =
      env["CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH"]
      |> parse_env_passthrough()

    warnings =
      []
      |> maybe_add_missing_executable_warning(executable, executable_hint)
      |> maybe_add_missing_auth_file_warning(env["CONTEXT_PRUNER_CODEX_AUTH_FILE"], auth_file)
      |> maybe_add_missing_auth_strategy_warning(auth_file, passthrough_env)

    {
      %{
        auth_file: auth_file,
        executable: executable,
        executable_hint: executable_hint,
        model: model,
        passthrough_env: passthrough_env,
        reasoning_effort: reasoning_effort,
        timeout_ms: timeout_ms
      },
      warnings
    }
  end

  @spec prune(String.t(), String.t(), config()) :: {String.t(), [String.t()]}
  def prune(code, query, %{executable: nil} = config)
      when is_binary(code) and is_binary(query) and is_map(config) do
    {code,
     [
       "[context-pruner] Codex backend executable #{inspect(config.executable_hint)} is unavailable; falling back to original content."
     ]}
  end

  def prune(code, query, config)
      when is_binary(code) and is_binary(query) and is_map(config) do
    temp_root =
      Path.join(
        System.tmp_dir!(),
        "context-pruner-codex-#{System.unique_integer([:positive])}"
      )

    home_dir = Path.join(temp_root, "home")
    workspace_dir = Path.join(temp_root, "workspace")
    prompt_path = Path.join(temp_root, "prompt.txt")
    output_path = Path.join(temp_root, "output.json")
    schema_path = Path.join(temp_root, "output.schema.json")

    File.mkdir_p!(home_dir)
    File.mkdir_p!(workspace_dir)
    File.mkdir_p!(Path.join(home_dir, ".codex"))
    File.mkdir_p!(Path.join(home_dir, ".config"))
    File.mkdir_p!(Path.join(home_dir, ".cache"))
    File.mkdir_p!(Path.join(home_dir, ".local/state"))
    maybe_copy_auth_file(config.auth_file, home_dir)
    File.write!(prompt_path, prompt(query, code))
    File.write!(schema_path, output_schema())

    try do
      with {:ok, shell} <- HostShell.resolve_local() do
        command =
          build_command(
            shell,
            config,
            workspace_dir,
            home_dir,
            prompt_path,
            output_path,
            schema_path
          )

        {combined_output, exit_code} = run_command(shell, command, workspace_dir)

        case {exit_code, read_output_file(output_path)} do
          {0, {:ok, pruned_text}} ->
            {pruned_text, []}

          {0, {:error, reason}} ->
            {code,
             [
               "[context-pruner] Codex backend returned an invalid output payload (#{reason}); falling back to original content."
             ]}

          {status, _} ->
            {code,
             [
               "[context-pruner] Codex backend exited with status #{status}; falling back to original content.",
               format_combined_output(combined_output)
             ]
             |> Enum.reject(&(&1 == ""))}
        end
      else
        {:error, message, status} ->
          {code,
           [
             "[context-pruner] Codex backend shell setup failed (#{message}); falling back to original content.",
             "[context-pruner] Codex backend exited with status #{status}; falling back to original content."
           ]}
      end
    rescue
      error in [File.Error] ->
        {code,
         [
           "[context-pruner] Codex backend setup failed (#{Exception.message(error)}); falling back to original content."
         ]}
    after
      File.rm_rf(temp_root)
    end
  end

  defp build_command(shell, config, workspace_dir, home_dir, prompt_path, output_path, schema_path) do
    env_map = build_env_map(config, home_dir)

    case shell.family do
      :windows ->
        build_windows_command(env_map, config, workspace_dir, prompt_path, output_path, schema_path)

      :posix ->
        build_posix_command(env_map, config, workspace_dir, prompt_path, output_path, schema_path)
    end
  end

  defp build_env_map(config, home_dir) do
    base_env = %{
      "HOME" => home_dir,
      "PATH" => System.get_env("PATH") || "",
      "TMPDIR" => System.tmp_dir!(),
      "XDG_CACHE_HOME" => Path.join(home_dir, ".cache"),
      "XDG_CONFIG_HOME" => Path.join(home_dir, ".config"),
      "XDG_STATE_HOME" => Path.join(home_dir, ".local/state")
    }

    passthrough_env =
      Enum.reduce(config.passthrough_env, %{}, fn name, acc ->
        case System.get_env(name) do
          nil -> acc
          value -> Map.put(acc, name, value)
        end
      end)

    Map.merge(base_env, passthrough_env)
  end

  defp build_posix_command(env_map, config, workspace_dir, prompt_path, output_path, schema_path) do
    env_assignments =
      Enum.map_join(env_map, " ", fn {key, value} ->
        "#{key}=#{HostShell.posix_escape(value)}"
      end)

    codex_args =
      [
        HostShell.posix_escape(config.executable),
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "--color",
        "never",
        "--cd",
        HostShell.posix_escape(workspace_dir),
        "--model",
        HostShell.posix_escape(config.model),
        "-c",
        HostShell.posix_escape("model_reasoning_effort=#{config.reasoning_effort}"),
        "--output-schema",
        HostShell.posix_escape(schema_path),
        "-o",
        HostShell.posix_escape(output_path),
        "-",
        "<",
        HostShell.posix_escape(prompt_path)
      ]
      |> Enum.join(" ")

    [
      timeout_prefix(config.timeout_ms),
      "env -i",
      env_assignments,
      codex_args
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp build_windows_command(env_map, config, workspace_dir, prompt_path, output_path, schema_path) do
    clear_env =
      "Get-ChildItem Env: | ForEach-Object { Remove-Item -Path (\"Env:\" + $_.Name) -ErrorAction SilentlyContinue }"

    set_env =
      Enum.map_join(env_map, "; ", fn {key, value} ->
        "$env:#{key}=#{HostShell.powershell_escape(value)}"
      end)

    codex_args =
      [
        "&",
        HostShell.powershell_escape(config.executable),
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "--color",
        "never",
        "--cd",
        HostShell.powershell_escape(workspace_dir),
        "--model",
        HostShell.powershell_escape(config.model),
        "-c",
        HostShell.powershell_escape("model_reasoning_effort=#{config.reasoning_effort}"),
        "--output-schema",
        HostShell.powershell_escape(schema_path),
        "-o",
        HostShell.powershell_escape(output_path),
        "-"
      ]
      |> Enum.join(" ")

    input_redirect = "Get-Content -Raw #{HostShell.powershell_escape(prompt_path)} | #{codex_args}"

    [clear_env, set_env, input_redirect]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
  end

  defp run_command(shell, command, workspace_dir) do
    SymphonyElixir.ProcessRunner.run(shell.executable, shell.args_prefix ++ [command],
      cd: workspace_dir,
      stderr_to_stdout: true
    )
  end

  defp read_output_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"pruned_text" => pruned_text}} when is_binary(pruned_text) <- Jason.decode(content) do
      {:ok, pruned_text}
    else
      {:ok, _content} ->
        {:error, "missing pruned_text"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp output_schema do
    Jason.encode!(%{
      "type" => "object",
      "required" => ["pruned_text"],
      "additionalProperties" => false,
      "properties" => %{
        "pruned_text" => %{"type" => "string"}
      }
    })
  end

  defp prompt(query, code) do
    """
    You are a constrained blank-state context-pruner worker.

    Rules:
    - Use only the supplied bounded source.
    - Do not inspect the filesystem.
    - Do not run tools or shell commands.
    - Do not add commentary, markdown fences, or explanations.
    - Return only the minimum verbatim text from the bounded source that answers the query.
    - If nothing in the bounded source is relevant, return an empty string.

    Query:
    #{query}

    Bounded source:
    ```text
    #{code}
    ```
    """
  end

  defp timeout_prefix(timeout_ms) do
    case System.find_executable("timeout") do
      nil ->
        ""

      timeout_bin ->
        seconds = Float.round(timeout_ms / 1_000, 3)
        "#{HostShell.posix_escape(timeout_bin)} --signal=TERM --kill-after=#{@default_timeout_kill_after} #{seconds}s"
    end
  end

  defp format_combined_output(output) when is_binary(output) do
    trimmed = String.trim(output)
    if trimmed == "", do: "", else: "[context-pruner] Codex backend output: #{trimmed}"
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp maybe_add_missing_executable_warning(warnings, nil, executable_hint) do
    warnings ++
      [
        "[context-pruner] Codex backend executable #{inspect(executable_hint)} was not found on PATH; falling back to original content."
      ]
  end

  defp maybe_add_missing_executable_warning(warnings, _executable, _executable_hint), do: warnings

  defp maybe_add_missing_auth_file_warning(warnings, nil, _auth_file), do: warnings

  defp maybe_add_missing_auth_file_warning(warnings, configured_auth_file, nil) do
    warnings ++
      [
        "[context-pruner] CONTEXT_PRUNER_CODEX_AUTH_FILE=#{inspect(configured_auth_file)} does not exist; blank-state Codex lookup may fail unless auth is provided through passthrough env."
      ]
  end

  defp maybe_add_missing_auth_file_warning(warnings, _configured_auth_file, _auth_file), do: warnings

  defp maybe_add_missing_auth_strategy_warning(warnings, auth_file, passthrough_env) do
    if auth_file == nil and not auth_env_available?(passthrough_env) do
      warnings ++
        [
          "[context-pruner] Blank-state Codex lookup has no explicit auth source. Set CONTEXT_PRUNER_CODEX_AUTH_FILE or pass OPENAI_API_KEY/OPENAI_BASE_URL through CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH."
        ]
    else
      warnings
    end
  end

  defp auth_env_available?(passthrough_env) when is_list(passthrough_env) do
    Enum.any?(passthrough_env, fn name ->
      name in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID"] and
        System.get_env(name) not in [nil, ""]
    end)
  end

  defp parse_env_passthrough(nil), do: @default_env_passthrough

  defp parse_env_passthrough(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> @default_env_passthrough
      values -> values
    end
  end

  defp resolve_executable(nil), do: nil

  defp resolve_executable(value) when is_binary(value) do
    cond do
      String.contains?(value, "/") and File.exists?(value) ->
        Path.expand(value)

      true ->
        System.find_executable(value)
    end
  end

  defp resolve_auth_file(nil), do: nil

  defp resolve_auth_file(value) when is_binary(value) do
    value
    |> normalize_string()
    |> case do
      nil ->
        nil

      trimmed ->
        expanded = Path.expand(trimmed)
        if File.regular?(expanded), do: expanded, else: nil
    end
  end

  defp maybe_copy_auth_file(nil, _home_dir), do: :ok

  defp maybe_copy_auth_file(auth_file, home_dir) when is_binary(auth_file) do
    auth_target = Path.join([home_dir, ".codex", "auth.json"])
    File.cp!(auth_file, auth_target)
    File.chmod!(auth_target, 0o600)
  end
end
