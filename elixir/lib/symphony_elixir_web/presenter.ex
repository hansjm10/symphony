defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: token_totals_payload(snapshot.codex_totals),
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, issue_conversation(issue_identifier, orchestrator, snapshot_timeout_ms))}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec telemetry_payload(GenServer.name(), timeout()) :: map()
  def telemetry_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.telemetry_snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          summary: telemetry_summary_payload(snapshot.summary),
          events: Enum.map(snapshot.events, &telemetry_event_payload/1)
        }

      :timeout ->
        telemetry_error_payload(generated_at, "snapshot_timeout", "Snapshot timed out")

      :unavailable ->
        telemetry_error_payload(generated_at, "snapshot_unavailable", "Snapshot unavailable")
    end
  end

  @spec issue_telemetry_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_timeout | :snapshot_unavailable}
  def issue_telemetry_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.issue_telemetry_snapshot(issue_identifier, orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        {:ok,
         %{
           generated_at: generated_at,
           issue_identifier: snapshot.issue_identifier,
           issue_id: snapshot.issue_id,
           status: snapshot.status,
           summary: telemetry_summary_payload(snapshot.summary),
           events: Enum.map(snapshot.events, &telemetry_event_payload/1),
           conversation: conversation_payload(Map.get(snapshot, :conversation, []))
         }}

      :issue_not_found ->
        {:error, :issue_not_found}

      :timeout ->
        {:error, :snapshot_timeout}

      :unavailable ->
        {:error, :snapshot_unavailable}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, conversation) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      conversation: conversation,
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens:
        token_payload(
          entry.codex_input_tokens,
          Map.get(entry, :codex_cached_input_tokens, 0),
          entry.codex_output_tokens,
          entry.codex_total_tokens
        )
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens:
        token_payload(
          running.codex_input_tokens,
          Map.get(running, :codex_cached_input_tokens, 0),
          running.codex_output_tokens,
          running.codex_total_tokens
        )
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp telemetry_summary_payload(summary) when is_map(summary) do
    %{
      event_count: Map.get(summary, :event_count, 0),
      last_event_at: iso8601(Map.get(summary, :last_event_at)),
      counts_by_kind: Map.get(summary, :counts_by_kind, %{}),
      counts_by_status: Map.get(summary, :counts_by_status, %{}),
      running_count: Map.get(summary, :running_count),
      retrying_count: Map.get(summary, :retrying_count),
      buffer_limit: Map.get(summary, :buffer_limit),
      codex_totals: token_totals_payload(Map.get(summary, :codex_totals)),
      rate_limits: Map.get(summary, :rate_limits)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp telemetry_summary_payload(_summary), do: %{}

  defp telemetry_event_payload(event) when is_map(event) do
    %{
      id: Map.get(event, :id),
      at: iso8601(Map.get(event, :at)),
      issue_id: Map.get(event, :issue_id),
      issue_identifier: Map.get(event, :issue_identifier),
      session_id: Map.get(event, :session_id),
      kind: Map.get(event, :kind),
      status: Map.get(event, :status),
      summary: Map.get(event, :summary),
      metrics: Map.get(event, :metrics, %{})
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp telemetry_event_payload(_event), do: %{}

  defp conversation_payload(entries) when is_list(entries) do
    Enum.map(entries, &conversation_item_payload/1)
  end

  defp conversation_payload(_entries), do: []

  defp conversation_item_payload(entry) when is_map(entry) do
    %{
      id: Map.get(entry, :id),
      at: iso8601(Map.get(entry, :at)),
      updated_at: iso8601(Map.get(entry, :updated_at)),
      session_id: Map.get(entry, :session_id),
      item_id: Map.get(entry, :item_id),
      kind: Map.get(entry, :kind),
      status: Map.get(entry, :status),
      title: Map.get(entry, :title),
      detail: Map.get(entry, :detail),
      content: Map.get(entry, :content)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp conversation_item_payload(_entry), do: %{}

  defp telemetry_error_payload(generated_at, code, message) do
    %{generated_at: generated_at, error: %{code: code, message: message}}
  end

  defp token_payload(input_tokens, cached_input_tokens, output_tokens, total_tokens) do
    cached_input_tokens = normalize_int(cached_input_tokens)
    input_tokens = normalize_int(input_tokens)
    output_tokens = normalize_int(output_tokens)
    total_tokens = normalize_int(total_tokens)

    %{
      input_tokens: input_tokens,
      cached_input_tokens: min(cached_input_tokens, input_tokens),
      uncached_input_tokens: max(input_tokens - cached_input_tokens, 0),
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      input_output_delta: input_tokens - output_tokens
    }
  end

  defp normalize_int(value) when is_integer(value), do: max(value, 0)
  defp normalize_int(_value), do: 0

  defp token_totals_payload(nil), do: nil

  defp token_totals_payload(codex_totals) when is_map(codex_totals) do
    token_payload(
      Map.get(codex_totals, :input_tokens) || Map.get(codex_totals, "input_tokens"),
      Map.get(codex_totals, :cached_input_tokens) || Map.get(codex_totals, "cached_input_tokens"),
      Map.get(codex_totals, :output_tokens) || Map.get(codex_totals, "output_tokens"),
      Map.get(codex_totals, :total_tokens) || Map.get(codex_totals, "total_tokens")
    )
    |> Map.put(
      :seconds_running,
      Map.get(codex_totals, :seconds_running) || Map.get(codex_totals, "seconds_running") || 0
    )
  end

  defp token_totals_payload(_codex_totals), do: nil

  defp issue_conversation(issue_identifier, orchestrator, snapshot_timeout_ms) do
    case Orchestrator.issue_telemetry_snapshot(issue_identifier, orchestrator, snapshot_timeout_ms) do
      %{} = snapshot -> conversation_payload(Map.get(snapshot, :conversation, []))
      _ -> []
    end
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
