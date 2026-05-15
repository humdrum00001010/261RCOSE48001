defmodule ContractWeb.UserLive.Integrations do
  @moduledoc """
  `/settings/integrations` — Wave 6 surface for managing external
  integrations. Today it lists exactly one row (Slack) with a connect /
  disconnect affordance.

  When the user has a Slack token persisted in `slack_tokens`, the page
  shows the team id + granted scope list and a "Slack 연결 해제"
  (disconnect) form. Otherwise it shows a "Slack 연결" (connect) link
  pointing at `/auth/slack/start` so the browser navigates out to
  Slack's OAuth consent screen.

  Connect / disconnect are owned by `ContractWeb.SlackOAuthController`
  (not this LV) because Slack's OAuth handshake needs a `redirect` that
  the LiveView socket can't perform mid-mount.
  """
  use ContractWeb, :live_view

  alias Contract.Integrations.Slack
  alias ContractWeb.UserLive.SettingsHub

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, dgettext("settings", "Integrations"))
      |> assign(:active_item, :integrations)
      |> assign_slack_status()

    {:ok, socket}
  end

  defp assign_slack_status(socket) do
    case Slack.connection_info(socket.assigns.current_scope) do
      {:ok, row} ->
        assign(socket, :slack, %{
          connected?: true,
          team_id: row.slack_team_id,
          slack_user_id: row.slack_user_id,
          scopes: row.scopes || []
        })

      {:error, _} ->
        assign(socket, :slack, %{connected?: false})
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <SettingsHub.settings_layout active_item={@active_item}>
        <section id="integrations-page" class="space-y-6">
          <header class="space-y-1">
            <p class="text-xs font-medium tracking-wide uppercase text-base-content/50">
              {dgettext("settings", "Settings · Integrations")}
            </p>
            <h1 class="text-2xl font-semibold tracking-tight">
              {dgettext("settings", "외부 통합")}
            </h1>
            <p class="text-sm text-base-content/60">
              {dgettext(
                "settings",
                "Slack 등 외부 서비스 연결을 관리합니다. 연결된 도구는 에이전트가 검색 및 응답에 사용할 수 있습니다."
              )}
            </p>
          </header>

          <ul
            id="integrations-list"
            class="rounded-box border border-base-200 divide-y divide-base-200 bg-base-100"
          >
            <li id="integration-slack" class="px-4 py-4 flex items-start gap-4">
              <.icon
                name="hero-chat-bubble-left-right"
                class="size-5 text-primary/80 mt-0.5 shrink-0"
              />
              <div class="flex-1 min-w-0">
                <p class="font-semibold tracking-tight">Slack</p>
                <p class="text-sm text-base-content/60 mt-0.5">
                  {dgettext(
                    "settings",
                    "Slack 워크스페이스를 연결하면 에이전트가 메시지 검색, 이모지 목록 등을 활용할 수 있습니다."
                  )}
                </p>

                <%= if @slack.connected? do %>
                  <div class="mt-3 flex flex-wrap items-center gap-2 text-xs">
                    <span
                      id="slack-status-badge"
                      class="badge badge-success badge-soft"
                    >
                      {dgettext("settings", "연결됨")}
                    </span>
                    <span class="text-base-content/60">
                      {dgettext("settings", "팀")}: <code class="font-mono">{@slack.team_id}</code>
                    </span>
                    <%= if @slack.slack_user_id not in [nil, ""] do %>
                      <span class="text-base-content/60">
                        {dgettext("settings", "사용자")}:
                        <code class="font-mono">{@slack.slack_user_id}</code>
                      </span>
                    <% end %>
                  </div>
                  <%= if @slack.scopes != [] do %>
                    <details class="mt-2 text-xs text-base-content/60">
                      <summary class="cursor-pointer select-none">
                        {dgettext("settings", "권한 (%{count})", count: length(@slack.scopes))}
                      </summary>
                      <ul class="mt-1 grid grid-cols-1 sm:grid-cols-2 gap-x-3 gap-y-0.5 font-mono">
                        <li :for={scope <- @slack.scopes}>{scope}</li>
                      </ul>
                    </details>
                  <% end %>
                <% else %>
                  <div class="mt-3">
                    <span
                      id="slack-status-badge"
                      class="badge badge-ghost badge-soft text-xs"
                    >
                      {dgettext("settings", "연결 안 됨")}
                    </span>
                  </div>
                <% end %>
              </div>

              <div class="shrink-0">
                <%= if @slack.connected? do %>
                  <.form
                    for={%{}}
                    action={~p"/auth/slack/disconnect"}
                    method="post"
                    id="slack-disconnect-form"
                  >
                    <button
                      type="submit"
                      id="slack-disconnect-button"
                      class="btn btn-sm btn-ghost text-error"
                    >
                      {dgettext("settings", "Slack 연결 해제")}
                    </button>
                  </.form>
                <% else %>
                  <a
                    id="slack-connect-button"
                    href={~p"/auth/slack/start"}
                    class="btn btn-sm btn-primary"
                  >
                    {dgettext("settings", "Slack 연결")}
                  </a>
                <% end %>
              </div>
            </li>
          </ul>
        </section>
      </SettingsHub.settings_layout>
    </Layouts.app>
    """
  end
end
