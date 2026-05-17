defmodule ContractWeb.DashboardLive do
  @moduledoc """
  Authenticated home for Contract Studio. Document library only — no metric
  cards, no recent-activity feed, no left sidebar.

  Per DESIGN.md §4 (v31, 2026-05-17):

    * Top row is a Google-Docs-style title row: `모든 문서` H1 + right-aligned
      action button (`새 문서` primary).
    * `새 문서` navigates to `/studio`. Document creation, upload, and
      recent-document selection live inside Studio's empty-state surface
      (`Canvas.Empty`) per the 2026-05-17 owner directive.
    * Documents render as a hairline TABLE (2026-05-17 owner clarification:
      "table hover means, the per row needs to have effect on user's
      interaction") — columns are 문서명 / 상태 / 수정일 / overflow menu.
      Rows are keyboard-focusable links to `/documents/:id` with a 1-step
      hover bg shift. No `다음 질문`, no agent activity feed.
    * Tabs: `모든 문서` (active) / `즐겨찾기`.
    * The contract-upload affordance must NOT live on this surface OR in
      the global navbar — it lives inside `/studio` (Canvas.Empty +
      ChatRail no-document chips).

  ## Data sources

    * `Contract.Documents.list_all_for_scope/2` — all owner-scoped
      non-archived documents, ordered by `updated_at DESC`. The dashboard
      surfaces the full library, not a "recent N" slice.
  """
  use ContractWeb, :live_view

  alias Contract.Documents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, dgettext("dashboard", "Dashboard"))
      |> assign(:active_tab, :all)
      |> load_documents()

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("new_document", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/studio")}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ~w(all favorites) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_documents(socket) do
    docs = list_all_documents(socket.assigns.current_scope)
    assign(socket, :documents, docs)
  end

  defp list_all_documents(scope) do
    scope
    |> Documents.list_all_for_scope()
    |> Enum.reject(&(&1.status == :template))
    |> Enum.reject(&(&1.status == :archived))
    |> Enum.map(fn d ->
      %{
        document_id: d.id,
        title: d.title,
        type_key: d.type_key,
        status: d.status,
        updated_at: d.updated_at
      }
    end)
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <main class="dashboard-v31 py-6 sm:py-10">
        <%!-- ------------------------------------------------------------ --%>
        <%!-- Title row — H1 + right-aligned primary action.                --%>
        <%!-- `새 문서` navigates to /studio (the empty-state surface where  --%>
        <%!-- upload / blank / recent / agent-discussion all live). No      --%>
        <%!-- modal, no popover, no doc creation on this surface.           --%>
        <%!-- ------------------------------------------------------------ --%>
        <header class="dashboard-v31__top">
          <h1 class="dashboard-v31__title">{dgettext("dashboard", "모든 문서")}</h1>

          <div class="dashboard-v31__actions">
            <button
              type="button"
              phx-click="new_document"
              class="dashboard-v31__btn dashboard-v31__btn--primary"
              data-role="dashboard-new-document"
            >
              {dgettext("dashboard", "새 문서")}
            </button>
          </div>
        </header>

        <%!-- ------------------------------------------------------------ --%>
        <%!-- Tabs — visual filter only; the active tab governs the grid.  --%>
        <%!-- ------------------------------------------------------------ --%>
        <nav class="dashboard-v31__tabs" role="tablist">
          <button
            type="button"
            role="tab"
            aria-selected={to_string(@active_tab == :all)}
            phx-click="switch_tab"
            phx-value-tab="all"
            class={[
              "dashboard-v31__tab",
              @active_tab == :all && "dashboard-v31__tab--active"
            ]}
          >
            {dgettext("dashboard", "모든 문서")}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={to_string(@active_tab == :favorites)}
            phx-click="switch_tab"
            phx-value-tab="favorites"
            class={[
              "dashboard-v31__tab",
              @active_tab == :favorites && "dashboard-v31__tab--active"
            ]}
          >
            {dgettext("dashboard", "즐겨찾기")}
          </button>
        </nav>

        <%!-- ------------------------------------------------------------ --%>
        <%!-- Document table — hairline rows with per-row hover/focus.      --%>
        <%!-- 2026-05-17 owner directive: rows, not cards.                   --%>
        <%!-- ------------------------------------------------------------ --%>
        <%= cond do %>
          <% @active_tab == :favorites -> %>
            <section
              id="favorites-empty"
              class="dashboard-v31__empty"
              data-role="dashboard-favorites-empty"
            >
              {dgettext("dashboard", "즐겨찾기한 문서가 아직 없습니다.")}
            </section>
          <% true -> %>
            <.document_table documents={@documents} />
        <% end %>
      </main>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  @doc """
  Renders the document library as a hairline table. Each row is a
  keyboard-focusable link to `/documents/:id` with per-row hover and
  focus states. Empty state renders a single muted row spanning all
  columns rather than a separate empty card.
  """
  attr :documents, :list, required: true

  def document_table(assigns) do
    ~H"""
    <table id="document-table" class="document-table" data-role="document-table">
      <thead>
        <tr>
          <th scope="col">{dgettext("dashboard", "문서명")}</th>
          <th scope="col">{dgettext("dashboard", "상태")}</th>
          <th scope="col">{dgettext("dashboard", "수정일")}</th>
          <th scope="col" aria-label={dgettext("dashboard", "메뉴")}></th>
        </tr>
      </thead>
      <tbody>
        <%= if @documents == [] do %>
          <tr id="documents-empty" data-role="dashboard-documents-empty">
            <td class="document-table__empty" colspan="4">
              {dgettext("dashboard", "아직 문서가 없습니다.")}
            </td>
          </tr>
        <% else %>
          <tr
            :for={doc <- @documents}
            class="document-table__row"
            data-role="document-row"
            phx-click={JS.navigate(~p"/documents/#{doc.document_id}")}
            tabindex="0"
            role="link"
            phx-hook=".DocRow"
            id={"document-row-#{doc.document_id}"}
          >
            <td class="document-table__title">{doc.title}</td>
            <td>
              <span class={["status-dot", "status-dot--#{doc.status}"]}></span>
              {document_status_label(doc.status)}
            </td>
            <td class="document-table__date">{format_date(doc.updated_at)}</td>
            <td class="document-table__menu-cell">
              <button
                type="button"
                class="document-table__menu"
                data-role="document-row-menu"
                aria-label={dgettext("dashboard", "문서 메뉴")}
                phx-click={JS.dispatch("phx:noop")}
                onclick="event.stopPropagation()"
              >⋮</button>
            </td>
          </tr>
        <% end %>
      </tbody>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DocRow">
        export default {
          mounted() {
            this.handler = (e) => {
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault()
                this.el.click()
              }
            }
            this.el.addEventListener("keydown", this.handler)
          },
          destroyed() {
            if (this.handler) {
              this.el.removeEventListener("keydown", this.handler)
            }
          }
        }
      </script>
    </table>
    """
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp document_status_label(:draft), do: dgettext("dashboard", "초안")
  defp document_status_label(:importing), do: dgettext("dashboard", "가져오는 중")
  defp document_status_label(:editing), do: dgettext("dashboard", "진행 중")
  defp document_status_label(:reviewing), do: dgettext("dashboard", "검토 대기")
  defp document_status_label(:export_ready), do: dgettext("dashboard", "완료")
  defp document_status_label(:archived), do: dgettext("dashboard", "보관")
  defp document_status_label(other), do: to_string(other)

  defp format_date(nil), do: "—"

  defp format_date(%NaiveDateTime{} = t),
    do: t |> DateTime.from_naive!("Etc/UTC") |> format_date()

  defp format_date(%DateTime{} = t), do: Calendar.strftime(t, "%Y.%m.%d")
  defp format_date(%Date{} = d), do: Calendar.strftime(d, "%Y.%m.%d")
end
