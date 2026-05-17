defmodule ContractWeb.DashboardLive do
  @moduledoc """
  Authenticated home for Contract Studio. Shows a greeting, a Resume link
  to the most-recent document, recent documents, and an activity feed.

  Per the 2026-05-15 product directives:

    * "a lawyer is not a programmer" — the dashboard no longer counts
      things; the old stat row (active matters / documents / open
      agent runs) was removed.
    * Document-pivot — Matter is an internal context container, not a
      user-facing object. The Matters dashboard section is dropped
      entirely; the user-facing label policy is "Workspace" or hidden,
      and we chose hidden here. Existing matter rows are still listed
      visibility-wise through `Contract.Matters.list_for_scope/1` for
      the New-Document fallback path.

  ## Data sources

    * `Contract.Documents.list_recent_for_scope/2` — recent owner-scoped
      documents. The head of this list drives the "Resume" affordance in
      the greeting area.
    * `Contract.ContractTypes.list/2` — compile-time TOML-backed type
      registry, drives the "New Document" modal.
    * `Contract.Repo.all/1` on a small `changes` query — flattened into
      an activity feed.
  """
  use ContractWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Contract.Change
  alias Contract.ContractTypes
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, contract_types} = ContractTypes.list(socket.assigns.current_scope)

    socket =
      socket
      |> assign(:page_title, dgettext("dashboard", "Dashboard"))
      |> assign(:show_new_doc_modal, false)
      |> assign(:contract_types, contract_types)
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_event("open_new_document", _params, socket) do
    {:noreply, assign(socket, :show_new_doc_modal, true)}
  end

  def handle_event("close_new_document", _params, socket) do
    {:noreply, assign(socket, :show_new_doc_modal, false)}
  end

  # Per SPEC.md §18 a document is created untyped (`type_key: nil`); the
  # type is set later via `Command(:set_contract_type)` by the user or agent.
  # v0.5 removes Matter from the product model, so creation is owner-scoped
  # through `Documents.create/2` and navigation is `/documents/:document_id`.
  def handle_event("create_new_document", %{"title" => title}, socket)
      when is_binary(title) do
    scope = socket.assigns.current_scope

    case Documents.create(scope, %{"title" => title}) do
      {:ok, doc} ->
        {:noreply,
         socket
         |> assign(:show_new_doc_modal, false)
         |> load_data()
         |> put_flash(
           :info,
           dgettext(
             "dashboard",
             "New document created. Pick a contract type with Cmd+K, or let the agent suggest one."
           )
         )
         |> push_navigate(to: ~p"/documents/#{doc.id}")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           dgettext("dashboard", "Could not create the document.")
         )}
    end
  end

  defp load_data(socket) do
    recent_documents = list_recent_documents(socket.assigns.current_scope)
    ftc_templates = list_ftc_templates()
    activity = list_activity(socket.assigns.current_scope)

    socket
    |> assign(:recent_documents, recent_documents)
    |> assign(:resume_document, most_recent_document(recent_documents))
    |> assign(:ftc_templates, ftc_templates)
    |> assign(:activity, activity)
  end

  # `list_recent_for_scope/2` returns documents newest-first, so the head
  # of the list (if any) is the lawyer's "resume" target. We guard
  # against `:template` documents (FTC seeds in the special system matter)
  # so the Resume link never points the user back into a template.
  defp most_recent_document([]), do: nil

  defp most_recent_document([%{status: :template} | rest]),
    do: most_recent_document(rest)

  defp most_recent_document([doc | _]), do: doc

  # FTC templates still need a v0.5 source-document backed model. Until that
  # lands, keep the dashboard document-first and omit the legacy Matter query.
  defp list_ftc_templates, do: []

  # Single source of truth for the dashboard's recent-documents row cap.
  defp recent_documents_limit, do: 20

  defp list_recent_documents(scope) do
    scope
    |> Documents.list_recent_for_scope(limit: recent_documents_limit())
    |> Enum.map(fn d ->
      %{
        document_id: d.id,
        title: d.title,
        type_key: d.type_key,
        status: d.status,
        last_revision: d.latest_revision,
        last_activity_at: d.updated_at
      }
    end)
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  # Last 10 changes for documents owned by the current scope. Keep the
  # rendered activity rows raw, but gate them through documents.owner_id so
  # another user's document activity never appears on this dashboard.
  defp list_activity(%{user: %{id: user_id}}) do
    from(c in Change,
      join: d in Document,
      on: d.id == c.document_id,
      where: d.owner_id == ^user_id,
      order_by: [desc: c.inserted_at],
      limit: 10,
      select: %{
        actor_type: c.actor_type,
        actor_id: c.actor_id,
        action_kind: c.command_kind,
        document_id: c.document_id,
        applied_revision: c.result_revision,
        message: c.message,
        inserted_at: c.inserted_at
      }
    )
    |> Repo.all()
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  defp list_activity(_scope), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <div class="py-10 space-y-10">
        <%!-- ---------------------------------------------------------- --%>
        <%!-- Welcome + primary action                                    --%>
        <%!-- ---------------------------------------------------------- --%>
        <header class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4">
          <div>
            <p class="text-xs font-medium tracking-wide uppercase text-base-content/50">
              {today_label()}
            </p>
            <h1 class="text-3xl font-semibold tracking-tight">
              {dgettext("dashboard", "Good day,")}
              <span class="text-primary">{persona_first_name(@current_scope)}</span>.
            </h1>
            <p class="text-base-content/60 mt-1">
              {dgettext("dashboard", "Pick up where you left off, or start a new document.")}
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="open_new_document"
              class="btn btn-primary flex-1 sm:flex-none"
            >
              <.icon name="hero-document-plus" class="size-4" /> {dgettext(
                "dashboard",
                "New Document"
              )}
            </button>
            <.link navigate={~p"/studio"} class="btn btn-ghost flex-1 sm:flex-none">
              {dgettext("dashboard", "Open Studio")} <span aria-hidden="true">→</span>
            </.link>
          </div>
        </header>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- Resume affordance                                           --%>
        <%!--                                                              --%>
        <%!-- Replaces the old stat row (active matters / documents /     --%>
        <%!-- open agent runs). A lawyer doesn't care about counts —      --%>
        <%!-- they care about getting back to the document they were      --%>
        <%!-- working on. When there's no recent document the slot is     --%>
        <%!-- not rendered at all; the Documents section's empty state    --%>
        <%!-- already covers that case.                                   --%>
        <%!-- ---------------------------------------------------------- --%>
        <section
          :if={@resume_document}
          id="dashboard-resume"
          class="rounded-box border border-base-200 bg-base-100 px-5 py-4 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2"
        >
          <div class="min-w-0">
            <p class="text-xs font-medium tracking-wide uppercase text-base-content/50">
              {dgettext("dashboard", "Resume your most recent document")}
            </p>
            <.link
              navigate={~p"/documents/#{@resume_document.document_id}"}
              class="text-base font-medium hover:underline truncate block mt-1"
              data-role="dashboard-resume-link"
            >
              {@resume_document.title}
            </.link>
          </div>
          <.link
            navigate={~p"/documents/#{@resume_document.document_id}"}
            class="text-sm text-base-content/60 hover:text-base-content shrink-0"
          >
            {dgettext("dashboard", "Open")} <span aria-hidden="true">→</span>
          </.link>
        </section>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- Matters section dropped per SPEC.md Document-pivot           --%>
        <%!-- (Workspace label or hidden — chose hidden).                  --%>
        <%!-- ---------------------------------------------------------- --%>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- Recent documents                                            --%>
        <%!-- ---------------------------------------------------------- --%>
        <section id="recent-documents">
          <header class="flex items-end justify-between mb-4">
            <h2 class="text-lg font-semibold tracking-tight">
              {dgettext("dashboard", "Recent documents")}
            </h2>
          </header>

          <%= if @recent_documents == [] do %>
            <div
              id="documents-empty"
              class="rounded-box border border-dashed border-base-300 p-8 text-center bg-base-200/30 text-sm text-base-content/60"
            >
              {dgettext(
                "dashboard",
                "No documents yet. Drag a PDF in, or start from a contract type."
              )}
            </div>
          <% else %>
            <div class="overflow-x-auto rounded-box border border-base-200 bg-base-100">
              <table id="documents-list" class="table table-sm">
                <thead class="text-xs uppercase tracking-wide text-base-content/60">
                  <tr class="border-b border-base-200">
                    <th class="font-medium">{dgettext("dashboard", "Title")}</th>
                    <th class="font-medium">{dgettext("dashboard", "Type")}</th>
                    <th class="hidden sm:table-cell font-medium">
                      {dgettext("dashboard", "Status")}
                    </th>
                    <th class="font-medium text-right">
                      {dgettext("dashboard", "Last revision")}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={doc <- @recent_documents}
                    class="border-b border-base-200 last:border-b-0 hover:bg-base-200/30"
                  >
                    <td class="min-w-0">
                      <.link
                        navigate={~p"/documents/#{doc.document_id}"}
                        class="font-medium hover:underline"
                      >
                        {doc.title}
                      </.link>
                    </td>
                    <td>
                      <span class="badge badge-ghost badge-sm" title={doc.type_key}>
                        {Contract.ContractTypes.display_name(doc.type_key)}
                      </span>
                    </td>
                    <td class="hidden sm:table-cell">
                      <span class={[
                        "badge badge-sm",
                        document_status_badge_class(doc.status)
                      ]}>
                        {document_status_label(doc.status)}
                      </span>
                    </td>
                    <td class="text-right text-xs text-base-content/60 tabular-nums">
                      {dgettext("dashboard", "rev %{n}", n: doc.last_revision)} · {format_timestamp(
                        doc.last_activity_at
                      )}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p
              :if={length(@recent_documents) >= recent_documents_limit()}
              data-role="recent-documents-footer"
              class="mt-2 text-xs text-base-content/50 text-right"
            >
              {dgettext("dashboard", "최근 %{n}개 표시 중", n: recent_documents_limit())}
            </p>
          <% end %>
        </section>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- FTC standard contracts (Wave 5)                             --%>
        <%!-- ---------------------------------------------------------- --%>
        <section :if={@ftc_templates != []} id="ftc-templates">
          <header class="flex items-end justify-between mb-4">
            <h2 class="text-lg font-semibold tracking-tight">
              {dgettext("dashboard", "FTC standard contracts")}
            </h2>
            <span class="text-xs text-base-content/50">
              {dgettext("dashboard", "%{count} templates", count: length(@ftc_templates))}
            </span>
          </header>

          <ul
            id="ftc-templates-list"
            class="rounded-box border border-base-200 md:divide-y md:divide-base-200 bg-base-100 space-y-2 md:space-y-0 p-2 md:p-0"
          >
            <li
              :for={tpl <- @ftc_templates}
              class="rounded-box md:rounded-none border border-base-200 md:border-0 bg-base-100 px-4 py-3 flex flex-col md:flex-row md:items-center gap-2 md:gap-4 hover:bg-base-200/30"
            >
              <div class="flex items-center gap-3 min-w-0 md:flex-1">
                <.icon name="hero-document-duplicate" class="size-4 text-primary/70 shrink-0" />
                <.link
                  navigate={~p"/documents/#{tpl.document_id}"}
                  class="text-sm font-medium hover:underline truncate block"
                >
                  {tpl.title}
                </.link>
              </div>
              <div class="flex items-center justify-between md:justify-end gap-2 md:gap-4 pl-7 md:pl-0">
                <span class="badge badge-primary badge-sm" title={tpl.type_key}>
                  {Contract.ContractTypes.display_name(tpl.type_key)}
                </span>
                <span class="text-xs text-base-content/50 md:w-32 md:text-right">
                  {dgettext("dashboard", "FTC template")}
                </span>
              </div>
            </li>
          </ul>
        </section>

        <%!-- ---------------------------------------------------------- --%>
        <%!-- Recent activity                                             --%>
        <%!-- ---------------------------------------------------------- --%>
        <section id="recent-activity" class="w-full lg:max-w-2xl">
          <header class="flex items-end justify-between mb-4">
            <h2 class="text-lg font-semibold tracking-tight">
              {dgettext("dashboard", "Recent activity")}
            </h2>
          </header>

          <%= if @activity == [] do %>
            <div
              id="activity-empty"
              class="rounded-box border border-dashed border-base-300 p-8 text-center bg-base-200/30 text-sm text-base-content/60"
            >
              {dgettext(
                "dashboard",
                "The activity feed will populate as you and the agent make changes."
              )}
            </div>
          <% else %>
            <ol id="activity-feed" class="space-y-3">
              <li :for={event <- @activity} class="flex gap-3">
                <div class="shrink-0 mt-0.5">
                  <span class={[
                    "inline-flex h-6 w-6 items-center justify-center rounded-full text-[0.6rem] font-semibold",
                    actor_class(event.actor_type)
                  ]}>
                    {actor_initial(event.actor_type)}
                  </span>
                </div>
                <div class="flex-1 min-w-0">
                  <p class="text-sm">
                    <span class="font-medium">{actor_label(event.actor_type)}</span>
                    <span class="text-base-content/70">{action_kind_label(event.action_kind)}</span>
                    <span class="text-base-content/50 font-mono text-xs">
                      doc/{String.slice(event.document_id || "", 0, 6)} · {dgettext(
                        "dashboard",
                        "rev %{n}",
                        n: event.applied_revision
                      )}
                    </span>
                  </p>
                  <p :if={event.message} class="text-xs text-base-content/60 truncate mt-0.5">
                    {event.message}
                  </p>
                  <p class="text-xs text-base-content/40 mt-0.5">
                    {format_timestamp(event.inserted_at)}
                  </p>
                </div>
              </li>
            </ol>
          <% end %>
        </section>
      </div>

      <%!-- ------------------------------------------------------------- --%>
      <%!-- New Document modal — title-only per SPEC.md §18                --%>
      <%!--                                                                 --%>
      <%!-- The type picker is gone. Contract type is a key set AFTER       --%>
      <%!-- creation via `Action(:set_contract_type)` — by the user via     --%>
      <%!-- Cmd+K or by the agent once it understands the document          --%>
      <%!-- context. The modal collects only what we cannot infer:          --%>
      <%!-- a title.                                                        --%>
      <%!-- ------------------------------------------------------------- --%>
      <div
        :if={@show_new_doc_modal}
        id="new-document-modal"
        class="modal modal-open"
        phx-window-keydown="close_new_document"
        phx-key="escape"
      >
        <div class="modal-box max-w-md">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h3 class="font-semibold text-lg tracking-tight">
                {dgettext("dashboard", "New document")}
              </h3>
              <p class="text-sm text-base-content/60">
                {dgettext(
                  "dashboard",
                  "Give it a title. The contract type is set later."
                )}
              </p>
            </div>
            <button
              type="button"
              phx-click="close_new_document"
              class="btn btn-sm btn-ghost btn-square"
              aria-label={dgettext("dashboard", "Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <.form
            for={%{}}
            as={:new_document}
            phx-submit="create_new_document"
            class="mt-5 space-y-3"
            data-role="new-document-form"
          >
            <.input
              type="text"
              name="title"
              value=""
              label={dgettext("dashboard", "Title")}
              required
            />

            <p class="text-xs text-base-content/60" data-role="new-document-type-hint">
              {dgettext("dashboard", "Type is set later by you or the agent.")}
            </p>

            <div class="flex justify-end gap-2 pt-2">
              <button
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="close_new_document"
              >
                {dgettext("dashboard", "Cancel")}
              </button>
              <button type="submit" class="btn btn-primary btn-sm">
                {dgettext("dashboard", "Create")}
              </button>
            </div>
          </.form>
        </div>
        <button
          type="button"
          phx-click="close_new_document"
          class="modal-backdrop"
          aria-label={dgettext("dashboard", "Close modal")}
        >
          {dgettext("dashboard", "close")}
        </button>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Small render helpers
  # ---------------------------------------------------------------------------

  defp persona_first_name(%{user: %{email: email}}) when is_binary(email) do
    email |> String.split("@") |> List.first()
  end

  defp persona_first_name(_), do: "there"

  defp today_label do
    Calendar.strftime(DateTime.utc_now(), "%A, %d %B %Y")
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%NaiveDateTime{} = t),
    do: t |> DateTime.from_naive!("Etc/UTC") |> format_timestamp()

  defp format_timestamp(%DateTime{} = t) do
    diff = DateTime.diff(DateTime.utc_now(), t, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(t, "%d %b")
    end
  end

  defp actor_class(:user), do: "bg-primary/15 text-primary"
  defp actor_class(:agent), do: "bg-secondary/15 text-secondary"
  defp actor_class(:lawyer), do: "bg-primary/15 text-primary"
  defp actor_class(:slack), do: "bg-accent/20 text-accent-content"
  defp actor_class(_), do: "bg-base-200 text-base-content/60"

  defp actor_initial(:user), do: "U"
  defp actor_initial(:agent), do: "AI"
  defp actor_initial(:lawyer), do: "L"
  defp actor_initial(:slack), do: "S"
  defp actor_initial(_), do: "·"

  defp actor_label(:user), do: "You"
  defp actor_label(:agent), do: "Agent"
  defp actor_label(:lawyer), do: "Lawyer"
  defp actor_label(:slack), do: "Slack"
  defp actor_label(:system), do: "System"
  defp actor_label(other), do: to_string(other)

  # Activity-feed action labels (#93). Pulls Korean strings from the
  # dashboard gettext domain so the feed reads as Korean copy ("문서 편집")
  # under :ko locale and as the English msgid ("edited document") under
  # :en. The schema stores `action_kind` as a string (see
  # `Contract.Change` — `field :action_kind, :string`), but we accept
  # atoms too so this stays useful for hand-built test payloads.
  defp action_kind_label(kind) when is_atom(kind) and not is_nil(kind),
    do: kind |> Atom.to_string() |> action_kind_label()

  defp action_kind_label("edit_document"), do: dgettext("dashboard", "edited document")
  defp action_kind_label("set_contract_type"), do: dgettext("dashboard", "set type")
  defp action_kind_label("rename_document"), do: dgettext("dashboard", "renamed")
  defp action_kind_label("update_metadata"), do: dgettext("dashboard", "updated metadata")
  defp action_kind_label("add_mark"), do: dgettext("dashboard", "added mark")
  defp action_kind_label("update_mark"), do: dgettext("dashboard", "updated mark")
  defp action_kind_label("revoke_change"), do: dgettext("dashboard", "revoked change")
  defp action_kind_label("resolve_revoke"), do: dgettext("dashboard", "resolved revoke")
  defp action_kind_label("create_document"), do: dgettext("dashboard", "created document")
  defp action_kind_label("archive_document"), do: dgettext("dashboard", "archived")
  defp action_kind_label("restore_document"), do: dgettext("dashboard", "restored")
  defp action_kind_label("duplicate_document"), do: dgettext("dashboard", "duplicated")
  defp action_kind_label("create_converted_variant"), do: dgettext("dashboard", "created variant")
  defp action_kind_label("request_export"), do: dgettext("dashboard", "requested export")
  defp action_kind_label("upload_document"), do: dgettext("dashboard", "uploaded")
  defp action_kind_label("agent_change"), do: dgettext("dashboard", "agent edit")
  defp action_kind_label("chat_message"), do: dgettext("dashboard", "chat")
  defp action_kind_label(other), do: to_string(other)

  # ---------------------------------------------------------------------------
  # Status badges (Wave 4.6: dashboard tables)
  # ---------------------------------------------------------------------------

  defp document_status_label(:active), do: dgettext("dashboard", "Active")
  defp document_status_label(:archived), do: dgettext("dashboard", "Archived")
  defp document_status_label(:template), do: dgettext("dashboard", "Template")
  defp document_status_label(other), do: to_string(other)

  defp document_status_badge_class(:active), do: "badge-ghost"
  defp document_status_badge_class(:archived), do: "badge-ghost opacity-60"
  defp document_status_badge_class(:template), do: "badge-ghost"
  defp document_status_badge_class(_), do: "badge-ghost"
end
