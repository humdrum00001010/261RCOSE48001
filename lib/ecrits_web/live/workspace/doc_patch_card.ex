defmodule EcritsWeb.Workspace.DocPatchCard do
  @moduledoc """
  One in-flight document patch, drawn as a chat-rail stream entry keyed by
  `edit_id` (Layer 1.5 of `docs/plans/2026-07-26-doclang-engine-migration.md`).

  The patch state is owned by `Ecrits.Doc.EditSession`, one process per patch,
  started by the agent `Session` on the first event that names it. The rail
  holds no patch buffer: it follows `doc_edit:<edit_id>` and re-inserts the same
  `dom_id`, so every delta updates the card in place and the terminal event
  settles it. Deliberately NOT a nested `live_render` — a child LiveView's
  lifetime is bound to its parent socket, so a refresh would kill an in-flight
  patch and a second tab would duplicate it.

  Everything here is a pure function of an `Ecrits.Agent.Event` or an
  `Ecrits.Doc.EditSession` snapshot. `EcritsWeb.Workspace.WorkspaceLive` keeps
  only the parts that need the socket: subscription bookkeeping and
  `stream_insert/3`.
  """

  use EcritsWeb, :html

  import Ecrits.Guards

  alias Ecrits.Agent.Event, as: AgentEvent

  # `Ecrits.Doc.EditSession` stops after publishing any of these.
  @settled_statuses [:committed, :failed, :rejected, :rolled_back, :cancelled, :expired]

  @doc """
  Does this event open a card?

  A card is drawn only for the AUTHORITATIVE patch stream — the doc-VFS
  lifecycle the `Session` re-emits. `:edit_delta` / `:file_change_snapshot` are
  provider-PROPOSED display state (`WorkspaceLive.apply_agent_event/2` already
  refuses to let them touch a document), and their ids are not the VFS `edit_id`
  space, so they must not open a card either.

  Ownership is then explicit: the Session deliberately re-emits UNOWNED edits (a
  user's own save, a `doc.save`) so an open viewer can resync, but those belong
  to no conversation and stay out of the transcript.
  """
  def card_event?(%{type: type} = event, agent_session_id)
      when type in [:doc_edited, :doc_edit_rejected],
      do: field(event, :agent_id) == agent_session_id

  def card_event?(_event, _agent_session_id), do: false

  @doc """
  Does a worker snapshot belong to this rail?

  An unowned patch (no `session_id`) is accepted: it was subscribed to
  deliberately, so refusing it here would strand the card that opened it.
  """
  def snapshot_for_bound_agent?(snapshot, agent_session_id) do
    case Map.get(snapshot, :session_id) do
      session_id when is_present(session_id) ->
        session_id == agent_session_id

      _unowned ->
        true
    end
  end

  @doc """
  Build the stream item.

  One builder for both sources: an `Ecrits.Agent.Event` (first sight) and an
  `EditSession` snapshot (every update after it) describe the same patch.
  """
  def item(source, edit_id) do
    %{
      dom_id: "agent-doc-patch-#{dom_token(edit_id)}",
      role: :doc_patch,
      edit_id: edit_id,
      status: status(source),
      turn_id: field(source, :turn_id),
      document_id: field(source, :document_id),
      path: field(source, :path),
      revision: field(source, :revision),
      body: body(source)
    }
  end

  @doc "True once the patch is terminal — its worker has stopped and its topic is dead."
  def settled?(%{status: status}), do: status in @settled_statuses

  @doc """
  Status text for the card's right-hand label.

  `:accumulating` is `EditSession`'s word for its own buffer; someone watching
  the rail wants the activity, so the in-flight case reads "Editing". Every
  other status already names an outcome.
  """
  def status_label(%{status: :accumulating}), do: "Editing"

  def status_label(%{status: status}),
    do: status |> to_string() |> String.replace("_", " ")

  attr :item, :map, required: true, doc: "a stream item built by `item/2`"

  def card(assigns) do
    ~H"""
    <div
      data-role="doc-patch-card"
      data-edit-id={@item.edit_id}
      data-patch-status={to_string(@item.status)}
      class="min-w-0 px-3 py-1 text-[12px] text-base-content/60"
    >
      <div class="flex min-w-0 items-center gap-1.5">
        <.icon name="hero-pencil-square" class="size-3.5 shrink-0" />
        <span class="shrink-0">Patch:</span>
        <span data-role="doc-patch-target" class="min-w-0 truncate font-mono" title={@item.path}>
          {label(@item)}
        </span>
        <span data-role="doc-patch-status" class="ml-auto shrink-0 text-[11px] text-base-content/70">
          {status_label(@item)}
        </span>
      </div>
      <pre
        :if={@item.body != ""}
        data-role="doc-patch-delta"
        class="mt-1 max-h-40 overflow-y-auto border-l border-base-300 pl-3 whitespace-pre-wrap break-words font-mono text-[11px] leading-relaxed text-base-content/55"
      >{@item.body}</pre>
    </div>
    """
  end

  # The basename is what a reader tracks across a turn; the full path is on the
  # element's title. Falls back through the ids so a patch that named no file
  # still labels itself.
  defp label(item) do
    case item.path do
      path when is_present(path) -> Path.basename(path)
      _other -> item.document_id || item.edit_id || "document"
    end
  end

  # The snapshot names the settled status directly; a raw event carries the VFS
  # lifecycle `phase` instead. Anything else is still accumulating.
  defp status(source) do
    case field(source, :status) do
      status when status in @settled_statuses -> status
      _unsettled -> terminal_phase(field(source, :phase)) || :accumulating
    end
  end

  # Only these two lifecycle phases settle a card; `:candidate` and
  # `:snapshot_ready` are mid-patch. The string spelling is accepted because the
  # phase rides along in a raw lifecycle payload, which is not always cast.
  defp terminal_phase(phase) when phase in [:committed, "committed"], do: :committed
  defp terminal_phase(phase) when phase in [:rejected, "rejected"], do: :rejected
  defp terminal_phase(_phase), do: nil

  defp body(source) do
    case field(source, :delta) do
      delta when is_binary(delta) -> delta
      _other -> ""
    end
  end

  # Reader for the two INCOMING shapes only (event struct, worker snapshot); the
  # item this module builds is read by key. `Ecrits.Agent.Event` folds unnamed
  # provider keys into `payload`, so read it through its own accessor rather
  # than `Map.get/2`, which would stop at the named fields and lose them.
  defp field(%AgentEvent{} = event, key), do: AgentEvent.field(event, key)

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_map, _key), do: nil

  # An `edit_id` is opaque (VFS paths, uuids), and it lands in a DOM id that
  # `phx-update="stream"` matches on.
  defp dom_token(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "root"
      token -> token
    end
  end
end
