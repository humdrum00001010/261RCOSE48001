defmodule ContractWeb.Live.Studio.Components.ContextReservoir do
  @moduledoc """
  Studio left rail: the **Context Reservoir** (SPEC.md §10a).

  Replaces the legacy `DocumentList` in the desktop 3-pane layout. The
  reservoir is a *projection* of contract context (brief / shared fields
  / open questions / related documents / sources / evidence / recent
  changes / readiness), not the source of truth — see §10a and
  `Contract.Studio.ContextReservoir`.

  ## Sections (in render order)

  1. Brief
  2. Shared fields
  3. Open questions
  4. Related documents
  5. Sources
  6. Evidence
  7. Recent changes
  8. Recent revokes
  9. Readiness

  Empty sections collapse (`:if={... != []}`) except **Brief** and
  **Readiness**, which always render — those two are the rail's
  baseline identity even when the document is empty.

  ## Visual language

  Per `feedback-mature-visual-language.md` (Westlaw / Bloomberg tier):
  hairline borders only (`border-base-200`), no shadows, no emerald
  block fills. Korean copy primary via `dgettext("studio", ...)`.

  ## Events

    * `edit_field` (LC-local, `phx-target={@myself}`) — toggles inline
      edit mode for that field. Stores the active field_id in
      `assigns[:editing_field]`.

    * `submit_field` (LC-local, then re-emitted to parent) — converts
      the inline-edit blur into `edit_document` and forwards via
      `send(self(), {:context_reservoir_action, action_attrs})` so the
      parent LV's protocol handler can dispatch it through the funnel.
      Falls back to a `phx-submit="edit_document"` on the form when the
      LC's `handle_event/3` re-fires it, mirroring how `GrillRail`
      keeps draft state but lets the typed Action escape.

    * `open_question_in_chat` (LC-local, re-emitted) — sends
      `{:context_reservoir_focus, question_id}` to the parent so the
      ChatRail can scroll to that question and open the answer
      affordance.

  Document role links use plain `<.link navigate=...>` to the standard
  document-first route — no Action needed.
  """

  use ContractWeb, :live_component

  alias Contract.Studio.ContextReservoir

  # ---- Attribute contract ------------------------------------------------

  attr :id, :string, required: true
  attr :reservoir, :map, required: true
  attr :current_scope, :map, required: true
  attr :layout, :atom, default: :desktop, values: [:desktop, :drawer]

  # ---- Lifecycle ---------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :editing_field, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:layout, fn -> :desktop end)
      |> assign_new(:editing_field, fn -> nil end)

    {:ok, socket}
  end

  # ---- Events ------------------------------------------------------------

  # Toggle the inline edit state for one shared field. Local to the LC —
  # the parent never needs to know which field is currently "open" for
  # edit; that's pure UI state.
  @impl true
  def handle_event("edit_field", %{"field_id" => field_id}, socket) do
    {:noreply, assign(socket, :editing_field, field_id)}
  end

  # Cancel the open editor without submitting.
  def handle_event("cancel_field", _params, socket) do
    {:noreply, assign(socket, :editing_field, nil)}
  end

  # Submit the inline edit. The Action *must* be built by the parent LV's
  # `event_to_action/3` funnel (so persona perms / scope are enforced
  # there), so we send a plain message and let the parent dispatch.
  def handle_event(
        "submit_field",
        %{"field_id" => field_id, "value" => value},
        socket
      ) do
    send(self(), {:context_reservoir_edit_field, field_id, value})
    {:noreply, assign(socket, :editing_field, nil)}
  end

  # A user clicked the "답변하기" link next to an open question — ask
  # the parent to focus that node so the ChatRail can scroll to it.
  def handle_event("open_question_in_chat", %{"question_id" => question_id}, socket) do
    send(self(), {:context_reservoir_focus_question, question_id})
    {:noreply, socket}
  end

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # ---- Render ------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id={@id}
      class={container_class(@layout)}
      data-component="context-reservoir"
      data-role="context-reservoir"
      data-layout={Atom.to_string(@layout)}
      aria-label={dgettext("studio", "Context reservoir")}
    >
      <.brief_section brief={brief(@reservoir)} />

      <.shared_fields_section
        :if={shared_fields(@reservoir) != []}
        fields={shared_fields(@reservoir)}
        editing_field={@editing_field}
        myself={@myself}
        can_edit?={can_edit?(@current_scope)}
      />

      <.open_questions_section
        :if={open_questions(@reservoir) != []}
        questions={open_questions(@reservoir)}
        myself={@myself}
      />

      <.related_documents_section
        :if={related_documents(@reservoir) != []}
        related={related_documents(@reservoir)}
      />

      <.sources_section
        :if={sources(@reservoir) != []}
        sources={sources(@reservoir)}
      />

      <.evidence_section
        :if={evidence(@reservoir) != []}
        evidence={evidence(@reservoir)}
      />

      <.recent_changes_section
        :if={recent_changes(@reservoir) != []}
        changes={recent_changes(@reservoir)}
      />

      <.recent_revokes_section
        :if={recent_revokes(@reservoir) != []}
        revokes={recent_revokes(@reservoir)}
      />

      <.readiness_section readiness={readiness(@reservoir)} />
    </aside>
    """
  end

  # ---- Section partials --------------------------------------------------

  attr :brief, :map, required: true

  defp brief_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4 border-b border-base-200"
      data-role="reservoir-section"
      data-section="brief"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2">
        {dgettext("studio", "Brief")}
      </h2>
      <dl class="text-sm space-y-1">
        <div :if={brief_field(@brief, :title)} class="flex flex-col">
          <dt class="text-xs text-base-content/60">{dgettext("studio", "Title")}</dt>
          <dd class="font-medium truncate" title={brief_field(@brief, :title)}>
            {brief_field(@brief, :title)}
          </dd>
        </div>
        <div :if={brief_field(@brief, :purpose)} class="flex flex-col">
          <dt class="text-xs text-base-content/60">{dgettext("studio", "Purpose")}</dt>
          <dd class="font-medium">{brief_field(@brief, :purpose)}</dd>
        </div>
        <div :if={brief_field(@brief, :status)} class="flex justify-between gap-2">
          <dt class="text-xs text-base-content/60">{dgettext("studio", "Status")}</dt>
          <dd class="font-medium">{to_string(brief_field(@brief, :status))}</dd>
        </div>
        <div :if={brief_field(@brief, :user_role)} class="flex justify-between gap-2">
          <dt class="text-xs text-base-content/60">{dgettext("studio", "User role")}</dt>
          <dd class="font-medium">{brief_field(@brief, :user_role)}</dd>
        </div>
        <div :if={brief_field(@brief, :counterparty_role)} class="flex justify-between gap-2">
          <dt class="text-xs text-base-content/60">{dgettext("studio", "Counterparty")}</dt>
          <dd class="font-medium">{brief_field(@brief, :counterparty_role)}</dd>
        </div>
      </dl>
      <p
        :if={brief_empty?(@brief)}
        class="text-xs text-base-content/50"
        data-role="brief-empty"
      >
        {dgettext("studio", "No brief yet.")}
      </p>
    </section>
    """
  end

  attr :fields, :list, required: true
  attr :editing_field, :string, default: nil
  attr :myself, :any, required: true
  attr :can_edit?, :boolean, default: false

  defp shared_fields_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4 border-b border-base-200"
      data-role="reservoir-section"
      data-section="shared-fields"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2">
        {dgettext("studio", "Shared fields")}
      </h2>
      <dl class="text-sm space-y-2">
        <div
          :for={field <- @fields}
          class="grid grid-cols-[110px_1fr] gap-2 items-baseline"
          data-role="shared-field"
          data-field-id={read(field, :field_id)}
        >
          <dt class="text-xs text-base-content/60 truncate" title={read(field, :label)}>
            {read(field, :label)}
          </dt>
          <dd class="font-medium">
            <%= cond do %>
              <% editing?(field, @editing_field) -> %>
                <form
                  phx-submit="submit_field"
                  phx-target={@myself}
                  data-role="shared-field-form"
                >
                  <input type="hidden" name="field_id" value={read(field, :field_id)} />
                  <input
                    type="text"
                    name="value"
                    value={read(field, :value)}
                    class="input input-xs input-bordered w-full"
                    data-role="shared-field-input"
                    autofocus
                  />
                </form>
              <% @can_edit? -> %>
                <button
                  type="button"
                  phx-click="edit_field"
                  phx-value-field_id={read(field, :field_id)}
                  phx-target={@myself}
                  class="text-left w-full hover:text-primary truncate"
                  data-role="shared-field-edit"
                >
                  {value_or_dash(read(field, :value))}
                </button>
              <% true -> %>
                <span class="truncate" data-role="shared-field-value">
                  {value_or_dash(read(field, :value))}
                </span>
            <% end %>
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :questions, :list, required: true
  attr :myself, :any, required: true

  defp open_questions_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4 border-b border-base-200"
      data-role="reservoir-section"
      data-section="open-questions"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2 flex items-center gap-2">
        <span>{dgettext("studio", "Open questions")}</span>
        <span class="text-base-content/40 tabular-nums" data-role="open-question-count">
          {length(@questions)}
        </span>
      </h2>
      <ul class="text-sm space-y-2" role="list">
        <li
          :for={q <- @questions}
          class="border-l-2 border-warning/40 pl-3 py-1"
          data-role="open-question"
          data-question-id={read(q, :question_id)}
        >
          <p class="leading-snug">{read(q, :text)}</p>
          <button
            type="button"
            phx-click="open_question_in_chat"
            phx-value-question_id={read(q, :question_id)}
            phx-target={@myself}
            class="text-xs link link-primary underline-offset-2 mt-1"
            data-role="open-question-answer-btn"
          >
            {dgettext("studio", "Answer")}
          </button>
        </li>
      </ul>
    </section>
    """
  end

  attr :related, :list, required: true

  defp related_documents_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4 border-b border-base-200"
      data-role="reservoir-section"
      data-section="related-documents"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2">
        {dgettext("studio", "Related documents")}
      </h2>
      <ul class="text-sm space-y-1" role="list">
        <li
          :for={rel <- @related}
          data-role="related-document"
          data-document-id={read(rel, :document_id)}
        >
          <.link
            navigate={~p"/documents/#{read(rel, :document_id)}"}
            class="link link-hover flex items-baseline gap-2"
          >
            <span class="truncate">{related_label(rel)}</span>
            <span class="text-xs text-base-content/40 shrink-0">
              {role_label(read(rel, :role))}
            </span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :sources, :list, required: true

  defp sources_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4 border-b border-base-200"
      data-role="reservoir-section"
      data-section="sources"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2">
        {dgettext("studio", "Sources")}
      </h2>
      <ul class="text-sm space-y-1" role="list">
        <li :for={s <- @sources} data-role="source-item">
          <span class="text-base-content/80">{read(s, :label)}</span>
          <span class="text-xs text-base-content/40 ml-1">{kind_label(read(s, :kind))}</span>
        </li>
      </ul>
    </section>
    """
  end

  attr :evidence, :list, required: true

  defp evidence_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4 border-b border-base-200"
      data-role="reservoir-section"
      data-section="evidence"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2">
        {dgettext("studio", "Evidence")}
      </h2>
      <ul class="text-sm space-y-1" role="list">
        <li :for={e <- @evidence} data-role="evidence-item">
          <span class="text-base-content/80">{read(e, :summary)}</span>
          <span class="text-xs text-base-content/40 ml-1">
            {evidence_source_label(read(e, :source))}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :changes, :list, required: true

  defp recent_changes_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4 border-b border-base-200"
      data-role="reservoir-section"
      data-section="recent-changes"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2">
        {dgettext("studio", "Recent changes")}
      </h2>
      <ul class="text-xs space-y-1" role="list">
        <li
          :for={c <- Enum.take(@changes, 5)}
          class="flex gap-2"
          data-role="recent-change"
        >
          <span class="text-base-content/50 tabular-nums shrink-0">
            {format_timestamp(read(c, :applied_at))}
          </span>
          <span class="text-base-content/80 truncate">
            {change_summary(c)}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :revokes, :list, required: true

  defp recent_revokes_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4 border-b border-base-200"
      data-role="reservoir-section"
      data-section="recent-revokes"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2">
        {dgettext("studio", "Recent revokes")}
      </h2>
      <ul class="text-xs space-y-1" role="list">
        <li
          :for={r <- Enum.take(@revokes, 5)}
          class="flex gap-2"
          data-role="recent-revoke"
        >
          <span class="text-base-content/50 tabular-nums shrink-0">
            {format_timestamp(read(r, :applied_at))}
          </span>
          <span class="text-base-content/80 truncate">
            {change_summary(r)}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :readiness, :map, required: true

  defp readiness_section(assigns) do
    ~H"""
    <section
      class="px-4 py-4"
      data-role="reservoir-section"
      data-section="readiness"
    >
      <h2 class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/60 mb-2">
        {dgettext("studio", "Readiness")}
      </h2>
      <dl class="text-xs space-y-1">
        <div class="flex justify-between gap-2">
          <dt class="text-base-content/60">{dgettext("studio", "Unresolved")}</dt>
          <dd class="font-medium tabular-nums" data-role="readiness-unresolved">
            {readiness_field(@readiness, :unresolved_questions) || 0}
          </dd>
        </div>
        <div class="flex justify-between gap-2">
          <dt class="text-base-content/60">{dgettext("studio", "Export warnings")}</dt>
          <dd class="font-medium tabular-nums" data-role="readiness-export-warnings">
            {readiness_field(@readiness, :export_warnings) || 0}
          </dd>
        </div>
        <div class="flex justify-between gap-2">
          <dt class="text-base-content/60">{dgettext("studio", "Source-modified")}</dt>
          <dd class="font-medium tabular-nums" data-role="readiness-source-modified">
            {readiness_field(@readiness, :source_modified_notes) || 0}
          </dd>
        </div>
        <div class="flex justify-between gap-2">
          <dt class="text-base-content/60">{dgettext("studio", "Packet")}</dt>
          <dd class="font-medium" data-role="readiness-packet">
            {packet_label(readiness_field(@readiness, :lawyer_packet_status))}
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  # ---- Reservoir accessors (string-or-atom safe) -------------------------

  defp brief(%ContextReservoir{brief: brief}), do: brief || %{}
  defp brief(_), do: %{}

  defp shared_fields(%ContextReservoir{shared_fields: list}) when is_list(list), do: list
  defp shared_fields(_), do: []

  defp open_questions(%ContextReservoir{open_questions: list}) when is_list(list), do: list
  defp open_questions(_), do: []

  defp related_documents(%ContextReservoir{related_documents: list}) when is_list(list), do: list
  defp related_documents(_), do: []

  defp sources(%ContextReservoir{sources: list}) when is_list(list), do: list
  defp sources(_), do: []

  defp evidence(%ContextReservoir{evidence: list}) when is_list(list), do: list
  defp evidence(_), do: []

  defp recent_changes(%ContextReservoir{recent_changes: list}) when is_list(list), do: list
  defp recent_changes(_), do: []

  defp recent_revokes(%ContextReservoir{recent_revokes: list}) when is_list(list), do: list
  defp recent_revokes(_), do: []

  defp readiness(%ContextReservoir{readiness: m}) when is_map(m), do: m
  defp readiness(_), do: %{}

  # ---- Field accessors ---------------------------------------------------

  defp read(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp read(_, _), do: nil

  defp brief_field(brief, key) do
    case read(brief, key) do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

  defp brief_empty?(brief) when is_map(brief) do
    Enum.all?(
      [:title, :purpose, :status, :user_role, :counterparty_role],
      &is_nil(brief_field(brief, &1))
    )
  end

  defp brief_empty?(_), do: true

  defp readiness_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp readiness_field(_, _), do: nil

  defp editing?(field, editing_field_id)
       when is_binary(editing_field_id) and editing_field_id != "" do
    to_string(read(field, :field_id)) == editing_field_id
  end

  defp editing?(_, _), do: false

  # ---- Labels ------------------------------------------------------------

  defp value_or_dash(nil), do: dgettext("studio", "—")
  defp value_or_dash(""), do: dgettext("studio", "—")
  defp value_or_dash(v), do: to_string(v)

  defp related_label(rel) do
    case read(rel, :label_ko) do
      v when is_binary(v) and v != "" -> v
      _ -> read(rel, :label_en) || dgettext("studio", "Document")
    end
  end

  defp role_label(:current_draft), do: dgettext("studio", "current draft")
  defp role_label(:source), do: dgettext("studio", "source")
  defp role_label(:variant), do: dgettext("studio", "variant")
  defp role_label(:packet), do: dgettext("studio", "packet")
  defp role_label(role) when is_binary(role), do: role
  defp role_label(_), do: ""

  defp kind_label(:upload), do: dgettext("studio", "upload")
  defp kind_label(:upstage_parse), do: dgettext("studio", "parse")
  defp kind_label(:imported), do: dgettext("studio", "import")
  defp kind_label(kind) when is_binary(kind), do: kind
  defp kind_label(_), do: ""

  defp evidence_source_label(:law_mcp), do: dgettext("studio", "law")
  defp evidence_source_label(:citation_verify), do: dgettext("studio", "citation")
  defp evidence_source_label(:government_comment), do: dgettext("studio", "gov")
  defp evidence_source_label(s) when is_binary(s), do: s
  defp evidence_source_label(_), do: ""

  defp packet_label(:not_started), do: dgettext("studio", "not started")
  defp packet_label(:in_progress), do: dgettext("studio", "in progress")
  defp packet_label(:ready), do: dgettext("studio", "ready")
  defp packet_label(s) when is_binary(s), do: s
  defp packet_label(_), do: dgettext("studio", "not started")

  defp change_summary(c) do
    case read(c, :summary_ko) do
      v when is_binary(v) and v != "" -> v
      _ -> read(c, :summary_en) || read(c, :action_kind) || ""
    end
  end

  # ---- Time formatting ---------------------------------------------------

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%NaiveDateTime{} = t),
    do: t |> DateTime.from_naive!("Etc/UTC") |> format_timestamp()

  defp format_timestamp(%DateTime{} = t) do
    diff = DateTime.diff(DateTime.utc_now(), t, :second)

    cond do
      diff < 60 -> dgettext("studio", "just now")
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h"
      diff < 604_800 -> "#{div(diff, 86_400)}d"
      true -> Calendar.strftime(t, "%d %b")
    end
  end

  defp format_timestamp(_), do: "—"

  # ---- Persona perms -----------------------------------------------------

  defp can_edit?(%{perms: perms}) when is_list(perms), do: :write in perms
  defp can_edit?(_), do: false

  # ---- Layout chrome -----------------------------------------------------

  defp container_class(:drawer) do
    "h-full overflow-y-auto bg-base-100"
  end

  defp container_class(_) do
    "w-[320px] border-r border-base-200 bg-base-100 h-full overflow-y-auto"
  end
end
