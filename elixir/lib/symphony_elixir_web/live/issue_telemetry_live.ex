defmodule SymphonyElixirWeb.IssueTelemetryLive do
  @moduledoc """
  Issue-specific telemetry view for Symphony observability.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"issue_identifier" => issue_identifier}, _session, socket) do
    socket =
      socket
      |> assign(:issue_identifier, issue_identifier)
      |> assign(:now, DateTime.utc_now())
      |> assign_issue_data(issue_identifier)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, %{assigns: %{issue_identifier: issue_identifier}} = socket) do
    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign_issue_data(issue_identifier)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Issue Telemetry
            </h1>
            <p class="hero-copy">
              Summarized runtime telemetry for <span class="mono"><%= @issue_identifier %></span>.
            </p>
          </div>

          <div class="status-stack">
            <a class="subtle-button" href="/">Back to dashboard</a>
            <a class="subtle-button" href={"/api/v1/#{@issue_identifier}/telemetry"}>Telemetry JSON</a>
            <a class="subtle-button" href={"/api/v1/#{@issue_identifier}"}>Issue JSON</a>
          </div>
        </div>
      </header>

      <%= if @telemetry[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Telemetry unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @telemetry.error.code %>:</strong> <%= @telemetry.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Status</p>
            <p class="metric-value"><%= @telemetry.status || "n/a" %></p>
            <p class="metric-detail">Current issue runtime state.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Events</p>
            <p class="metric-value numeric"><%= Map.get(@telemetry.summary, :event_count, 0) %></p>
            <p class="metric-detail">Bounded recent telemetry history for this issue.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Last event</p>
            <p class="metric-value mono"><%= Map.get(@telemetry.summary, :last_event_at) || "n/a" %></p>
            <p class="metric-detail">Most recent telemetry timestamp.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Buffer limit</p>
            <p class="metric-value numeric"><%= Map.get(@telemetry.summary, :buffer_limit) || "n/a" %></p>
            <p class="metric-detail">Maximum issue events kept in memory.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Current issue state</h2>
              <p class="section-copy">Latest issue/runtime projection from the observability API.</p>
            </div>
          </div>

          <%= if @issue[:error] do %>
            <p class="empty-state"><%= @issue.error.message %></p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <tbody>
                  <tr>
                    <th>Issue</th>
                    <td><%= @issue.issue_identifier %></td>
                  </tr>
                  <tr>
                    <th>Status</th>
                    <td><%= @issue.status %></td>
                  </tr>
                  <tr>
                    <th>Workspace</th>
                    <td class="mono"><%= @issue.workspace.path %></td>
                  </tr>
                  <tr>
                    <th>Worker host</th>
                    <td><%= @issue.workspace.host || "local" %></td>
                  </tr>
                  <tr>
                    <th>Last event</th>
                    <td><%= issue_last_message(@issue) %></td>
                  </tr>
                  <tr>
                    <th>Tokens</th>
                    <td class="numeric"><%= issue_token_summary(@issue) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Telemetry summary</h2>
              <p class="section-copy">Aggregated counts by kind and status for the buffered issue history.</p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table">
              <tbody>
                <tr>
                  <th>Kinds</th>
                  <td><pre class="code-panel"><%= pretty_value(Map.get(@telemetry.summary, :counts_by_kind, %{})) %></pre></td>
                </tr>
                <tr>
                  <th>Statuses</th>
                  <td><pre class="code-panel"><%= pretty_value(Map.get(@telemetry.summary, :counts_by_status, %{})) %></pre></td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Recent events</h2>
              <p class="section-copy">Newest-first summarized telemetry for this issue.</p>
            </div>
          </div>

          <%= if @telemetry.events == [] do %>
            <p class="empty-state">No telemetry events recorded for this issue.</p>
          <% else %>
            <div
              id={"issue-telemetry-events-#{@issue_identifier}"}
              class="telemetry-scroll-region"
              phx-hook="AutoScrollTelemetry"
              data-autoscroll-edge="start"
              data-autoscroll-threshold="48"
            >
              <div class="table-wrap">
                <table class="data-table" style="min-width: 960px;">
                  <thead>
                    <tr>
                      <th>At</th>
                      <th>Kind</th>
                      <th>Status</th>
                      <th>Summary</th>
                      <th>Session</th>
                      <th>Metrics</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={event <- @telemetry.events}>
                      <td class="mono"><%= event.at || "n/a" %></td>
                      <td><%= event.kind %></td>
                      <td><%= event.status %></td>
                      <td><%= event.summary %></td>
                      <td class="mono"><%= event.session_id || "n/a" %></td>
                      <td><pre class="code-panel"><%= pretty_value(event.metrics || %{}) %></pre></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp assign_issue_data(socket, issue_identifier) do
    assign(socket,
      issue: load_issue_payload(issue_identifier),
      telemetry: load_telemetry_payload(issue_identifier)
    )
  end

  defp load_issue_payload(issue_identifier) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> payload
      {:error, :issue_not_found} -> %{error: %{code: "issue_not_found", message: "Issue not found"}}
    end
  end

  defp load_telemetry_payload(issue_identifier) do
    case Presenter.issue_telemetry_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        payload

      {:error, :issue_not_found} ->
        %{error: %{code: "issue_not_found", message: "Issue not found"}}

      {:error, :snapshot_timeout} ->
        %{error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      {:error, :snapshot_unavailable} ->
        %{error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp issue_last_message(%{running: %{} = running}), do: running.last_message || running.last_event || "n/a"
  defp issue_last_message(_issue), do: "n/a"

  defp issue_token_summary(%{running: %{} = running}) do
    "Total #{format_int(running.tokens.total_tokens)} | In #{format_int(running.tokens.input_tokens)} / Out #{format_int(running.tokens.output_tokens)} | Delta #{signed_int(running.tokens.input_output_delta)} | Cached #{format_int(running.tokens.cached_input_tokens)}"
  end

  defp issue_token_summary(_issue), do: "n/a"

  defp format_int(value) when is_integer(value), do: Integer.to_string(value)
  defp format_int(_value), do: "n/a"
  defp signed_int(value) when is_integer(value) and value > 0, do: "+" <> Integer.to_string(value)
  defp signed_int(value) when is_integer(value), do: Integer.to_string(value)
  defp signed_int(_value), do: "n/a"

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
