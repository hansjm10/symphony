defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()
    telemetry = load_telemetry()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:telemetry, telemetry)
      |> assign(:now, DateTime.utc_now())
      |> assign(:selected_issue_identifier, default_selected_issue_identifier(payload, nil))
      |> assign(:selected_issue, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, refresh_selected_issue(socket)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:telemetry, load_telemetry())
     |> assign(:now, DateTime.utc_now())
     |> assign(:selected_issue_identifier, default_selected_issue_identifier(payload, socket.assigns.selected_issue_identifier))
     |> refresh_selected_issue()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_issue_identifier = default_selected_issue_identifier(socket.assigns.payload, params["issue"])

    {:noreply,
     socket
     |> assign(:selected_issue_identifier, selected_issue_identifier)
     |> refresh_selected_issue()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="telemetry-dashboard">
      <aside class="telemetry-sidebar">
        <div class="telemetry-sidebar-section">
          <div class="telemetry-brand-mark">CX</div>
          <div>
            <h1 class="telemetry-brand-title">Precision Telemetry</h1>
            <p class="telemetry-brand-subtitle">Codex dashboard</p>
          </div>
        </div>

        <nav class="telemetry-nav">
          <a class="telemetry-nav-link telemetry-nav-link-active" href="/">Codex</a>
          <a class="telemetry-nav-link" href="/api/v1/state">API</a>
          <a class="telemetry-nav-link" href="/api/v1/telemetry">Runtime</a>
        </nav>

        <div class="telemetry-sidebar-footer">
          <a class="telemetry-nav-link telemetry-nav-link-muted" href="/api/v1/state">Settings</a>
          <a class="telemetry-nav-link telemetry-nav-link-muted" href="/api/v1/telemetry">Support</a>

          <div class="telemetry-operator-card">
            <div class="telemetry-operator-avatar">OP</div>
            <div class="telemetry-operator-copy">
              <p>Admin Session</p>
              <span>ops@codex.internal</span>
            </div>
          </div>
        </div>
      </aside>

      <div class="telemetry-canvas">
        <header class="telemetry-topbar">
          <div class="telemetry-topbar-brand">
            <p class="telemetry-topbar-kicker">Precision telemetry interface</p>
            <h2 class="telemetry-topbar-title">Codex Telemetry</h2>
          </div>

          <nav class="telemetry-tabbar">
            <a class="telemetry-tabbar-link telemetry-tabbar-link-active" href="#conversation">Conversation</a>
            <a class="telemetry-tabbar-link" href="#live-feed">Runtime</a>
            <a class="telemetry-tabbar-link" href="#retry-queue">Alerts</a>
          </nav>

          <div class="telemetry-topbar-meta">
            <label class="telemetry-search-shell">
              <span class="telemetry-search-label">Search system</span>
              <input type="text" placeholder="ISSUE, EVENT, SESSION" />
            </label>

            <div class="telemetry-toolbar-icons" aria-hidden="true">
              <span>!</span>
              <span>Y</span>
            </div>

            <div class="telemetry-connection">
              <span class="status-badge status-badge-live">
                <span class="status-badge-dot"></span>
                Live
              </span>
              <span class="status-badge status-badge-offline">
                <span class="status-badge-dot"></span>
                Offline
              </span>
            </div>

            <p class="telemetry-updated-at">Updated <%= format_timestamp_display(@payload.generated_at) %></p>
          </div>
        </header>

        <main class="telemetry-main">
          <%= if @payload[:error] do %>
            <section class="telemetry-alert-card">
              <p class="telemetry-panel-kicker">Snapshot unavailable</p>
              <h3 class="telemetry-panel-title">Codex dashboard data is offline</h3>
              <p class="telemetry-panel-copy">
                <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
              </p>
            </section>
          <% else %>
            <% totals = @payload.codex_totals || %{} %>
            <% health = system_health(@payload, @telemetry, @now) %>

            <section class="telemetry-metrics-grid">
              <article class="telemetry-metric-card">
                <div class="telemetry-metric-header">
                  <p class="telemetry-metric-label">Total Tokens</p>
                  <span class="telemetry-metric-glyph">TK</span>
                </div>
                <p class="telemetry-metric-value numeric"><%= format_int(Map.get(totals, :total_tokens)) %></p>
                <p class="telemetry-metric-detail numeric">
                  In <%= format_int(Map.get(totals, :input_tokens)) %> / Out <%= format_int(Map.get(totals, :output_tokens)) %> / Cached <%= format_int(Map.get(totals, :cached_input_tokens)) %>
                </p>
              </article>

              <article class="telemetry-metric-card">
                <div class="telemetry-metric-header">
                  <p class="telemetry-metric-label">Input Delta / Cache</p>
                  <span class="telemetry-metric-glyph">DC</span>
                </div>
                <p class="telemetry-metric-pair numeric">
                  <span><%= signed_int(Map.get(totals, :input_output_delta)) %></span>
                  <span class="telemetry-metric-pair-separator">uncached</span>
                  <span class="telemetry-metric-pair-accent"><%= format_int(Map.get(totals, :uncached_input_tokens)) %></span>
                </p>
                <div class="telemetry-ratio-bar" aria-hidden="true">
                  <span style={"width: #{token_ratio_width(Map.get(totals, :cached_input_tokens), Map.get(totals, :input_tokens))}%;"}></span>
                  <span class="telemetry-ratio-bar-accent" style={"width: #{token_ratio_width(Map.get(totals, :uncached_input_tokens), Map.get(totals, :input_tokens))}%;"}></span>
                </div>
              </article>

              <article class="telemetry-metric-card">
                <div class="telemetry-metric-header">
                  <p class="telemetry-metric-label">Active Commands</p>
                  <span class="telemetry-metric-glyph">AC</span>
                </div>
                <p class="telemetry-metric-value numeric"><%= @payload.counts.running %></p>
                <p class="telemetry-metric-detail">
                  <%= active_command_summary(@payload, @now) %>
                </p>
              </article>

              <article class={["telemetry-metric-card", "telemetry-metric-card-health", "telemetry-metric-card-health-#{health.tone}"]}>
                <div class="telemetry-metric-header">
                  <p class="telemetry-metric-label">System Health</p>
                  <span class="telemetry-health-indicator">
                    <span></span>
                    <%= health.label %>
                  </span>
                </div>
                <p class="telemetry-metric-health-value"><%= health.headline %></p>
                <p class="telemetry-metric-health-detail"><%= health.detail_one %></p>
                <p class="telemetry-metric-health-detail"><%= health.detail_two %></p>
              </article>
            </section>

            <section id="conversation" class="telemetry-panel telemetry-conversation-panel">
              <div class="telemetry-panel-header">
                <div>
                  <p class="telemetry-panel-kicker">Active Conversation</p>
                  <h3 class="telemetry-panel-title">Follow the live Codex walkthrough</h3>
                </div>

                <div class="telemetry-panel-meta">
                  <%= if @selected_issue do %>
                    <span>Following <span class="mono"><%= @selected_issue.issue_identifier %></span></span>
                    <a href={"/issues/#{@selected_issue.issue_identifier}/telemetry"}>Issue trace</a>
                    <a href={"/api/v1/#{@selected_issue.issue_identifier}"}>Issue JSON</a>
                  <% else %>
                    <span>No active run selected</span>
                  <% end %>
                </div>
              </div>

              <%= if @selected_issue do %>
                <% running = @selected_issue.running || %{} %>
                <% conversation = Map.get(@selected_issue, :conversation, []) %>

                <div class="telemetry-conversation-summary">
                  <div class="telemetry-conversation-summary-card">
                    <p class="telemetry-conversation-summary-label">Issue</p>
                    <p class="telemetry-conversation-summary-value"><%= @selected_issue.issue_identifier %></p>
                    <p class="telemetry-conversation-summary-detail"><%= running.state || @selected_issue.status %></p>
                  </div>

                  <div class="telemetry-conversation-summary-card">
                    <p class="telemetry-conversation-summary-label">Runtime / turns</p>
                    <p class="telemetry-conversation-summary-value numeric"><%= format_runtime_and_turns(running.started_at, running.turn_count, @now) %></p>
                    <p class="telemetry-conversation-summary-detail"><%= issue_conversation_status(@selected_issue) %></p>
                  </div>

                  <div class="telemetry-conversation-summary-card">
                    <p class="telemetry-conversation-summary-label">Session</p>
                    <p class="telemetry-conversation-summary-value mono"><%= running.session_id || "n/a" %></p>
                    <p class="telemetry-conversation-summary-detail">Last update <%= format_clock_time(running.last_event_at) %></p>
                  </div>
                </div>

                <%= if conversation == [] do %>
                  <p class="telemetry-empty-state">Waiting for Codex conversation events for this run.</p>
                <% else %>
                  <div
                    id={"conversation-steps-#{@selected_issue.issue_identifier}"}
                    class="telemetry-scroll-region telemetry-conversation-scroll"
                    phx-hook="AutoScrollTelemetry"
                    data-autoscroll-edge="end"
                    data-autoscroll-threshold="72"
                  >
                    <div class="telemetry-conversation-list">
                      <article
                        :for={{step, index} <- Enum.with_index(conversation, 1)}
                        class={["telemetry-conversation-step", "telemetry-conversation-step-#{step.kind}"]}
                      >
                        <div class="telemetry-conversation-index"><%= index %></div>

                        <div class="telemetry-conversation-copy">
                          <div class="telemetry-conversation-head">
                            <div class="telemetry-conversation-titles">
                              <span class={conversation_kind_badge_class(step.kind)}><%= conversation_kind_label(step.kind) %></span>
                              <h4><%= step.title || conversation_kind_label(step.kind) %></h4>
                            </div>

                            <div class="telemetry-conversation-meta">
                              <span class={conversation_status_badge_class(step.status)}><%= step.status || "updated" %></span>
                              <span class="mono"><%= format_clock_time(step.updated_at || step.at) %></span>
                            </div>
                          </div>

                          <%= if Map.get(step, :detail) do %>
                            <p class="telemetry-conversation-detail mono"><%= step.detail %></p>
                          <% end %>

                          <%= if Map.get(step, :content) do %>
                            <pre class="telemetry-conversation-content"><%= step.content %></pre>
                          <% end %>
                        </div>
                      </article>
                    </div>
                  </div>
                <% end %>
              <% else %>
                <p class="telemetry-empty-state">No running Codex session is available to follow right now.</p>
              <% end %>
            </section>

            <div class="telemetry-bento-grid">
              <section id="live-feed" class="telemetry-panel telemetry-feed-panel">
                <div class="telemetry-panel-header">
                  <div>
                    <p class="telemetry-panel-kicker">Telemetry Live Stream</p>
                    <h3 class="telemetry-panel-title">Runtime event feed</h3>
                  </div>

                  <div class="telemetry-panel-meta">
                    <span>Buffer <%= buffer_summary(@telemetry) %></span>
                    <a href="/api/v1/telemetry">Open JSON</a>
                  </div>
                </div>

                <%= if @telemetry[:error] do %>
                  <p class="telemetry-empty-state"><%= @telemetry.error.message %></p>
                <% else %>
                  <%= if @telemetry.events == [] do %>
                    <p class="telemetry-empty-state">No telemetry events recorded yet.</p>
                  <% else %>
                    <div
                      id="runtime-telemetry-events"
                      class="telemetry-scroll-region telemetry-feed-scroll"
                      phx-hook="AutoScrollTelemetry"
                      data-autoscroll-edge="start"
                      data-autoscroll-threshold="48"
                    >
                      <div class="telemetry-feed-head">
                        <span>Timestamp</span>
                        <span>Event Scope</span>
                        <span>Payload / Instruction</span>
                      </div>

                      <div class="telemetry-feed-body">
                        <article
                          :for={event <- Enum.take(@telemetry.events, 48)}
                          class={["telemetry-feed-row", telemetry_feed_row_class(event)]}
                        >
                          <div class="telemetry-feed-time mono"><%= format_clock_time(Map.get(event, :at)) %></div>
                          <div class="telemetry-feed-scope">
                            <span class={telemetry_scope_badge_class(event)}>
                              <%= telemetry_scope_label(event) %>
                            </span>
                          </div>
                          <div class="telemetry-feed-summary">
                            <p class="mono"><%= Map.get(event, :summary) || "n/a" %></p>
                            <p class="telemetry-feed-meta">
                              <span><%= Map.get(event, :issue_identifier) || "runtime" %></span>
                              <%= if Map.get(event, :status) do %>
                                <span><%= Map.get(event, :status) %></span>
                              <% end %>
                              <%= if Map.get(event, :session_id) do %>
                                <span class="mono"><%= Map.get(event, :session_id) %></span>
                              <% end %>
                            </p>
                          </div>
                        </article>
                      </div>
                    </div>

                    <div class="telemetry-json-preview">
                      <div class="telemetry-json-preview-header">
                        <span>Live Payload Inspector</span>
                        <a href="/api/v1/telemetry">Telemetry JSON</a>
                      </div>
                      <pre class="telemetry-json-preview-body"><%= pretty_value(payload_inspector_value(@telemetry, @payload)) %></pre>
                    </div>
                  <% end %>
                <% end %>
              </section>

              <aside class="telemetry-rail">
                <section class="telemetry-panel">
                  <div class="telemetry-panel-header">
                    <div>
                      <p class="telemetry-panel-kicker">Recent Calls</p>
                      <h3 class="telemetry-panel-title">Current execution queue</h3>
                    </div>
                  </div>

                  <div class="telemetry-call-list">
                    <%= for item <- recent_call_items(@payload, @now, @selected_issue_identifier) do %>
                      <%= if item.mode == :patch do %>
                        <.link patch={item.href} class={["telemetry-call-card", item.selected? && "telemetry-call-card-selected"]}>
                          <div class={["telemetry-call-avatar", "telemetry-call-avatar-#{item.tone}"]}>
                            <%= item.badge %>
                          </div>

                          <div class="telemetry-call-copy">
                            <p class="telemetry-call-title"><%= item.title %></p>
                            <p class="telemetry-call-subtitle"><%= item.subtitle %></p>
                          </div>

                          <div class="telemetry-call-stats">
                            <p><%= item.metric_primary %></p>
                            <p><%= item.metric_secondary %></p>
                          </div>
                        </.link>
                      <% else %>
                        <a class="telemetry-call-card" href={item.href}>
                          <div class={["telemetry-call-avatar", "telemetry-call-avatar-#{item.tone}"]}>
                            <%= item.badge %>
                          </div>

                          <div class="telemetry-call-copy">
                            <p class="telemetry-call-title"><%= item.title %></p>
                            <p class="telemetry-call-subtitle"><%= item.subtitle %></p>
                          </div>

                          <div class="telemetry-call-stats">
                            <p><%= item.metric_primary %></p>
                            <p><%= item.metric_secondary %></p>
                          </div>
                        </a>
                      <% end %>
                    <% end %>

                    <%= if recent_call_items(@payload, @now, @selected_issue_identifier) == [] do %>
                      <p class="telemetry-empty-state">No running or retrying activity right now.</p>
                    <% end %>
                  </div>
                </section>

                <section class="telemetry-panel">
                  <div class="telemetry-panel-header">
                    <div>
                      <p class="telemetry-panel-kicker">Rate Limits</p>
                      <h3 class="telemetry-panel-title">Upstream budget</h3>
                    </div>
                  </div>

                  <div class="telemetry-limit-list">
                    <%= for row <- rate_limit_rows(@payload.rate_limits) do %>
                      <div class="telemetry-limit-row">
                        <div>
                          <p class="telemetry-limit-label"><%= row.label %></p>
                          <p class="telemetry-limit-detail"><%= row.detail %></p>
                        </div>
                        <p class="telemetry-limit-value numeric"><%= row.value %></p>
                      </div>
                    <% end %>
                  </div>
                </section>

                <section class="telemetry-doc-card">
                  <p class="telemetry-panel-kicker">Telemetry Endpoints</p>
                  <h3 class="telemetry-panel-title">Inspect raw observability data</h3>
                  <p class="telemetry-panel-copy">
                    Open structured snapshots for the runtime or jump into issue-specific telemetry traces.
                  </p>

                  <div class="telemetry-doc-links">
                    <a href="/api/v1/state">State JSON</a>
                    <a href="/api/v1/telemetry">Telemetry JSON</a>
                    <%= if @payload.running != [] do %>
                      <a href={"/issues/#{List.first(@payload.running).issue_identifier}/telemetry"}>First issue trace</a>
                    <% end %>
                  </div>
                </section>
              </aside>
            </div>

            <div class="telemetry-ops-grid">
              <section id="sessions" class="telemetry-panel">
                <div class="telemetry-panel-header">
                  <div>
                    <p class="telemetry-panel-kicker">Sessions</p>
                    <h3 class="telemetry-panel-title">Running sessions</h3>
                  </div>
                  <span class="telemetry-panel-meta-pill"><%= @payload.counts.running %> active</span>
                </div>

                <%= if @payload.running == [] do %>
                  <p class="telemetry-empty-state">No active sessions.</p>
                <% else %>
                  <div class="telemetry-session-list">
                    <article :for={entry <- @payload.running} class="telemetry-session-card">
                      <div class="telemetry-session-topline">
                        <div>
                          <p class="telemetry-session-id"><%= entry.issue_identifier %></p>
                          <p class="telemetry-session-path mono"><%= entry.workspace_path || "workspace unavailable" %></p>
                        </div>
                        <span class={state_badge_class(entry.state)}><%= entry.state %></span>
                      </div>

                      <div class="telemetry-session-grid">
                        <div>
                          <p class="telemetry-session-label">Runtime / turns</p>
                          <p class="telemetry-session-value numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></p>
                        </div>
                        <div>
                          <p class="telemetry-session-label">Codex update</p>
                          <p class="telemetry-session-value"><%= entry.last_message || to_string(entry.last_event || "n/a") %></p>
                        </div>
                        <div>
                          <p class="telemetry-session-label">Tokens</p>
                          <p class="telemetry-session-value numeric"><%= session_token_summary(entry.tokens) %></p>
                        </div>
                      </div>

                      <div class="telemetry-session-actions">
                        <.link
                          patch={"/?issue=#{entry.issue_identifier}#conversation"}
                          class={[
                            "issue-link",
                            @selected_issue_identifier == entry.issue_identifier && "issue-link-selected"
                          ]}
                        >
                          Follow
                        </.link>
                        <a class="issue-link" href={"/issues/#{entry.issue_identifier}/telemetry"}>Telemetry</a>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">Session unavailable</span>
                        <% end %>
                      </div>
                    </article>
                  </div>
                <% end %>
              </section>

              <section id="retry-queue" class="telemetry-panel">
                <div class="telemetry-panel-header">
                  <div>
                    <p class="telemetry-panel-kicker">Queue Pressure</p>
                    <h3 class="telemetry-panel-title">Retry queue</h3>
                  </div>
                  <span class="telemetry-panel-meta-pill"><%= @payload.counts.retrying %> queued</span>
                </div>

                <%= if @payload.retrying == [] do %>
                  <p class="telemetry-empty-state">No issues are currently backing off.</p>
                <% else %>
                  <div class="telemetry-queue-list">
                    <article :for={entry <- @payload.retrying} class="telemetry-queue-card">
                      <div>
                        <p class="telemetry-session-id"><%= entry.issue_identifier %></p>
                        <p class="telemetry-session-label">Attempt <%= entry.attempt %> · Due <span class="mono"><%= format_timestamp_display(entry.due_at) %></span></p>
                      </div>
                      <p class="telemetry-queue-error"><%= entry.error || "n/a" %></p>
                      <div class="telemetry-session-actions">
                        <a class="issue-link" href={"/issues/#{entry.issue_identifier}/telemetry"}>Telemetry</a>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </article>
                  </div>
                <% end %>
              </section>
            </div>
          <% end %>
        </main>
      </div>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_telemetry do
    Presenter.telemetry_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_issue(issue_identifier) when is_binary(issue_identifier) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> payload
      {:error, :issue_not_found} -> nil
    end
  end

  defp load_issue(_issue_identifier), do: nil

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(%{codex_totals: codex_totals}) when is_map(codex_totals) do
    Map.get(codex_totals, :seconds_running, 0) || 0
  end

  defp completed_runtime_seconds(_payload), do: 0

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp signed_int(value) when is_integer(value) and value > 0, do: "+" <> format_int(value)
  defp signed_int(value) when is_integer(value), do: Integer.to_string(value)
  defp signed_int(_value), do: "n/a"

  defp format_timestamp_display(nil), do: "n/a"

  defp format_timestamp_display(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> Calendar.strftime(parsed, "%b %d, %H:%M")
      _ -> value
    end
  end

  defp format_timestamp_display(%DateTime{} = value), do: Calendar.strftime(value, "%b %d, %H:%M")
  defp format_timestamp_display(value), do: to_string(value)

  defp format_clock_time(nil), do: "n/a"

  defp format_clock_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> Calendar.strftime(parsed, "%H:%M:%S")
      _ -> value
    end
  end

  defp format_clock_time(%DateTime{} = value), do: Calendar.strftime(value, "%H:%M:%S")
  defp format_clock_time(value), do: to_string(value)

  defp token_ratio_width(part, total)
       when is_integer(part) and is_integer(total) and part >= 0 and total > 0 do
    part
    |> Kernel./(total)
    |> Kernel.*(100)
    |> Float.round(1)
    |> max(4.0)
    |> min(100.0)
  end

  defp token_ratio_width(_part, _total), do: 0

  defp active_command_summary(payload, now) do
    "#{payload.counts.retrying} queued for retry · #{format_runtime_seconds(total_runtime_seconds(payload, now))} aggregate runtime"
  end

  defp system_health(payload, telemetry, _now) do
    telemetry_summary = Map.get(telemetry, :summary, %{})
    last_event = Map.get(telemetry_summary, :last_event_at)

    cond do
      payload[:error] ->
        %{
          tone: "danger",
          label: "Unavailable",
          headline: "Snapshot timeout",
          detail_one: payload.error.message,
          detail_two: "Refresh the runtime and retry."
        }

      telemetry[:error] ->
        %{
          tone: "warning",
          label: "Delayed",
          headline: "Telemetry lag",
          detail_one: telemetry.error.message,
          detail_two: "#{payload.counts.running} sessions still reporting state."
        }

      payload.counts.retrying > 0 ->
        %{
          tone: "warning",
          label: "Watching",
          headline: "#{payload.counts.retrying} queued",
          detail_one: "#{payload.counts.running} active sessions remain in flight.",
          detail_two: "Last event #{format_timestamp_display(last_event)}"
        }

      true ->
        %{
          tone: "nominal",
          label: "Nominal",
          headline: "#{payload.counts.running} active",
          detail_one: "#{Map.get(telemetry_summary, :event_count, 0)} buffered runtime events.",
          detail_two: "Last event #{format_timestamp_display(last_event)}"
        }
    end
  end

  defp buffer_summary(%{error: _}), do: "Unavailable"

  defp buffer_summary(%{summary: summary}) when is_map(summary) do
    "#{Map.get(summary, :event_count, 0)} events / limit #{Map.get(summary, :buffer_limit, "n/a")}"
  end

  defp buffer_summary(_telemetry), do: "Unavailable"

  defp telemetry_scope_label(event) do
    event.kind
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, ".")
    |> String.split(".", trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(".")
    |> case do
      "" -> "Runtime"
      label -> label
    end
  end

  defp telemetry_scope_badge_class(event) do
    base = "telemetry-scope-badge"
    normalized = [event.kind, event.status] |> Enum.map(&to_string/1) |> Enum.join(" ") |> String.downcase()

    cond do
      String.contains?(normalized, ["error", "failed"]) -> "#{base} telemetry-scope-badge-danger"
      String.contains?(normalized, ["retry", "warning", "pending"]) -> "#{base} telemetry-scope-badge-warning"
      String.contains?(normalized, ["token", "usage"]) -> "#{base} telemetry-scope-badge-tertiary"
      true -> "#{base} telemetry-scope-badge-primary"
    end
  end

  defp telemetry_feed_row_class(event) do
    normalized = [event.kind, event.status] |> Enum.map(&to_string/1) |> Enum.join(" ") |> String.downcase()

    cond do
      String.contains?(normalized, ["error", "failed"]) -> "telemetry-feed-row-danger"
      true -> "telemetry-feed-row-default"
    end
  end

  defp payload_inspector_value(%{events: [event | _]}, _payload) do
    Map.take(event, [:id, :at, :issue_identifier, :session_id, :kind, :status, :summary, :metrics])
  end

  defp payload_inspector_value(_telemetry, payload) do
    payload.rate_limits || %{message: "No telemetry payload available yet."}
  end

  defp recent_call_items(payload, now) do
    running_items =
      Enum.map(payload.running, fn entry ->
        %{
          href: "/?issue=#{entry.issue_identifier}#conversation",
          mode: :patch,
          selected?: false,
          issue_identifier: entry.issue_identifier,
          tone: recent_call_tone(entry.state),
          badge: "RN",
          title: entry.issue_identifier,
          subtitle: entry.last_message || to_string(entry.last_event || "running"),
          metric_primary: session_token_summary(entry.tokens),
          metric_secondary: format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, now))
        }
      end)

    retry_items =
      Enum.map(payload.retrying, fn entry ->
        %{
          href: "/issues/#{entry.issue_identifier}/telemetry",
          mode: :navigate,
          selected?: false,
          issue_identifier: entry.issue_identifier,
          tone: "danger",
          badge: "RQ",
          title: entry.issue_identifier,
          subtitle: entry.error || "retry scheduled",
          metric_primary: "Attempt #{entry.attempt}",
          metric_secondary: format_timestamp_display(entry.due_at)
        }
      end)

    Enum.take(running_items ++ retry_items, 4)
  end

  defp recent_call_items(payload, now, selected_issue_identifier) do
    payload
    |> recent_call_items(now)
    |> Enum.map(fn item -> Map.put(item, :selected?, item.issue_identifier == selected_issue_identifier) end)
  end

  defp recent_call_tone(state) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["error", "failed", "blocked"]) -> "danger"
      String.contains?(normalized, ["retry", "pending", "queued"]) -> "warning"
      true -> "primary"
    end
  end

  defp rate_limit_rows(nil) do
    [
      %{label: "Snapshot", detail: "No upstream rate-limit data available.", value: "n/a"}
    ]
  end

  defp rate_limit_rows(rate_limits) when is_map(rate_limits) do
    [
      rate_limit_row("Primary", map_value(rate_limits, [:primary, "primary"])),
      rate_limit_row("Secondary", map_value(rate_limits, [:secondary, "secondary"])),
      credits_row(map_value(rate_limits, [:credits, "credits"]))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> rate_limit_rows(nil)
      rows -> rows
    end
  end

  defp rate_limit_rows(_rate_limits), do: rate_limit_rows(nil)

  defp rate_limit_row(_label, nil), do: nil

  defp rate_limit_row(label, snapshot) when is_map(snapshot) do
    remaining = map_value(snapshot, [:remaining, "remaining"])
    limit = map_value(snapshot, [:limit, "limit"])
    reset_seconds = map_value(snapshot, [:reset_in_seconds, "reset_in_seconds"])

    %{
      label: label,
      detail: "Reset in #{reset_seconds || "n/a"}s",
      value: "#{format_int(remaining)} / #{format_int(limit)}"
    }
  end

  defp credits_row(nil), do: nil

  defp credits_row(%{unlimited: true}) do
    %{label: "Credits", detail: "Unlimited credits enabled.", value: "Open"}
  end

  defp credits_row(%{has_credits: true, balance: balance}) when is_number(balance) do
    formatted_balance =
      if is_float(balance), do: :erlang.float_to_binary(balance, decimals: 1), else: Integer.to_string(balance)

    %{label: "Credits", detail: "Balance available.", value: formatted_balance}
  end

  defp credits_row(%{has_credits: false}) do
    %{label: "Credits", detail: "No credits remaining.", value: "Empty"}
  end

  defp credits_row(_credits), do: %{label: "Credits", detail: "Credit status unavailable.", value: "n/a"}

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp session_token_summary(tokens) when is_map(tokens) do
    "T #{format_int(tokens.total_tokens)} / D #{signed_int(tokens.input_output_delta)} / C #{format_int(tokens.cached_input_tokens)}"
  end

  defp session_token_summary(_tokens), do: "n/a"

  defp refresh_selected_issue(socket) do
    assign(socket, :selected_issue, load_issue(socket.assigns.selected_issue_identifier))
  end

  defp default_selected_issue_identifier(%{running: running}, requested_issue_identifier) when is_list(running) do
    available = Enum.map(running, & &1.issue_identifier)

    cond do
      is_binary(requested_issue_identifier) and requested_issue_identifier in available -> requested_issue_identifier
      running != [] -> List.first(running).issue_identifier
      true -> nil
    end
  end

  defp default_selected_issue_identifier(_payload, _requested_issue_identifier), do: nil

  defp issue_conversation_status(%{conversation: conversation}) when is_list(conversation) and conversation != [] do
    case List.last(conversation) do
      %{kind: kind, status: status} -> "#{conversation_kind_label(kind)} is #{status || "updated"}"
      _ -> "Conversation active"
    end
  end

  defp issue_conversation_status(_issue), do: "Conversation active"

  defp conversation_kind_label("assistant"), do: "Reply"
  defp conversation_kind_label("reasoning"), do: "Reasoning"
  defp conversation_kind_label("command"), do: "Command"
  defp conversation_kind_label("tool"), do: "Tool"
  defp conversation_kind_label("file_change"), do: "File change"
  defp conversation_kind_label("user"), do: "Prompt"
  defp conversation_kind_label("session"), do: "Session"
  defp conversation_kind_label(kind), do: kind |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp conversation_kind_badge_class(kind) do
    "telemetry-conversation-kind telemetry-conversation-kind-#{kind}"
  end

  defp conversation_status_badge_class(status) do
    base = "telemetry-conversation-status"
    normalized = status |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["failed", "error", "cancelled"]) -> "#{base} telemetry-conversation-status-danger"
      String.contains?(normalized, ["streaming", "started", "running"]) -> "#{base} telemetry-conversation-status-live"
      true -> "#{base} telemetry-conversation-status-idle"
    end
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
