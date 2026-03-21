defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");
            var Hooks = {
              AutoScrollTelemetry: {
                mounted: function () {
                  this.edge = this.el.dataset.autoscrollEdge || "start";
                  this.threshold = parseInt(this.el.dataset.autoscrollThreshold || "24", 10);
                  this.shouldFollow = true;
                  this.onScroll = this.syncFollowState.bind(this);
                  this.el.addEventListener("scroll", this.onScroll, {passive: true});
                  this.syncFollowState();
                  this.scrollToEdge("auto");
                },
                beforeUpdate: function () {
                  this.syncFollowState();
                },
                updated: function () {
                  if (this.shouldFollow) this.scrollToEdge("smooth");
                },
                destroyed: function () {
                  this.el.removeEventListener("scroll", this.onScroll);
                },
                syncFollowState: function () {
                  this.shouldFollow = this.distanceFromEdge() <= this.threshold;
                },
                distanceFromEdge: function () {
                  if (this.edge === "end") {
                    return this.el.scrollHeight - this.el.clientHeight - this.el.scrollTop;
                  }

                  return this.el.scrollTop;
                },
                scrollToEdge: function (behavior) {
                  var top = this.edge === "end" ? this.el.scrollHeight : 0;
                  this.el.scrollTo({top: top, behavior: behavior});
                }
              }
            };

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: Hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
