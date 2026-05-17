defmodule ContractWeb.DashboardLive do
  @moduledoc """
  Authenticated v33 document-library dashboard.

  This surface is intentionally limited to owner-scoped document library work:
  open documents, create a blank document, or pick an upload file from a small
  content popover. Analytics, recent activity, sidebars, and table rows do not
  belong here.
  """
  use ContractWeb, :live_view

  alias Contract.{Command, Documents, Runtime}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, dgettext("dashboard", "Dashboard"))
      |> assign(:upload_menu_open?, false)
      |> load_documents()
      |> allow_upload(:contract_file,
        accept: ~w(.pdf .docx .hwp),
        max_entries: 1,
        auto_upload: true,
        progress: &handle_upload_progress/3
      )

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("new_document", _params, socket) do
    case create_document(socket.assigns.current_scope, dgettext("dashboard", "새 문서")) do
      {:ok, doc} ->
        {:noreply, push_navigate(socket, to: ~p"/studio/#{doc.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("dashboard", "문서 생성에 실패했습니다."))}
    end
  end

  def handle_event("toggle_upload_menu", _params, socket) do
    {:noreply, update(socket, :upload_menu_open?, &(!&1))}
  end

  def handle_event("close_upload_menu", _params, socket) do
    {:noreply, assign(socket, :upload_menu_open?, false)}
  end

  def handle_event("contract_upload_validate", _params, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Data loading and mutations
  # ---------------------------------------------------------------------------

  defp load_documents(socket) do
    docs = list_all_documents(socket.assigns.current_scope)
    assign(socket, :documents, docs)
  end

  defp list_all_documents(scope) do
    scope
    |> Documents.list_all_for_scope()
    |> Enum.reject(&(&1.status in [:template, :archived]))
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

  defp create_document(scope, title, metadata \\ %{}) do
    action = %Command{
      kind: :create_document,
      actor_type: :user,
      actor_id: scope && scope.user && scope.user.id,
      base_revision: 0,
      idempotency_key: generate_idempotency_key(),
      payload: %{"title" => title, "metadata" => metadata}
    }

    case Runtime.apply(scope, action) do
      {:ok, %Contract.Change{document_id: document_id}} ->
        Documents.get(scope, document_id)

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_upload_progress(:contract_file, entry, socket) do
    if entry.done? do
      uploaded =
        consume_uploaded_entries(socket, :contract_file, fn _meta, entry ->
          title = upload_title(entry.client_name)

          result =
            create_document(socket.assigns.current_scope, title, %{
              "source_filename" => entry.client_name
            })

          {:ok, result}
        end)

      case uploaded do
        [{:ok, doc}] ->
          {:noreply, push_navigate(socket, to: ~p"/studio/#{doc.id}")}

        [{:error, _reason}] ->
          {:noreply, put_flash(socket, :error, dgettext("dashboard", "업로드 문서 생성에 실패했습니다."))}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp upload_title(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> case do
      "" -> dgettext("dashboard", "새 문서")
      title -> title
    end
  end

  defp upload_title(_filename), do: dgettext("dashboard", "새 문서")

  defp generate_idempotency_key, do: "dashboard:" <> Ecto.UUID.generate()

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active="대시보드">
      <main class="dashboard-page py-6 sm:py-10">
          <section id="dashboard-toolbar" class="dashboard-toolbar">
            <div class="dashboard-toolbar__copy">
              <h1>{dgettext("dashboard", "최근 문서")}</h1>
              <p>{dgettext("dashboard", "계약서를 열거나 기존 계약서를 Studio로 가져옵니다.")}</p>
            </div>

            <div id="dashboard-actions" class="dashboard-actions">
              <button
                type="button"
                phx-click="new_document"
                class="button button--primary"
                data-role="dashboard-new-document"
              >
                {dgettext("dashboard", "새 문서")}
              </button>

              <div class="upload-action" phx-click-away="close_upload_menu">
                <button
                  type="button"
                  phx-click="toggle_upload_menu"
                  class="button button--secondary"
                  data-role="dashboard-upload-trigger"
                  aria-haspopup="menu"
                  aria-expanded={to_string(@upload_menu_open?)}
                >
                  <img src={~p"/assets/icons/upload.svg"} alt="" class="size-4" />
                  <span>{dgettext("dashboard", "계약서 업로드")}</span>
                  <img src={~p"/assets/icons/chevron-down.svg"} alt="" class="size-4" />
                </button>

                <%= if @upload_menu_open? do %>
                  <.contract_upload_menu upload={@uploads.contract_file} />
                <% end %>
              </div>
            </div>
          </section>

          <section
            id="document-grid"
            class="document-grid"
            aria-label={dgettext("dashboard", "문서 목록")}
          >
            <%= if @documents == [] do %>
              <div id="documents-empty" class="document-grid__empty">
                {dgettext("dashboard", "아직 문서가 없습니다.")}
              </div>
            <% else %>
              <.document_card :for={doc <- @documents} document={doc} />
            <% end %>
          </section>
        </main>
    </.app_shell>
    <Layouts.flash_group flash={@flash} />
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  attr :upload, :any, required: true

  def contract_upload_menu(assigns) do
    ~H"""
    <div
      id="contract-upload-menu"
      class="contract-upload-menu"
      data-role="dashboard-upload-popover"
    >
      <div class="contract-upload-menu__row">
        <img src={~p"/assets/icons/document.svg"} alt="" class="size-5" />
        <div>
          <strong>{dgettext("dashboard", "파일에서 가져오기")}</strong>
          <p>{dgettext("dashboard", "기존 계약서 파일을 Studio로 가져옵니다.")}</p>
        </div>
      </div>

      <div class="contract-upload-menu__divider"></div>

      <.form
        for={%{}}
        as={:upload}
        id="dashboard-upload-form"
        phx-change="contract_upload_validate"
        class="contract-upload-menu__form"
      >
        <label for={@upload.ref} class="contract-upload-menu__picker">
          <.live_file_input
            upload={@upload}
            class="sr-only"
            data-role="dashboard-upload-input"
          />
          <span>{dgettext("dashboard", "PDF, DOCX, HWP 지원")}</span>
          <span>{dgettext("dashboard", "Studio에서 열립니다.")}</span>
        </label>
      </.form>
    </div>
    """
  end

  attr :document, :map, required: true

  def document_card(assigns) do
    ~H"""
    <article
      id={"document-card-#{@document.document_id}"}
      class="document-card"
      data-role="document-card"
    >
      <.link navigate={~p"/studio/#{@document.document_id}"} class="document-card__open">
        <div class="document-card__thumb" aria-hidden="true">
          <img src={~p"/assets/icons/document.svg"} alt="" class="document-card__thumb-icon" />
        </div>

        <div class="document-card__body">
          <h2 class="document-card__title">{@document.title}</h2>
          <div class="document-card__meta">
            <span class={["status-dot", "status-dot--#{@document.status}"]}></span>
            <span class="document-card__status">{document_status_label(@document.status)}</span>
          </div>
          <time class="document-card__updated">{format_date(@document.updated_at)}</time>
        </div>
      </.link>

      <button
        type="button"
        class="document-card__menu"
        data-role="document-card-menu"
        aria-label={dgettext("dashboard", "문서 메뉴")}
      >
        <img src={~p"/assets/icons/more-vertical.svg"} alt="" class="size-5" />
      </button>
    </article>
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
