defmodule ContractWeb.Live.Studio.Components.ModalHost do
  @moduledoc """
  Studio modal host (Wave 3C1 / modal-host).

  Single `Phoenix.LiveComponent` that owns every modal-style overlay in
  Studio. The parent `ContractWeb.StudioLive` toggles flags on
  `@studio_state` (or on its own `@reconcile_modal_open?` assign); this
  component renders the matching dialog, debounces Esc / backdrop close
  via colocated JS, and emits the Studio event vocabulary back to the
  parent.

  ## Modals supported

      studio_state.document_picker_open?  → document picker (search + list)
      studio_state.metadata_panel_open?   → edit document metadata
      studio_state.upload_panel_open?     → new-document upload form
      studio_state.migration_panel_open?  → type-conversion wizard (3-step)
      reconcile_modal_open?               → revoke-overlap reconciliation
      modal_param == "new_document"       → create new document picker
      modal_param == "export"             → export format picker

  The first five are driven from parent assigns. The last two live as
  local component state (`:modal_param`) because the parent's
  `update_modal/3` does not map them onto `studio_state`. The parent's
  `open_modal` event with `phx-value-modal=new_document` (or `export`)
  is also captured here via `phx-target={@myself}` so the parent does
  not need a new state field.

  ## Event vocabulary emitted

  All Studio events bubble up to the parent LV — never `phx-target`ed
  here — so the parent's `event_to_action/3` funnel can map them to
  Actions:

      "open_document"               (picker)
      "rename_document"             (metadata)
      "set_contract_type"           (metadata)
      "upload_document"             (upload)
      "request_export"              (export picker)
      "create_variant"              (migration wizard, step 3)
      "create_document"             (new-document modal, via Action kind)
      "resolve_revoke"              (reconcile)

  Component-local events (target=@myself):

      "close_modal"                 — closes by clearing the parent flag
                                      (re-bubbled to the parent LV)
      "select_migration_step"       — moves wizard to step :plan|:fields|:confirm
      "set_field_strategy"          — records a per-field choice
      "set_migration_target"        — records the migration target type
      "set_modal_param"             — flips local :modal_param assign
      "key"                         — Esc dismiss

  ## Migration wizard

  Wave 4 (`Contract.Conversion`) is not yet implemented. The wizard
  renders all three steps (Plan → FieldStrategies → CreateVariant), but
  the planner output and the per-field strategy menu render a "Wave 4
  작업 진행 중" placeholder where the real `plan/4` output would go.
  The step structure is the contract; subagents shipping Wave 4 wire in
  the planner and the strategy enum without changing this surface.
  """

  use ContractWeb, :live_component

  alias Contract.ContractTypes

  # The strategy enum mandated by SPEC for field migration. Rendered as
  # the dropdown options on step 2 of the wizard. Wave 4 will validate
  # these against `Contract.Conversion`.
  @field_strategies ~w(copy_once link_to_matter_field derive reference_only ignore ask_user)a

  @export_formats ~w(pdf docx hwpx html)

  # --- attrs --------------------------------------------------------------

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :current_scope, :map, required: true
  attr :projection, :map, default: %{}
  attr :reconcile_modal_open?, :boolean, default: false
  attr :reconcile_request, :map, default: nil

  # Caller can pre-supply a list of `%{id, title, type_key}` rows for the
  # document picker; falls back to an empty list. DocumentList subagent
  # is the natural source of this data, but the picker does not depend
  # on a sibling component — it just renders whatever it's given.
  attr :documents, :list, default: []

  # Test-only — `render_component` cannot push events, so tests can
  # force step / strategy state directly.
  attr :initial_migration_step, :atom, default: nil
  attr :initial_modal_param, :string, default: nil

  # --- LiveComponent callbacks -------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:modal_param, nil)
     |> assign(:migration_step, :plan)
     |> assign(:migration_target, nil)
     |> assign(:field_strategies, %{})
     |> assign(:picker_query, "")
     |> assign(:export_formats, @export_formats)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign_new(:modal_param, fn -> nil end)
      |> assign_new(:migration_step, fn -> :plan end)
      |> assign_new(:migration_target, fn -> nil end)
      |> assign_new(:field_strategies, fn -> %{} end)
      |> assign_new(:picker_query, fn -> "" end)
      |> assign(:export_formats, @export_formats)
      |> assign(:id, Map.get(assigns, :id))
      |> assign(:studio_state, Map.get(assigns, :studio_state))
      |> assign(:current_scope, Map.get(assigns, :current_scope))
      |> assign(:projection, Map.get(assigns, :projection, %{}))
      |> assign(:reconcile_modal_open?, Map.get(assigns, :reconcile_modal_open?, false))
      |> assign(:reconcile_request, Map.get(assigns, :reconcile_request))
      |> assign(:documents, Map.get(assigns, :documents, []))

    socket =
      case Map.get(assigns, :initial_migration_step) do
        nil -> socket
        step -> assign(socket, :migration_step, step)
      end

    socket =
      case Map.get(assigns, :initial_modal_param) do
        nil -> socket
        param -> assign(socket, :modal_param, param)
      end

    {:ok, socket}
  end

  # --- handle_event/3 ----------------------------------------------------

  # The parent's open_modal event with modal=new_document|export is not
  # mapped into studio_state by the parent's `update_modal/3`. We
  # intercept those two values locally; the others fall through to the
  # parent.
  @impl true
  def handle_event("open_modal", %{"modal" => "new_document"}, socket) do
    {:noreply, assign(socket, :modal_param, "new_document")}
  end

  def handle_event("open_modal", %{"modal" => "export"}, socket) do
    {:noreply, assign(socket, :modal_param, "export")}
  end

  def handle_event("set_modal_param", %{"value" => value}, socket) do
    {:noreply, assign(socket, :modal_param, value)}
  end

  def handle_event("close_modal_local", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal_param, nil)
     |> assign(:migration_step, :plan)
     |> assign(:migration_target, nil)
     |> assign(:field_strategies, %{})
     |> assign(:picker_query, "")}
  end

  def handle_event("select_migration_step", %{"step" => step}, socket)
      when step in ["plan", "fields", "confirm"] do
    {:noreply, assign(socket, :migration_step, String.to_atom(step))}
  end

  def handle_event("set_migration_target", %{"type_key" => key}, socket) do
    {:noreply, assign(socket, :migration_target, key)}
  end

  def handle_event(
        "set_field_strategy",
        %{"field_id" => field_id, "strategy" => strategy},
        socket
      ) do
    strategies = Map.put(socket.assigns.field_strategies, field_id, strategy)
    {:noreply, assign(socket, :field_strategies, strategies)}
  end

  def handle_event("picker_query", %{"value" => value}, socket) do
    {:noreply, assign(socket, :picker_query, value)}
  end

  # Esc keydown reaches us when the active modal is new_document/export
  # (local state). For state-driven modals, Esc bubbles to the parent
  # LV via phx-window-keydown="close_modal" (see render_*).
  def handle_event("key", %{"key" => "Escape"}, socket) do
    if socket.assigns.modal_param in ["new_document", "export"] do
      {:noreply,
       socket
       |> assign(:modal_param, nil)
       |> assign(:migration_step, :plan)
       |> assign(:migration_target, nil)
       |> assign(:field_strategies, %{})}
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
      truthy?(state && state.upload_panel_open?) or
      truthy?(state && state.migration_panel_open?) or
      truthy?(assigns[:reconcile_modal_open?]) or
      assigns[:modal_param] in ["new_document", "export"]
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
      label = spec.name_ko || spec.name_en
      {label, spec.key}
    end)
  end

  defp strategy_options do
    Enum.map(@field_strategies, fn s ->
      {strategy_label(s), Atom.to_string(s)}
    end)
  end

  defp strategy_label(:copy_once), do: dgettext("studio", "Copy once (snapshot)")
  defp strategy_label(:link_to_matter_field), do: dgettext("studio", "Link to matter field")
  defp strategy_label(:derive), do: dgettext("studio", "Derive")
  defp strategy_label(:reference_only), do: dgettext("studio", "Reference only")
  defp strategy_label(:ignore), do: dgettext("studio", "Ignore")
  defp strategy_label(:ask_user), do: dgettext("studio", "Ask user")

  defp format_label("pdf"), do: "PDF"
  defp format_label("docx"), do: "Word (DOCX)"
  defp format_label("hwpx"), do: "한글 (HWPX)"
  defp format_label("html"), do: "HTML"
  defp format_label(other), do: other

  # --- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-role="modal-host" data-any-open={to_string(any_modal_open?(assigns))}>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ModalEsc">
        export default {
          // Forwards a single Escape keydown to the LiveComponent. The
          // component decides whether to act on it (only when one of
          // the local-state modals — new_document / export — is open;
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
        <% @studio_state && @studio_state.upload_panel_open? -> %>
          {render_upload_panel(assigns)}
        <% @studio_state && @studio_state.migration_panel_open? -> %>
          {render_migration_wizard(assigns)}
        <% @reconcile_modal_open? -> %>
          {render_reconcile_modal(assigns)}
        <% @modal_param == "new_document" -> %>
          {render_new_document_modal(assigns)}
        <% @modal_param == "export" -> %>
          {render_export_modal(assigns)}
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
              phx-click="open_document"
              phx-value-document_id={doc_field(doc, :id)}
            >
              <span class="font-medium">{doc_field(doc, :title)}</span>
              <span :if={doc_field(doc, :type_key)} class="text-xs text-base-content/60">
                {doc_field(doc, :type_key)}
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
      |> assign(
        :current_notes,
        projection |> Map.get(:metadata, %{}) |> Map.get(:notes, "")
      )

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

        <.form
          for={%{}}
          as={:metadata}
          phx-submit="rename_document"
          data-role="metadata-rename-form"
        >
          <.input
            type="text"
            name="title"
            value={@current_title}
            label={dgettext("studio", "Title")}
          />
          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Save title")}
          </button>
        </.form>

        <.form
          for={%{}}
          as={:type}
          phx-submit="set_contract_type"
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
          phx-submit="update_metadata"
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

  defp render_upload_panel(assigns) do
    ~H"""
    <div
      id={"#{@id}-upload-panel"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-upload-title"}
      data-modal="upload"
    >
      <div
        id={"#{@id}-upload-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="upload"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="upload"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-md">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-upload-title"} class="text-lg font-semibold">
            {dgettext("studio", "Upload a document")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="upload"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <.form
          for={%{}}
          as={:upload}
          phx-submit="upload_document"
          phx-change="upload_document"
          data-role="upload-form"
        >
          <%!--
            `<.live_file_input>` requires the parent LV to declare
            `allow_upload/3`. Until that lands in StudioLive we render a
            plain file input so the form shell is real and clickable;
            the parent's `event_to_action/3` already maps
            `"upload_document"` regardless of payload shape.
          --%>
          <.input
            type="file"
            name="upload"
            value={nil}
            label={dgettext("studio", "Choose a file")}
            accept=".pdf,.docx,.hwpx,.txt,.md"
            data-role="upload-file-input"
          />

          <.input
            type="text"
            name="title"
            value=""
            label={dgettext("studio", "Title (optional)")}
          />

          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Upload")}
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp render_migration_wizard(assigns) do
    ~H"""
    <div
      id={"#{@id}-migration-wizard"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-migration-title"}
      data-modal="migration"
    >
      <div
        id={"#{@id}-migration-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="migration"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="migration"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-2xl">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-migration-title"} class="text-lg font-semibold">
            {dgettext("studio", "Convert document type")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="migration"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <ul class="steps w-full mb-4" data-role="migration-steps">
          <li class={["step", @migration_step in [:plan, :fields, :confirm] && "step-primary"]}>
            {dgettext("studio", "Plan")}
          </li>
          <li class={["step", @migration_step in [:fields, :confirm] && "step-primary"]}>
            {dgettext("studio", "Field strategies")}
          </li>
          <li class={["step", @migration_step == :confirm && "step-primary"]}>
            {dgettext("studio", "Confirm")}
          </li>
        </ul>

        <%= case @migration_step do %>
          <% :plan -> %>
            {render_migration_plan(assigns)}
          <% :fields -> %>
            {render_migration_fields(assigns)}
          <% :confirm -> %>
            {render_migration_confirm(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  defp render_migration_plan(assigns) do
    ~H"""
    <section data-role="migration-step-plan">
      <p class="text-sm text-base-content/70 mb-3">
        {dgettext("studio", "Pick the target contract type. The planner will report which fields can carry over.")}
      </p>

      <.form
        for={%{}}
        as={:plan}
        phx-change="set_migration_target"
        phx-submit="set_migration_target"
        phx-target={@myself}
      >
        <.input
          type="select"
          name="type_key"
          value={@migration_target}
          label={dgettext("studio", "Target type")}
          options={type_options()}
          prompt={dgettext("studio", "Choose a target type…")}
          data-role="migration-target-select"
        />
      </.form>

      <%!--
        TODO(Wave 4): wire `Contract.Conversion.plan/4` here. For now we
        show the placeholder so subagents implementing the migration
        runner know the structural slot exists.
      --%>
      <div
        class="alert alert-info mt-3"
        data-role="migration-plan-placeholder"
      >
        <span>{dgettext("studio", "Wave 4 작업 진행 중 — planner output will appear here.")}</span>
      </div>

      <div class="modal-action">
        <button
          type="button"
          class="btn btn-sm"
          phx-click="close_modal"
          phx-value-modal="migration"
        >
          {dgettext("studio", "Cancel")}
        </button>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="select_migration_step"
          phx-value-step="fields"
          phx-target={@myself}
          disabled={is_nil(@migration_target)}
          data-role="migration-next-fields"
        >
          {dgettext("studio", "Next: field strategies")}
        </button>
      </div>
    </section>
    """
  end

  defp render_migration_fields(assigns) do
    ~H"""
    <section data-role="migration-step-fields">
      <p class="text-sm text-base-content/70 mb-3">
        {dgettext("studio", "Choose how each source field is carried over.")}
      </p>

      <%!--
        TODO(Wave 4): the strategy planner returns the actual field
        list. Until then we render an empty table shell so callers see
        the contract.
      --%>
      <div
        class="alert alert-info"
        data-role="migration-fields-placeholder"
      >
        <span>{dgettext("studio", "Wave 4 작업 진행 중 — per-field strategy picker.")}</span>
      </div>

      <table class="table table-sm mt-3" data-role="migration-fields-table">
        <thead>
          <tr>
            <th>{dgettext("studio", "Source field")}</th>
            <th>{dgettext("studio", "Strategy")}</th>
          </tr>
        </thead>
        <tbody>
          <%!-- Placeholder row so the markup exists for assertions. --%>
          <tr data-role="migration-field-row">
            <td>—</td>
            <td>
              <.form
                for={%{}}
                as={:strategy}
                phx-change="set_field_strategy"
                phx-target={@myself}
              >
                <input type="hidden" name="field_id" value="placeholder" />
                <.input
                  type="select"
                  name="strategy"
                  value={Map.get(@field_strategies, "placeholder", "copy_once")}
                  options={strategy_options()}
                />
              </.form>
            </td>
          </tr>
        </tbody>
      </table>

      <div class="modal-action">
        <button
          type="button"
          class="btn btn-sm"
          phx-click="select_migration_step"
          phx-value-step="plan"
          phx-target={@myself}
        >
          {dgettext("studio", "Back")}
        </button>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="select_migration_step"
          phx-value-step="confirm"
          phx-target={@myself}
          data-role="migration-next-confirm"
        >
          {dgettext("studio", "Next: confirm")}
        </button>
      </div>
    </section>
    """
  end

  defp render_migration_confirm(assigns) do
    ~H"""
    <section data-role="migration-step-confirm">
      <p class="text-sm text-base-content/70 mb-3">
        {dgettext("studio", "Review and create the converted variant. This does not modify the original document.")}
      </p>

      <dl class="text-sm space-y-1 mb-4" data-role="migration-summary">
        <div>
          <dt class="inline font-medium">{dgettext("studio", "Target type:")}</dt>
          <dd class="inline">{@migration_target || dgettext("studio", "—")}</dd>
        </div>
        <div>
          <dt class="inline font-medium">{dgettext("studio", "Fields with explicit strategies:")}</dt>
          <dd class="inline">{map_size(@field_strategies)}</dd>
        </div>
      </dl>

      <.form
        for={%{}}
        as={:variant}
        phx-submit="create_variant"
        data-role="migration-create-form"
      >
        <input type="hidden" name="target_type_key" value={@migration_target || ""} />
        <input
          type="hidden"
          name="field_strategies"
          value={Jason.encode!(@field_strategies)}
        />

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-sm"
            phx-click="select_migration_step"
            phx-value-step="fields"
            phx-target={@myself}
          >
            {dgettext("studio", "Back")}
          </button>
          <button
            type="submit"
            class="btn btn-primary btn-sm"
            disabled={is_nil(@migration_target)}
            data-role="migration-create-variant"
          >
            {dgettext("studio", "Create variant")}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  defp render_reconcile_modal(assigns) do
    ~H"""
    <div
      id={"#{@id}-reconcile"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-reconcile-title"}
      data-modal="reconcile"
    >
      <div
        id={"#{@id}-reconcile-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="reconcile"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="reconcile"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-lg">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-reconcile-title"} class="text-lg font-semibold">
            {dgettext("studio", "Resolve revoke conflict")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="reconcile"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <p class="text-sm text-base-content/70 mb-3">
          {dgettext("studio", "Another change has touched the same content since you asked to revoke. Choose how to proceed.")}
        </p>

        <pre
          class="bg-base-200 rounded-md p-3 text-xs font-mono overflow-auto max-h-48"
          data-role="reconcile-diff"
        ><%= inspect(@reconcile_request, pretty: true) %></pre>

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-sm"
            phx-click="resolve_revoke"
            phx-value-resolution="cancel"
            data-role="reconcile-cancel"
          >
            {dgettext("studio", "Cancel revoke")}
          </button>
          <button
            type="button"
            class="btn btn-warning btn-sm"
            phx-click="resolve_revoke"
            phx-value-resolution="force"
            data-role="reconcile-force"
          >
            {dgettext("studio", "Force revoke")}
          </button>
        </div>
      </div>
    </div>
    """
  end

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
          as={:command_palette_picked}
          phx-submit="command_palette_picked"
          data-role="new-document-form"
        >
          <%!-- Routed through command_palette_picked so the parent's
                event_to_action funnel can build the right Action kind. --%>
          <input type="hidden" name="kind" value="create_document" />

          <.input
            type="select"
            name="type_key"
            value={nil}
            label={dgettext("studio", "Contract type")}
            options={type_options()}
            prompt={dgettext("studio", "Choose a type…")}
          />

          <.input
            type="text"
            name="title"
            value=""
            label={dgettext("studio", "Initial title")}
          />

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

  defp render_export_modal(assigns) do
    ~H"""
    <div
      id={"#{@id}-export"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-export-title"}
      data-modal="export"
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
          <h2 id={"#{@id}-export-title"} class="text-lg font-semibold">
            {dgettext("studio", "Export document")}
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
          {dgettext("studio", "Pick an output format.")}
        </p>

        <ul class="menu menu-sm w-full" data-role="export-format-list">
          <li :for={format <- @export_formats} id={"export-#{format}"}>
            <button
              type="button"
              phx-click="request_export"
              phx-value-format={format}
              data-format={format}
            >
              {format_label(format)}
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

end
