defmodule Contract.Studio do
  @moduledoc """
  Product façade for the one big LiveView. Orchestrates load, select, submit,
  sync, subscribe. See SPEC.md §8.

  Studio is the thin product seam between `ContractWeb.StudioLive` and
  `Contract.Runtime`. It does **not** own document truth — `Store` is truth.
  It only:

    * shapes a `%Contract.Studio.State{}` for the LV to render against;
    * routes UI-level intents (load, select, submit, sync) through the
      `Runtime`;
    * subscribes the calling process to the right PubSub topics so
      `handle_info/2` in the LV receives the §11 protocol messages.
  """

  alias Contract.Command
  alias Contract.Change
  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Matters
  alias Contract.Matters.Matter
  alias Contract.Runtime
  alias Contract.Store
  alias Contract.Studio.ContextReservoir
  alias Contract.Studio.State
  alias Contract.Types, as: T

  @pubsub Contract.PubSub
  @recent_change_limit 10

  # ----------------------------------------------------------------------------
  # load/2
  # ----------------------------------------------------------------------------

  @doc """
  Hydrates a `%Studio.State{}` for the calling LiveView from the routing
  params + scope. Accepts either string-keyed (Phoenix params) or atom-keyed
  maps; the optional keys recognised are `"matter_id"` and `"document_id"`.

  When a `document_id` is present, the call also primes `Runtime.load/2`
  and stamps `last_seen_revision` from the loaded projection. The
  `Runtime.State.projection` itself is returned through the second tuple
  slot so the LV can `assign(:projection, ...)` directly without a
  second round-trip.
  """
  @spec load(T.ctx(), T.params() | map()) :: T.result({State.t(), map()})
  def load(%Context{} = ctx, params) when is_map(params) do
    matter_id = read_param(params, [:matter_id, "matter_id"])
    document_id = read_param(params, [:document_id, "document_id"])

    case do_load(ctx, matter_id, document_id) do
      {:ok, state, projection, revision} ->
        {:ok,
         {%State{
            state
            | last_seen_revision: revision
          }, projection}}

      {:error, _} = err ->
        err
    end
  end

  def load(_ctx, _params), do: {:error, :invalid_params}

  defp do_load(_ctx, matter_id, nil) do
    state = %State{
      matter_id: matter_id,
      selected_document_id: nil,
      mode: :no_document,
      last_seen_revision: 0
    }

    {:ok, state, empty_projection(), 0}
  end

  defp do_load(ctx, matter_id, document_id) do
    case Runtime.load(ctx, document_id) do
      {:ok, %Runtime.State{revision: rev, projection: proj}} ->
        state = %State{
          matter_id: matter_id,
          selected_document_id: document_id,
          mode: derive_mode(document_id, proj),
          last_seen_revision: rev
        }

        {:ok, state, proj, rev}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # reload/2
  # ----------------------------------------------------------------------------

  @doc """
  Reloads the currently-selected document from `Runtime.load/2`. Used after
  a reconnect when the LV doesn't know whether it lost messages.
  """
  @spec reload(T.ctx(), State.t()) :: T.result({State.t(), map()})
  def reload(%Context{} = _ctx, %State{selected_document_id: nil} = state) do
    {:ok, {state, empty_projection()}}
  end

  def reload(%Context{} = ctx, %State{selected_document_id: doc_id} = state) do
    case Runtime.load(ctx, doc_id) do
      {:ok, %Runtime.State{revision: rev, projection: proj}} ->
        {:ok, {%State{state | last_seen_revision: rev}, proj}}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # select_document/3
  # ----------------------------------------------------------------------------

  @doc """
  Switches the LV to a different document. Loads the new document's
  projection and resets ephemeral selection state.
  """
  @spec select_document(T.ctx(), State.t(), T.document_id() | nil) ::
          T.result({State.t(), map()})
  def select_document(_ctx, %State{} = state, nil) do
    new_state = %State{
      state
      | selected_document_id: nil,
        selected_node_id: nil,
        last_seen_revision: 0,
        mode: :no_document,
        agent_run_id: nil
    }

    {:ok, {new_state, empty_projection()}}
  end

  def select_document(%Context{} = ctx, %State{} = state, document_id)
      when is_binary(document_id) do
    case Runtime.load(ctx, document_id) do
      {:ok, %Runtime.State{revision: rev, projection: proj}} ->
        new_state = %State{
          state
          | selected_document_id: document_id,
            selected_node_id: nil,
            last_seen_revision: rev,
            mode: derive_mode(document_id, proj),
            agent_run_id: nil
        }

        {:ok, {new_state, proj}}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # submit/3
  # ----------------------------------------------------------------------------

  @doc """
  Submits an Action. Routes through `Runtime.apply/2` (or `Runtime.revoke/2`
  for revoke kinds). On success, optionally advances `agent_run_id` if the
  action was a `:chat_message` that returned an agent run.

  The LV doesn't mutate the projection from here — `Store.append/3`
  broadcasts `{:change_committed, change}` which `handle_info/2` consumes.
  """
  @spec submit(T.ctx(), State.t(), Command.t()) :: T.result(State.t())
  def submit(%Context{} = ctx, %State{} = state, %Command{} = action) do
    case Runtime.apply(ctx, action) do
      {:ok, %Change{}} ->
        {:ok, state}

      {:ok, %{agent_run_id: agent_run_id} = _agent} when is_binary(agent_run_id) ->
        {:ok, %State{state | agent_run_id: agent_run_id}}

      {:ok, _other} ->
        {:ok, state}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # sync/3
  # ----------------------------------------------------------------------------

  @doc """
  Replays missed changes from `revision` to current head. The caller is
  expected to fold the returned changes into its projection (or simply
  call `reload/2` if it doesn't track op-by-op).
  """
  @spec sync(T.ctx(), State.t(), T.revision()) :: T.result({State.t(), [Change.t()]})
  def sync(_ctx, %State{selected_document_id: nil} = state, _from_revision) do
    {:ok, {state, []}}
  end

  def sync(%Context{} = ctx, %State{selected_document_id: doc_id} = state, from_revision)
      when is_integer(from_revision) and from_revision >= 0 do
    case Runtime.sync_since(ctx, doc_id, from_revision) do
      {:ok, changes} ->
        new_rev =
          changes
          |> Enum.map(& &1.applied_revision)
          |> Enum.max(fn -> state.last_seen_revision end)

        {:ok, {%State{state | last_seen_revision: new_rev}, changes}}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # subscribe/2
  # ----------------------------------------------------------------------------

  @doc """
  Subscribes the calling process to the PubSub topics relevant to this
  Studio session.

    * `document:<id>` — when a document is selected, picks up
      `{:change_committed, change}` and friends per SPEC.md §11.
    * `agent:<run_id>` — only when an agent run is in flight; picks up
      `{:agent_stream, ...}` etc.
  """
  @spec subscribe(T.ctx(), State.t()) :: :ok
  def subscribe(_ctx, %State{selected_document_id: nil, agent_run_id: nil}) do
    :ok
  end

  def subscribe(ctx, %State{selected_document_id: doc_id} = state)
      when is_binary(doc_id) do
    _ = Runtime.subscribe(ctx, doc_id)
    maybe_subscribe_agent(state)
    :ok
  end

  def subscribe(_ctx, %State{} = state) do
    maybe_subscribe_agent(state)
    :ok
  end

  defp maybe_subscribe_agent(%State{agent_run_id: nil}), do: :ok

  defp maybe_subscribe_agent(%State{agent_run_id: id}) when is_binary(id) do
    Phoenix.PubSub.subscribe(@pubsub, "agent:" <> id)
    :ok
  end

  # ----------------------------------------------------------------------------
  # Context Reservoir (SPEC.md §10a)
  # ----------------------------------------------------------------------------

  @doc """
  Build a live projection of the Studio's left rail — see SPEC.md §10a.

  The reservoir is **not** the source of truth. It is a best-effort
  read-side aggregate over Documents / Matters / Store / Marks. Any
  individual section that errors falls back to its empty default rather
  than crashing the call.

  Returns `{:ok, %ContextReservoir{}}` even when no document is
  selected; in that case the reservoir has empty arrays / maps.
  """
  @spec load_context_reservoir(T.ctx(), State.t()) :: T.result(ContextReservoir.t())
  def load_context_reservoir(%Context{} = _ctx, %State{selected_document_id: nil}) do
    {:ok, %ContextReservoir{}}
  end

  def load_context_reservoir(%Context{} = ctx, %State{} = state) do
    doc_id = state.selected_document_id

    document = safe_get_document(ctx, doc_id)
    matter = safe_get_matter(ctx, state.matter_id || document_matter_id(document))
    projection = safe_load_projection(doc_id)
    changes = safe_changes(doc_id)

    marks = collect_change_marks(changes)
    open_questions = build_open_questions(marks)

    reservoir =
      %ContextReservoir{
        brief: build_brief(document, matter, projection),
        shared_fields: build_shared_fields(projection),
        open_questions: open_questions,
        related_documents: build_related_documents(ctx, document, matter),
        sources: build_sources(document, matter),
        evidence: build_evidence(marks),
        recent_changes: build_recent_changes(changes),
        recent_revokes: build_recent_revokes(changes),
        readiness: build_readiness(open_questions, matter)
      }

    {:ok, reservoir}
  end

  @doc """
  Refresh `state.context_reservoir` from the latest reads and return the
  updated state. Convenience wrapper around `load_context_reservoir/2`.
  """
  @spec refresh_context_reservoir(T.ctx(), State.t()) :: T.result(State.t())
  def refresh_context_reservoir(%Context{} = ctx, %State{} = state) do
    {:ok, %ContextReservoir{} = reservoir} = load_context_reservoir(ctx, state)
    {:ok, %State{state | context_reservoir: reservoir}}
  end

  @doc """
  Submit an Action originating in the Context Reservoir UI. Routes
  through `submit/3` exactly like any other action; on success, the
  reservoir is recomputed so the rail reflects the new state.

  This is `submit + refresh_context_reservoir` composed; it is provided
  so the StudioLive doesn't have to know the second step exists.
  """
  @spec submit_context_action(T.ctx(), State.t(), Command.t()) :: T.result(State.t())
  def submit_context_action(%Context{} = ctx, %State{} = state, %Command{} = action) do
    with {:ok, %State{} = next_state} <- submit(ctx, state, action),
         {:ok, %State{} = refreshed} <- refresh_context_reservoir(ctx, next_state) do
      {:ok, refreshed}
    end
  end

  # ---- Reservoir section builders ------------------------------------------------

  defp build_brief(document, matter, projection) do
    matter_meta = matter_metadata(matter)
    proj = if is_map(projection), do: projection, else: %{}

    %{
      purpose: read_string(matter_meta, "purpose"),
      status: doc_status(document),
      user_role: read_string(matter_meta, "user_role"),
      counterparty_role: read_string(matter_meta, "counterparty_role"),
      title: doc_field(document, :title) || Map.get(proj, :title),
      type_key: doc_field(document, :type_key) || Map.get(proj, :type_key)
    }
  end

  defp doc_field(%Document{} = doc, key), do: Map.get(doc, key)
  defp doc_field(_, _), do: nil

  defp doc_status(%Document{status: status}), do: status
  defp doc_status(_), do: :active

  defp build_shared_fields(projection) when is_map(projection) do
    projection
    |> Map.get(:fields, %{})
    |> case do
      map when is_map(map) -> map
      _ -> %{}
    end
    |> Enum.map(fn {field_id, field} ->
      field = if is_map(field), do: field, else: %{}

      %{
        field_id: to_string(field_id),
        label: field |> Map.get(:label) |> field_label(field_id),
        value: stringify_value(Map.get(field, :value)),
        attrs: Map.get(field, :attrs, %{}) || %{}
      }
    end)
  rescue
    _ -> []
  end

  defp build_shared_fields(_), do: []

  defp field_label(nil, field_id), do: to_string(field_id)
  defp field_label("", field_id), do: to_string(field_id)
  defp field_label(label, _), do: to_string(label)

  # Marks live on Change rows (`change.marks`), not in the projection — the
  # Engine.apply path only folds `ops` into the projection. Per SPEC §15 marks
  # are append-only, so flattening the changes list is correct.
  defp collect_change_marks(changes) when is_list(changes) do
    Enum.flat_map(changes, fn
      %Change{marks: marks, id: change_id} when is_list(marks) ->
        Enum.with_index(marks)
        |> Enum.map(fn {mark, idx} ->
          mark
          |> Map.put_new(:change_id, change_id)
          |> Map.put_new(:id, "#{change_id}:#{idx}")
        end)

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  defp collect_change_marks(_), do: []

  defp build_open_questions(marks) when is_list(marks) do
    marks
    |> Enum.filter(&ask_unanswered?/1)
    |> Enum.map(fn mark ->
      data = Map.get(mark, :data) || Map.get(mark, "data") || %{}

      %{
        question_id: to_string(Map.get(mark, :id, "")),
        text: read_mark_field(mark, :text) || "",
        asked_by: read_mark_atom(mark, :source),
        answered_at: Map.get(data, :answered_at) || Map.get(data, "answered_at")
      }
    end)
  rescue
    _ -> []
  end

  defp build_open_questions(_), do: []

  defp ask_unanswered?(mark) when is_map(mark) do
    intent = read_mark_atom(mark, :intent)
    data = Map.get(mark, :data) || Map.get(mark, "data") || %{}

    answered =
      Map.get(data, :answered_at) || Map.get(data, "answered_at")

    intent == :ask and is_nil(answered)
  end

  defp ask_unanswered?(_), do: false

  defp read_mark_field(mark, key) when is_map(mark) do
    Map.get(mark, key) || Map.get(mark, to_string(key))
  end

  defp read_mark_atom(mark, key) when is_map(mark) do
    case read_mark_field(mark, key) do
      v when is_atom(v) -> v
      v when is_binary(v) -> safe_to_existing_atom(v)
      _ -> nil
    end
  end

  defp safe_to_existing_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp build_related_documents(%Context{} = ctx, %Document{} = doc, %Matter{} = matter) do
    related =
      ctx
      |> Documents.list_for_matter(matter.id)
      |> Enum.reject(&(&1.id == doc.id))

    current = [
      %{
        document_id: doc.id,
        label_ko: doc.title || "현재 문서",
        label_en: doc.title || "Current draft",
        role: :current_draft
      }
    ]

    current ++ Enum.map(related, &related_doc_row(&1, doc))
  rescue
    _ -> []
  end

  defp build_related_documents(_ctx, _doc, _matter), do: []

  defp related_doc_row(%Document{} = related, %Document{id: current_id}) do
    role =
      cond do
        related.id == current_id -> :current_draft
        related.variant_of_change_id != nil -> :variant
        related.parent_document_id == current_id -> :variant
        true -> :source
      end

    %{
      document_id: related.id,
      label_ko: related.title || "관련 문서",
      label_en: related.title || "Related document",
      role: role
    }
  end

  defp build_sources(%Document{} = doc, _matter) do
    meta = doc.metadata || %{}

    case Map.get(meta, "source_artifact_id") || Map.get(meta, :source_artifact_id) do
      nil ->
        []

      artifact_id ->
        [
          %{
            artifact_id: to_string(artifact_id),
            kind: source_kind(meta),
            created_at: doc.inserted_at,
            label: source_label(meta, doc)
          }
        ]
    end
  rescue
    _ -> []
  end

  defp build_sources(_doc, _matter), do: []

  defp source_kind(meta) do
    case Map.get(meta, "source_kind") || Map.get(meta, :source_kind) do
      "upload" -> :upload
      :upload -> :upload
      "upstage_parse" -> :upstage_parse
      :upstage_parse -> :upstage_parse
      "imported" -> :imported
      :imported -> :imported
      _ -> :upload
    end
  end

  defp source_label(meta, doc) do
    case Map.get(meta, "source_label") || Map.get(meta, :source_label) do
      label when is_binary(label) and label != "" -> label
      _ -> doc.title || "Source"
    end
  end

  defp build_evidence(marks) when is_list(marks) do
    marks
    |> Enum.filter(&evidence_source?/1)
    |> Enum.map(fn mark ->
      %{
        evidence_id: to_string(Map.get(mark, :id, "")),
        source: read_mark_atom(mark, :source),
        summary: read_mark_field(mark, :text) || ""
      }
    end)
  rescue
    _ -> []
  end

  defp build_evidence(_), do: []

  defp evidence_source?(mark) when is_map(mark) do
    read_mark_atom(mark, :source) in [:law_mcp, :citation_verify, :government_comment]
  end

  defp evidence_source?(_), do: false

  defp build_recent_changes(changes) when is_list(changes) do
    changes
    |> Enum.reject(&revoke_kind?/1)
    |> Enum.sort_by(& &1.applied_revision, :desc)
    |> Enum.take(@recent_change_limit)
    |> Enum.map(&change_row/1)
  rescue
    _ -> []
  end

  defp build_recent_changes(_), do: []

  defp build_recent_revokes(changes) when is_list(changes) do
    changes
    |> Enum.filter(&revoke_kind?/1)
    |> Enum.sort_by(& &1.applied_revision, :desc)
    |> Enum.take(@recent_change_limit)
    |> Enum.map(&change_row/1)
  rescue
    _ -> []
  end

  defp build_recent_revokes(_), do: []

  defp revoke_kind?(%Change{action_kind: kind}) when is_binary(kind) do
    kind in ["revoke_change", "resolve_revoke"]
  end

  defp revoke_kind?(_), do: false

  defp change_row(%Change{} = change) do
    summary = change_summary(change)

    %{
      change_id: change.id,
      action_kind: change.action_kind,
      applied_at: change.inserted_at,
      summary_ko: summary,
      summary_en: summary
    }
  end

  defp change_summary(%Change{action_kind: kind, message: msg}) when is_binary(msg) and msg != "" do
    "#{kind}: #{msg}"
  end

  defp change_summary(%Change{action_kind: kind}), do: kind || ""

  defp build_readiness(open_questions, matter) do
    matter_meta = matter_metadata(matter)

    %{
      unresolved_questions: length(open_questions),
      source_modified_notes: 0,
      export_warnings: 0,
      lawyer_packet_status:
        atomize_status(read_string(matter_meta, "lawyer_packet_status") || "not_started")
    }
  end

  defp atomize_status(value) when is_atom(value), do: value
  defp atomize_status(value) when is_binary(value), do: String.to_atom(value)
  defp atomize_status(_), do: :not_started

  # ---- Defensive readers ---------------------------------------------------------

  defp safe_get_document(_ctx, nil), do: nil

  defp safe_get_document(%Context{} = ctx, doc_id) when is_binary(doc_id) do
    case Documents.get(ctx, doc_id) do
      {:ok, %Document{} = doc} -> doc
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_get_matter(_ctx, nil), do: nil

  defp safe_get_matter(%Context{} = ctx, matter_id) when is_binary(matter_id) do
    case Matters.get(ctx, matter_id) do
      {:ok, %Matter{} = matter} -> matter
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_load_projection(nil), do: empty_projection()

  defp safe_load_projection(doc_id) when is_binary(doc_id) do
    case Store.load(doc_id) do
      {:ok, %Runtime.State{projection: proj}} -> proj
      _ -> empty_projection()
    end
  rescue
    _ -> empty_projection()
  end

  defp safe_changes(nil), do: []

  defp safe_changes(doc_id) when is_binary(doc_id) do
    case Store.changes_since(doc_id, 0) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  end

  defp document_matter_id(%Document{matter_id: matter_id}), do: matter_id
  defp document_matter_id(_), do: nil

  defp matter_metadata(%Matter{metadata: meta}) when is_map(meta), do: meta
  defp matter_metadata(_), do: %{}

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp read_string(_, _), do: nil

  defp stringify_value(nil), do: nil
  defp stringify_value(v) when is_binary(v), do: v
  defp stringify_value(v), do: inspect(v)

  # ----------------------------------------------------------------------------
  # search_documents/2
  # ----------------------------------------------------------------------------

  @doc """
  Substring search across the scope's documents. Routes through
  `Contract.Documents.search/3`; the resulting rows are mapped to the
  shape the command palette expects.
  """
  @spec search_documents(T.ctx(), String.t()) :: [map()]
  def search_documents(_ctx, ""), do: []

  def search_documents(%Context{} = ctx, query) when is_binary(query) do
    ctx
    |> Contract.Documents.search(query, 20)
    |> Enum.map(fn doc ->
      %{
        id: doc.id,
        document_id: doc.id,
        title: doc.title,
        type_key: doc.type_key,
        matter_id: doc.matter_id,
        last_revision: doc.latest_revision
      }
    end)
  end

  def search_documents(_ctx, _query), do: []

  # ----------------------------------------------------------------------------
  # list_documents/2 — for DocumentList sidebar
  # ----------------------------------------------------------------------------

  @doc """
  List documents for a matter, gated by ACL. Returns the shape the
  Studio sidebar uses (`document_id, title, type_key, status,
  last_activity_at, last_revision`).
  """
  @spec list_documents(T.ctx(), T.id() | nil) :: [map()]
  def list_documents(%Context{} = ctx, matter_id) when is_binary(matter_id) do
    ctx
    |> Contract.Documents.list_for_matter(matter_id)
    |> Enum.map(&document_row/1)
  end

  def list_documents(_ctx, _matter_id), do: []

  defp document_row(doc) do
    %{
      document_id: doc.id,
      title: doc.title,
      type_key: doc.type_key,
      status: doc.status,
      last_activity_at: doc.updated_at,
      last_revision: doc.latest_revision
    }
  end

  # ----------------------------------------------------------------------------
  # helpers
  # ----------------------------------------------------------------------------

  defp read_param(params, [key | rest]) do
    case Map.get(params, key) do
      nil -> read_param(params, rest)
      "" -> read_param(params, rest)
      value -> value
    end
  end

  defp read_param(_params, []), do: nil

  # mode derivation: we look at the most recent change for the document.
  # If none, briefing. If the last change was an edit/revoke, editing.
  # If the most recent activity is a review-style action, reviewing.
  # No DB? Fall back to :briefing.
  #
  # SPEC.md §18: untyped documents (no `type_key`) start in `:briefing`
  # regardless of change history — the agent's first job is to
  # understand the document well enough to suggest a contract type.
  # Once `Action(:set_contract_type)` has filled the key in, the normal
  # change-history rules take over.
  defp derive_mode(document_id, projection)
       when is_binary(document_id) and is_map(projection) do
    case Map.get(projection, :type_key) do
      nil -> :briefing
      _typed -> derive_mode_from_history(document_id)
    end
  end

  defp derive_mode(document_id, _projection) when is_binary(document_id) do
    derive_mode_from_history(document_id)
  end

  defp derive_mode(_, _), do: :no_document

  defp derive_mode_from_history(document_id) do
    case Store.changes_since(document_id, 0) do
      {:ok, []} ->
        :briefing

      {:ok, changes} ->
        last = List.last(changes)
        action_kind = last && last.action_kind

        cond do
          action_kind in [
            "edit_document",
            "rename_document",
            "update_metadata",
            "set_contract_type",
            "add_mark",
            "update_mark",
            "agent_change"
          ] ->
            :editing

          action_kind in ["revoke_change", "resolve_revoke"] ->
            :reviewing

          true ->
            :editing
        end
    end
  rescue
    DBConnection.ConnectionError -> :briefing
    Postgrex.Error -> :briefing
  end

  defp empty_projection, do: Runtime.State.empty_projection()
end
