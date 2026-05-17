defmodule ContractWeb.DashboardLive do
  @moduledoc """
  Authenticated home for Contract Studio. Document library only — no metric
  cards, no recent-activity feed, no left sidebar.

  Per DESIGN.md §4 (v31, 2026-05-17):

    * Top row is a Google-Docs-style title row: `최근 문서` H1 + right-aligned
      action buttons (`새 문서` primary + `계약서 업로드 ⌄` secondary).
    * `계약서 업로드` opens a popover anchored under the trigger — NOT a modal.
    * Card information is: thumbnail / title / status dot + label / 수정일 /
      overflow menu. No `다음 질문`, no agent activity feed.
    * Tabs: `모든 문서` (active) / `즐겨찾기`.
    * `계약서 업로드` must NOT live in the global navbar.

  ## Data sources

    * `Contract.Documents.list_recent_for_scope/2` — recent owner-scoped
      documents.
    * `Contract.SourceDocuments.create_from_upload/3` — wiring target for the
      upload popover (see `consume_uploaded_entries/3` event handler).
  """
  use ContractWeb, :live_view

  alias Contract.Documents

  @recent_documents_limit 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, dgettext("dashboard", "Dashboard"))
      |> assign(:upload_menu_open?, false)
      |> assign(:active_tab, :all)
      |> allow_upload(:contract_file,
        accept: ~w(.pdf .docx .hwp .hwpx),
        max_entries: 1,
        max_file_size: 50_000_000,
        auto_upload: true
      )
      |> load_documents()

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_upload_menu", _params, socket) do
    {:noreply, update(socket, :upload_menu_open?, &(!&1))}
  end

  def handle_event("close_upload_menu", _params, socket) do
    {:noreply, assign(socket, :upload_menu_open?, false)}
  end

  def handle_event("new_document", _params, socket) do
    scope = socket.assigns.current_scope

    # SPEC.md §18: documents are created untyped — the contract type is set
    # afterwards by the user (Cmd+K) or the agent. The dashboard's "new"
    # action gives the doc a default title so we never block the lawyer on
    # naming. The title can be edited later in Studio.
    case Documents.create(scope, %{"title" => default_new_title()}) do
      {:ok, doc} ->
        {:noreply, push_navigate(socket, to: ~p"/documents/#{doc.id}")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("dashboard", "Could not create the document.")
         )}
    end
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  # auto_upload: the LiveView upload framework calls this when the file has
  # been streamed up. We consume the entry, hand it to the source-document
  # pipeline, then navigate the lawyer into Studio for the resulting doc.
  def handle_event("save_upload", _params, socket) do
    scope = socket.assigns.current_scope

    uploaded =
      consume_uploaded_entries(socket, :contract_file, fn %{path: path}, entry ->
        # TODO(post-merge): wire to a single SourceDocuments.import_contract/3
        # helper that creates the Document + SourceDocument in one transaction.
        # For now we mint an untyped Document (so the lawyer always lands on a
        # real doc) and stash the upload metadata on it; the actual blob /
        # parsing pipeline can be hooked up next.
        attrs = %{
          "title" => entry.client_name || default_new_title(),
          "metadata" => %{
            "import_source" => "dashboard_upload",
            "upload_filename" => entry.client_name,
            "upload_size" => entry.client_size,
            "upload_mime" => entry.client_type,
            "upload_path_hint" => Path.basename(path)
          }
        }

        case Documents.create(scope, attrs) do
          {:ok, doc} -> {:ok, doc}
          {:error, reason} -> {:postpone, {:error, reason}}
        end
      end)

    case uploaded do
      [%{id: doc_id}] ->
        {:noreply,
         socket
         |> assign(:upload_menu_open?, false)
         |> push_navigate(to: ~p"/documents/#{doc_id}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :contract_file, ref)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ~w(all favorites) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_documents(socket) do
    docs = list_recent_documents(socket.assigns.current_scope)
    assign(socket, :documents, docs)
  end

  defp list_recent_documents(scope) do
    scope
    |> Documents.list_recent_for_scope(limit: @recent_documents_limit)
    |> Enum.reject(&(&1.status == :template))
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

  defp default_new_title, do: dgettext("dashboard", "제목 없는 문서")

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <main class="dashboard-v31 py-10">
        <%!-- ------------------------------------------------------------ --%>
        <%!-- Title row — H1 + right-aligned action buttons                --%>
        <%!-- The popover lives inside the secondary button's wrapper so   --%>
        <%!-- click-away closes it. NOT a modal.                            --%>
        <%!-- ------------------------------------------------------------ --%>
        <header class="dashboard-v31__top">
          <h1 class="dashboard-v31__title">{dgettext("dashboard", "최근 문서")}</h1>

          <div class="dashboard-v31__actions">
            <button
              type="button"
              phx-click="new_document"
              class="dashboard-v31__btn dashboard-v31__btn--primary"
              data-role="dashboard-new-document"
            >
              {dgettext("dashboard", "새 문서")}
            </button>

            <div class="dashboard-v31__upload-wrap" phx-click-away="close_upload_menu">
              <button
                type="button"
                phx-click="toggle_upload_menu"
                class="dashboard-v31__btn dashboard-v31__btn--secondary"
                aria-haspopup="true"
                aria-expanded={to_string(@upload_menu_open?)}
                data-role="dashboard-upload-trigger"
              >
                {dgettext("dashboard", "계약서 업로드")}
                <span aria-hidden="true" class="dashboard-v31__caret">⌄</span>
              </button>

              <.contract_upload_menu :if={@upload_menu_open?} upload={@uploads.contract_file} />
            </div>
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
        <%!-- Document grid — 3 / 2 / 1 columns by viewport.                --%>
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
          <% @documents == [] -> %>
            <section
              id="documents-empty"
              class="dashboard-v31__empty"
              data-role="dashboard-documents-empty"
            >
              {dgettext(
                "dashboard",
                "아직 문서가 없습니다. ‘새 문서’로 시작하거나 ‘계약서 업로드’로 가져오세요."
              )}
            </section>
          <% true -> %>
            <section id="document-grid" class="dashboard-v31__grid">
              <.document_card :for={doc <- @documents} document={doc} />
            </section>
        <% end %>
      </main>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  @doc """
  Renders a single document card.

  Card contains: thumbnail block (gray rectangle if no preview), title,
  status dot + label, modification date, overflow menu. No `다음 질문`,
  no agent-decided body content — DESIGN.md §4 + §7 prohibition.
  """
  attr :document, :map, required: true

  def document_card(assigns) do
    ~H"""
    <article class="document-card-v31" data-role="document-card">
      <.link
        navigate={~p"/documents/#{@document.document_id}"}
        class="document-card-v31__link"
      >
        <div class="document-card-v31__preview">
          <button
            type="button"
            class="document-card-v31__menu"
            aria-label={dgettext("dashboard", "문서 메뉴")}
            phx-click={JS.dispatch("phx:noop")}
            onclick="event.preventDefault(); event.stopPropagation();"
          >
            ⋮
          </button>
        </div>
        <div class="document-card-v31__body">
          <h2 class="document-card-v31__title">{@document.title}</h2>
          <p class="document-card-v31__status">
            <span class={["status-dot-v31", "status-dot-v31--#{@document.status}"]}></span>
            <span>{document_status_label(@document.status)}</span>
          </p>
          <p class="document-card-v31__date">
            {dgettext("dashboard", "수정일")} {format_date(@document.updated_at)}
          </p>
        </div>
      </.link>
    </article>
    """
  end

  @doc """
  Renders the contract-upload popover anchored under the secondary action
  button. Per DESIGN.md §4 it is a popover, not a modal.
  """
  attr :upload, :any, required: true

  def contract_upload_menu(assigns) do
    ~H"""
    <div
      class="upload-menu-v31"
      role="dialog"
      aria-label={dgettext("dashboard", "계약서 업로드")}
      data-role="upload-menu"
    >
      <header class="upload-menu-v31__header">
        <strong>{dgettext("dashboard", "파일에서 가져오기")}</strong>
      </header>
      <div class="upload-menu-v31__body">
        <p class="upload-menu-v31__lead">
          {dgettext("dashboard", "기존 계약서 파일을 StudioLive로 가져옵니다.")}
        </p>
        <p class="upload-menu-v31__caption">
          {dgettext(
            "dashboard",
            "PDF, DOCX, HWP 지원 · StudioLive에서 열립니다."
          )}
        </p>

        <form
          id="contract-upload-form"
          phx-change="validate_upload"
          phx-submit="save_upload"
          class="upload-menu-v31__form"
        >
          <label class="upload-menu-v31__dropzone" for={@upload.ref}>
            <.live_file_input upload={@upload} class="sr-only" />
            <span class="upload-menu-v31__dropzone-text">
              {dgettext("dashboard", "파일을 선택하거나 끌어다 놓으세요")}
            </span>
            <span class="upload-menu-v31__dropzone-hint">
              {dgettext("dashboard", "PDF · DOCX · HWP")}
            </span>
          </label>

          <ul :if={@upload.entries != []} class="upload-menu-v31__entries">
            <li :for={entry <- @upload.entries} class="upload-menu-v31__entry">
              <span class="upload-menu-v31__entry-name">{entry.client_name}</span>
              <span class="upload-menu-v31__entry-progress">{entry.progress}%</span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="upload-menu-v31__entry-cancel"
                aria-label={dgettext("dashboard", "업로드 취소")}
              >
                ✕
              </button>
            </li>
          </ul>
        </form>
      </div>
    </div>
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
