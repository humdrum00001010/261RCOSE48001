defmodule ContractWeb.Components.AppShell do
  @moduledoc """
  Shared v33 Contract Studio shell.

  The shell owns only global chrome: brand and surface navigation. Dashboard
  actions such as document creation or contract upload belong in dashboard
  content, not this topbar.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ContractWeb.Endpoint,
    router: ContractWeb.Router,
    statics: ContractWeb.static_paths()

  attr :active, :string, default: nil, doc: "Current v33 surface label, e.g. 대시보드 or 스튜디오"
  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="app-shell">
      <header class="topbar">
        <.link navigate={~p"/"} class="brand" aria-label="Contract Studio">
          <img src={~p"/assets/icons/brand-mark.svg"} alt="" class="brand__icon" />
          <span>Contract Studio</span>
        </.link>

        <nav class="topbar__nav" aria-label="Contract Studio">
          <.link navigate={~p"/dashboard"} class={[@active == "대시보드" && "is-active"]}>
            대시보드
          </.link>

          <span class={[@active == "스튜디오" && "is-active"]}>스튜디오</span>
        </nav>
      </header>

      {render_slot(@inner_block)}
    </div>
    """
  end
end
