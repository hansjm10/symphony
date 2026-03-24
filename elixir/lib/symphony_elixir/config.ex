defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @default_review_prompt_template """
  You are performing a Codex Review for a Linear issue.

  Review scope:
  - Inspect the current local workspace changes as a fresh reviewer.
  - Do not edit files or implement fixes in this session.
  - If you find actionable issues, update the issue state to `Rework` and record concise findings.
  - If the change is clean, keep the review outcome concise and do not move the issue to human `In Review` unless the workflow explicitly requires it.

  Issue context:
  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}
  Current status: {{ issue.state }}

  Description:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type session_kind :: :implementation | :codex_review | :rework

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt(session_kind()) :: String.t()
  def workflow_prompt(session_kind \\ :implementation)

  def workflow_prompt(:codex_review) do
    case Workflow.current() do
      {:ok, %{review_prompt_template: prompt}} ->
        default_prompt(prompt, @default_review_prompt_template)

      _ ->
        @default_review_prompt_template
    end
  end

  def workflow_prompt(_session_kind) do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        default_prompt(prompt, @default_prompt_template)

      _ ->
        @default_prompt_template
    end
  end

  @spec codex_command(session_kind()) :: String.t() | map()
  def codex_command(session_kind \\ :implementation)

  def codex_command(:codex_review) do
    settings = settings!()
    settings.codex_review.command || settings.codex.command
  end

  def codex_command(_session_kind), do: settings!().codex.command

  @spec max_turns(session_kind()) :: pos_integer()
  def max_turns(:codex_review), do: settings!().codex_review.max_turns
  def max_turns(_session_kind), do: settings!().agent.max_turns

  @spec codex_review_enabled?() :: boolean()
  def codex_review_enabled? do
    settings!().codex_review.enabled == true
  end

  @spec session_kind_for_issue_state(term()) :: session_kind()
  def session_kind_for_issue_state(state_name) when is_binary(state_name) do
    normalized_state = Schema.normalize_issue_state(state_name)
    normalized_review_state = settings!().codex_review.state |> normalize_session_state()

    cond do
      codex_review_enabled?() and normalized_review_state != nil and normalized_state == normalized_review_state ->
        :codex_review

      normalized_state == "rework" ->
        :rework

      true ->
        :implementation
    end
  end

  def session_kind_for_issue_state(_state_name), do: :implementation

  @spec session_kind_name(session_kind()) :: String.t()
  def session_kind_name(:implementation), do: "implementation"
  def session_kind_name(:codex_review), do: "codex_review"
  def session_kind_name(:rework), do: "rework"

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    case Application.get_env(:symphony_elixir, :server_host_override) do
      host when is_binary(host) ->
        trimmed_host = String.trim(host)
        if trimmed_host == "", do: settings!().server.host, else: trimmed_host

      _ ->
        settings!().server.host
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      settings.codex_review.enabled == true and not codex_review_state_active?(settings) ->
        {:error, {:codex_review_state_not_active, settings.codex_review.state}}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      {:codex_review_state_not_active, state_name} ->
        "Invalid WORKFLOW.md config: codex_review.state #{inspect(state_name)} must be included in tracker.active_states"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end

  defp codex_review_state_active?(settings) do
    normalized_review_state = normalize_session_state(settings.codex_review.state)

    is_binary(normalized_review_state) and
      Enum.any?(settings.tracker.active_states, fn active_state ->
        normalize_session_state(active_state) == normalized_review_state
      end)
  end

  defp normalize_session_state(state_name) when is_binary(state_name) do
    case String.trim(state_name) do
      "" -> nil
      trimmed -> Schema.normalize_issue_state(trimmed)
    end
  end

  defp normalize_session_state(_state_name), do: nil

  defp default_prompt(prompt, fallback) when is_binary(fallback) do
    if is_binary(prompt) and String.trim(prompt) != "" do
      prompt
    else
      fallback
    end
  end
end
