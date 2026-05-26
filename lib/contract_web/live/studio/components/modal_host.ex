defmodule ContractWeb.Live.Studio.Components.ModalHost do
  @moduledoc """
  Studio modal host (Wave 3C1 / modal-host).

  Single `Phoenix.LiveComponent` that owns every modal-style overlay in
  Studio. The parent `ContractWeb.StudioLive` toggles flags on
  `@studio_state` (or local component state); this
  component renders the matching dialog, debounces Esc / backdrop close
  via colocated JS, and emits the Studio event vocabulary back to the
  parent.

  ## Modals supported

      studio_state.document_picker_open?  → document picker (search + list)
      studio_state.metadata_panel_open?   → edit document metadata
      studio_state.type_picker_open?      → set-contract-type picker
      modal_param == "new_document"       → create new document picker

  The first three are driven from parent assigns. The last one lives as
  local component state (`:modal_param`) because the parent's
  `update_modal/3` does not map it onto `studio_state`. The parent's
  `open_modal` event with `phx-value-modal=new_document` is also
  captured here via `phx-target={@myself}` so the parent does not need
  a new state field. The type-picker is also opened by the
  global Cmd+K command palette — the parent LV's
  `handle_event("command_palette_picked", %{"kind" =>
  "document.type.set"}, ...)` flips
  `studio_state.type_picker_open?` to true when no `type_key` is
  supplied, and each picker row fires `document.type.set` with the
  chosen `type_key` (which the parent's `event_to_action/3` funnel
  then converts into an Action and flips the flag back to false).

  ## Event vocabulary emitted

  All Studio events bubble up to the parent LV — never `phx-target`ed
  here — so the parent's `event_to_action/3` funnel can map them to
  Actions:

      "document.open"              (picker)
      "document.rename"            (metadata)
      "document.type.set"           (metadata)
      "document.create"             (new-document modal)

  Component-local events (target=@myself):

      "close_modal"                 — closes by clearing the parent flag
                                      (re-bubbled to the parent LV)
      "set_modal_param"             — flips local :modal_param assign
      "key"                         — Esc dismiss
  """

  use ContractWeb, :live_component

  alias Contract.ContractTypes

  # --- attrs --------------------------------------------------------------

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :current_scope, :map, required: true
  attr :projection, :map, default: %{}

  # Caller can pre-supply a list of `%{id, title, type_key}` rows for the
  # document picker; falls back to an empty list. DocumentList subagent
  # is the natural source of this data, but the picker does not depend
  # on a sibling component — it just renders whatever it's given.
  attr :documents, :list, default: []

  # Test-only — `render_component` cannot push events, so tests can
  # force local modal state directly.
  attr :initial_modal_param, :string, default: nil

  # --- LiveComponent callbacks -------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:modal_param, nil)
     |> assign(:picker_query, "")}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign_new(:modal_param, fn -> nil end)
      |> assign_new(:picker_query, fn -> "" end)
      |> assign(:id, Map.get(assigns, :id))
      |> assign(:studio_state, Map.get(assigns, :studio_state))
      |> assign(:current_scope, Map.get(assigns, :current_scope))
      |> assign(:projection, Map.get(assigns, :projection, %{}))
      |> assign(:documents, Map.get(assigns, :documents, []))

    socket =
      case Map.get(assigns, :initial_modal_param) do
        nil -> socket
        param -> assign(socket, :modal_param, param)
      end

    {:ok, socket}
  end

  # --- handle_event/3 ----------------------------------------------------

  # The parent's open_modal event with modal=new_document is not
  # mapped into studio_state by the parent's `update_modal/3`. We
  # intercept that value locally; the others fall through to the
  # parent.
  @impl true
  def handle_event("open_modal", %{"modal" => "new_document"}, socket) do
    {:noreply, assign(socket, :modal_param, "new_document")}
  end

  def handle_event("set_modal_param", %{"value" => value}, socket) do
    {:noreply, assign(socket, :modal_param, value)}
  end

  def handle_event("close_modal_local", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal_param, nil)
     |> assign(:picker_query, "")}
  end

  def handle_event("picker_query", %{"value" => value}, socket) do
    {:noreply, assign(socket, :picker_query, value)}
  end

  # Esc keydown reaches us when the active modal is new_document
  # (local state). For state-driven modals, Esc bubbles to the parent
  # LV via phx-window-keydown="close_modal" (see render_*).
  def handle_event("key", %{"key" => "Escape"}, socket) do
    if socket.assigns.modal_param == "new_document" do
      {:noreply, assign(socket, :modal_param, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("key", _params, socket), do: {:noreply, socket}

  # --- helpers -----------------------------------------------------------

  defp any_modal_open?(assigns) do
    state = assigns.studio_state

    truthy?(state && state.document_picker_open?) or
      truthy?(state && state.metadata_panel_open?) or
      truthy?(state && state.type_picker_open?) or
      assigns[:modal_param] == "new_document"
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp filter_documents(documents, ""), do: documents

  defp filter_documents(documents, query) when is_binary(query) do
    q = String.downcase(query)

    Enum.filter(documents, fn doc ->
      title = doc[:title] || doc["title"] || ""
      String.contains?(String.downcase(to_string(title)), q)
    end)
  end

  defp doc_field(doc, key) do
    doc[key] || doc[Atom.to_string(key)]
  end

  defp type_options do
    {:ok, specs} = ContractTypes.list()

    Enum.map(specs, fn spec ->
      # Use locale-aware display_name so the dropdown shows the user's
      # locale (Korean for ko, English for en). The version + key
      # suffix keeps the technical identifier visible to power users
      # since <option> can only render a single line of text.
      label = "#{ContractTypes.display_name(spec)} · #{spec.key} v#{spec.version}"
      {label, spec.key}
    end)
  end

  # Type-picker variant — returns `{display_name, key, version}` triples
  # so the row template can render the localized name prominently with a
  # `{key} v{version}` secondary line, instead of cramming everything
  # into a single <option>-style string.
  defp type_picker_rows do
    {:ok, specs} = ContractTypes.list()

    specs
    |> Enum.reject(&(&1.source == :custom))
    |> Enum.map(fn spec ->
      {ContractTypes.display_name(spec), spec.key, spec.version}
    end)
  end

  # --- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-role="modal-host" data-any-open={to_string(any_modal_open?(assigns))}>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ModalEsc">
        export default {
          // Forwards a single Escape keydown to the LiveComponent. The
          // component decides whether to act on it (only when the
          // local-state new_document modal is open;
          // for state-driven modals the dialog itself has a
          // window-keydown handler that bubbles straight to the parent
          // LV).
          mounted() {
            this.handler = (e) => {
              if (e.key === "Escape") {
                this.pushEventTo(this.el, "key", {key: "Escape"})
              }
            }
            window.addEventListener("keydown", this.handler)
          },
          destroyed() {
            window.removeEventListener("keydown", this.handler)
          }
        }
      </script>

      <div id={"#{@id}-keys"} phx-hook=".ModalEsc" phx-target={@myself} />

      <%= cond do %>
        <% @studio_state && @studio_state.document_picker_open? -> %>
          {render_document_picker(assigns)}
        <% @studio_state && @studio_state.metadata_panel_open? -> %>
          {render_metadata_panel(assigns)}
        <% @studio_state && @studio_state.type_picker_open? -> %>
          {render_type_picker(assigns)}
        <% @modal_param == "new_document" -> %>
          {render_new_document_modal(assigns)}
        <% true -> %>
          <%!-- No modal active. --%>
      <% end %>
    </div>
    """
  end

  # --- private modal renderers -----------------------------------------

  defp render_document_picker(assigns) do
    assigns =
      assigns
      |> assign(:filtered_documents, filter_documents(assigns.documents, assigns.picker_query))

    ~H"""
    <div
      id={"#{@id}-document-picker"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-document-picker-title"}
      data-modal="document_picker"
    >
      <div
        id={"#{@id}-document-picker-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="document_picker"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="document_picker"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-xl">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-document-picker-title"} class="text-lg font-semibold">
            {dgettext("studio", "Switch document")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="document_picker"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <.form
          for={%{}}
          as={:picker}
          phx-change="picker_query"
          phx-target={@myself}
          phx-submit="picker_query"
        >
          <.input
            type="search"
            name="value"
            value={@picker_query}
            label={dgettext("studio", "Search by title")}
            phx-debounce="200"
            data-role="document-picker-search"
          />
        </.form>

        <ul class="menu menu-sm w-full mt-2" data-role="document-picker-list">
          <li :for={doc <- @filtered_documents} id={"picker-#{doc_field(doc, :id)}"}>
            <button
              type="button"
              phx-click="document.open"
              phx-value-document_id={doc_field(doc, :id)}
            >
              <span class="font-medium">{doc_field(doc, :title)}</span>
              <span :if={doc_field(doc, :type_key)} class="text-xs text-base-content/60">
                {ContractTypes.display_name(doc_field(doc, :type_key))}
              </span>
            </button>
          </li>
          <li :if={@filtered_documents == []} class="text-base-content/60 text-sm px-3 py-2">
            {dgettext("studio", "No documents found.")}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp render_metadata_panel(assigns) do
    projection = assigns.projection || %{}

    assigns =
      assigns
      |> assign(:current_title, Map.get(projection, :title))
      |> assign(:current_type_key, Map.get(projection, :type_key))
      |> assign(:current_notes, projection |> Map.get(:metadata, %{}) |> Map.get(:notes, ""))

    ~H"""
    <div
      id={"#{@id}-metadata-panel"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-metadata-title"}
      data-modal="metadata"
    >
      <div
        id={"#{@id}-metadata-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="metadata"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="metadata"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-lg">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-metadata-title"} class="text-lg font-semibold">
            {dgettext("studio", "Edit document metadata")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="metadata"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>
        <.form for={%{}} as={:metadata} phx-submit="document.rename" data-role="metadata-rename-form">
          <.input type="text" name="title" value={@current_title} label={dgettext("studio", "Title")} />
          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Save title")}
          </button>
        </.form>
        <.form
          for={%{}}
          as={:type}
          phx-submit="document.type.set"
          class="mt-4"
          data-role="metadata-type-form"
        >
          <.input
            type="select"
            name="type_key"
            value={@current_type_key}
            label={dgettext("studio", "Contract type")}
            options={type_options()}
            prompt={dgettext("studio", "Choose a type…")}
          />
          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Apply type")}
          </button>
        </.form>
        <.form
          for={%{}}
          as={:notes}
          phx-submit="document.metadata.update"
          class="mt-4"
          data-role="metadata-notes-form"
        >
          <.input
            type="textarea"
            name="notes"
            value={@current_notes}
            label={dgettext("studio", "Notes")}
          />
          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Save notes")}
          </button>
        </.form>
      </div>
    </div>
    """
  end

  # Per SPEC.md §18 the contract type is set AFTER creation via
  # `Action(:document.type.set)` — by the user via Cmd+K or by the
  # agent once it has read enough context. The new-document modal
  # therefore renders ONLY the title input (required). Ownership comes
  # from `current_scope`; `type_key` is intentionally omitted so the
  # command lands with `type_key: nil`.
  defp render_new_document_modal(assigns) do
    ~H"""
    <div
      id={"#{@id}-new-document"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-new-document-title"}
      data-modal="new_document"
    >
      <div
        class="modal-backdrop"
        phx-click="set_modal_param"
        phx-value-value=""
        phx-target={@myself}
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-md">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-new-document-title"} class="text-lg font-semibold">
            {dgettext("studio", "New document")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="set_modal_param"
            phx-value-value=""
            phx-target={@myself}
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <.form
          for={%{}}
          as={:document}
          phx-submit="document.create"
          data-role="new-document-form"
        >
          <%!-- No `type_key` field — SPEC.md §18 sets it later. --%>
          <.input
            type="text"
            name="title"
            value=""
            label={dgettext("studio", "Title")}
            required
          />

          <p class="text-xs text-base-content/60 mt-1" data-role="new-document-type-hint">
            {dgettext("studio", "Type is set later by you or the agent.")}
          </p>

          <div class="modal-action">
            <button
              type="button"
              class="btn btn-sm"
              phx-click="set_modal_param"
              phx-value-value=""
              phx-target={@myself}
            >
              {dgettext("studio", "Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              {dgettext("studio", "Create")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # Set-contract-type picker. Opened by Cmd+K → "Set contract type…" or by
  # the mobile chat-command-button (both routes fire `command_palette_picked`
  # with `kind=document.type.set` and no `type_key`; the parent LV catches
  # that case and opens this modal).
  #
  # Each row submits the `document.type.set` Action directly (bubbles to
  # the parent LV) with the picked `type_key`. The list is sourced from
  # `Contract.ContractTypes.list/0` so it stays in sync with the registry.
  defp render_type_picker(assigns) do
    assigns = assign(assigns, :contract_types, type_picker_rows())

    ~H"""
    <div
      id={"#{@id}-type-picker"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-type-picker-title"}
      data-modal="type_picker"
      data-role="type-picker"
    >
      <div
        class="modal-backdrop"
        phx-click="set_modal_param"
        phx-value-value=""
        phx-target={@myself}
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-md">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-type-picker-title"} class="text-lg font-semibold">
            {dgettext("studio", "Set contract type")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="set_modal_param"
            phx-value-value=""
            phx-target={@myself}
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <p class="text-sm text-base-content/70 mb-3">
          {dgettext("studio", "Pick a contract type for this document.")}
        </p>

        <ul class="menu menu-sm w-full" data-role="type-picker-list">
          <li :for={{label, key, version} <- @contract_types} id={"type-picker-#{key}"}>
            <button
              type="button"
              phx-click="document.type.set"
              phx-value-type_key={key}
              data-type-key={key}
              data-role="type-picker-row"
            >
              <span class="font-medium">{label}</span>
              <span class="text-xs text-base-content/60 font-mono">{key} · v{version}</span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
