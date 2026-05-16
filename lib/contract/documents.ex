defmodule Contract.Documents do
  @moduledoc """
  Context module for documents and field lineage.

  Every public function (except `touch_revision/2`) takes a
  `%Contract.Context{}` as the first argument. The ACL gate is delegated
  to `Contract.Matters.authorize_read/2`: if a document belongs to a
  matter the scope cannot see, the read returns `{:error, :forbidden}`.

  `touch_revision/2` is the one exception. It is called by
  `Contract.Store.append/3` on the hot commit path, where the scope is
  not in scope; the caller has already passed the lease + idempotency
  gate by then, so we trust the operation.
  """

  import Ecto.Query

  alias Contract.Context
  alias Contract.Documents.Document
  alias Contract.Documents.FieldLineage
  alias Contract.Matters
  alias Contract.Matters.Matter
  alias Contract.Repo
  alias Contract.Types, as: T

  # ----------------------------------------------------------------------------
  # list_for_matter/2
  # ----------------------------------------------------------------------------

  @doc """
  List documents for a matter, gated by the matter's ACL.

  Returns the documents ordered by most recently updated. Archived
  documents are included; callers that want active-only can filter
  after.
  """
  @spec list_for_matter(Context.t(), T.id() | nil) :: [Document.t()]
  def list_for_matter(%Context{} = scope, matter_id) when is_binary(matter_id) do
    case Matters.get(scope, matter_id) do
      {:ok, %Matter{id: id}} ->
        from(d in Document, where: d.matter_id == ^id, order_by: [desc: d.updated_at])
        |> Repo.all()

      {:error, _} ->
        []
    end
  rescue
    Ecto.Query.CastError -> []
  end

  def list_for_matter(_scope, _matter_id), do: []

  # ----------------------------------------------------------------------------
  # list_recent_for_scope/2
  # ----------------------------------------------------------------------------

  @doc """
  List the most recent documents visible to the scope, across all
  matters the scope can see. Limit defaults to 8.

  Includes documents whose matter is hidden (system-created Workspaces
  auto-synthesized by `create_with_auto_matter/2`) — the matter is
  hidden from UI lists, but the Documents inside it are the user's
  real product and MUST surface in recents. ACL is still enforced via
  the tenant filter on `Matters.list_for_scope/2`.
  """
  @spec list_recent_for_scope(Context.t(), pos_integer()) :: [Document.t()]
  def list_recent_for_scope(%Context{} = scope, limit \\ 8) when is_integer(limit) do
    matter_ids =
      Matters.list_for_scope(scope, include_hidden: true) |> Enum.map(& &1.id)

    if matter_ids == [] do
      []
    else
      from(d in Document,
        where: d.matter_id in ^matter_ids,
        order_by: [desc: d.updated_at],
        limit: ^limit
      )
      |> Repo.all()
    end
  end

  # ----------------------------------------------------------------------------
  # get/2
  # ----------------------------------------------------------------------------

  @doc """
  Fetch a single document by id, gated by the matter ACL.
  """
  @spec get(Context.t(), T.id()) ::
          {:ok, Document.t()} | {:error, :not_found | :forbidden}
  def get(%Context{} = scope, document_id) when is_binary(document_id) do
    case Repo.get(Document, document_id) do
      nil ->
        {:error, :not_found}

      %Document{matter_id: matter_id} = doc ->
        case authorize_via_matter(scope, matter_id) do
          :ok -> {:ok, doc}
          err -> err
        end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get(_scope, _document_id), do: {:error, :not_found}

  # ----------------------------------------------------------------------------
  # create/2
  # ----------------------------------------------------------------------------

  @doc """
  Create a document in a matter the scope owns or shares.

  `attrs` must include `:matter_id` and `:title`. `:type_key` is
  optional per SPEC.md §18: a freshly-created document may be untyped,
  with `Action(:set_contract_type)` filling it in later (by the user
  via Cmd+K or by the agent once it understands the document). The ACL
  gate on the matter is enforced before the insert.
  """
  @spec create(Context.t(), %{
          required(:matter_id) => binary,
          optional(:title) => binary,
          optional(:type_key) => binary | nil
        }) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def create(%Context{} = scope, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    matter_id = Map.get(attrs, "matter_id")

    with :ok <- authorize_via_matter(scope, matter_id),
         :ok <- check_no_parent_cycle(attrs) do
      %Document{}
      |> Document.changeset(attrs)
      |> Repo.insert()
    end
  end

  # ----------------------------------------------------------------------------
  # create_with_auto_matter/2 (SPEC.md Document-primary pivot, 2026-05-15)
  # ----------------------------------------------------------------------------

  @doc """
  Create a Document without requiring the user to pick a Matter.

  Per SPEC.md §1/§4/§22/§28 (Document-primary pivot, 2026-05-15): the
  user must NOT be required to pick a Matter to create a Document. If
  `attrs["matter_id"]` is set, this delegates to `create/2` (the existing
  matter is reused, no new matter synthesized). Otherwise the backend
  auto-creates a hidden Matter to host the resulting Document — the
  auto-matter is filtered out of `Contract.Matters.list_for_scope/1`
  unless `include_hidden: true` is passed.

  The auto-matter's `name` is derived from the document title (e.g.
  `"Workspace · My NDA"`) or falls back to `"Workspace · <YYYY-MM-DD>"`
  when no title is supplied. `metadata` is stamped with:

      %{
        "system_created" => true,
        "hidden_from_user" => true,
        "source" => "auto_on_document_create"
      }

  so downstream queries can identify and filter these rows.

  Returns `{:ok, document, matter}` on success. The matter is included
  in the return tuple so callers can route to `/workspaces/:matter_id/...`
  if needed; most callers should route to `/documents/:document_id`.
  """
  @spec create_with_auto_matter(Context.t(), map()) ::
          {:ok, Document.t(), Matter.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def create_with_auto_matter(%Context{} = scope, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    matter_id = Map.get(attrs, "matter_id")

    cond do
      is_binary(matter_id) and matter_id != "" ->
        # Caller passed an explicit matter — reuse it, do NOT synthesize.
        with {:ok, doc} <- create(scope, attrs),
             {:ok, matter} <- Matters.get(scope, matter_id) do
          {:ok, doc, matter}
        end

      true ->
        # No matter_id — auto-create a hidden Matter, then the Document.
        title = Map.get(attrs, "title")

        matter_attrs = %{
          "name" => auto_matter_name(title),
          "metadata" => %{
            "system_created" => true,
            "hidden_from_user" => true,
            "source" => "auto_on_document_create"
          }
        }

        with {:ok, matter} <- Matters.create(scope, matter_attrs),
             doc_attrs = Map.put(attrs, "matter_id", matter.id),
             {:ok, doc} <- create(scope, doc_attrs) do
          {:ok, doc, matter}
        end
    end
  end

  # Build a stable, human-readable name for an auto-created Matter from
  # the Document title. Empty/nil titles fall back to today's date so the
  # row still has a non-empty :name (required by Matter changeset).
  defp auto_matter_name(title) when is_binary(title) do
    case String.trim(title) do
      "" -> "Workspace · " <> today_iso()
      trimmed -> "Workspace · " <> trimmed
    end
  end

  defp auto_matter_name(_), do: "Workspace · " <> today_iso()

  defp today_iso do
    Date.utc_today() |> Date.to_iso8601()
  end

  # ----------------------------------------------------------------------------
  # archive/2 / set_type/3
  # ----------------------------------------------------------------------------

  @doc """
  Archive a document. Visible-only gate; any caller that can see the
  document can archive (the heavy gate is on the matter).
  """
  @spec archive(Context.t(), T.id()) ::
          {:ok, Document.t()} | {:error, term()}
  def archive(%Context{} = scope, document_id) do
    with {:ok, doc} <- get(scope, document_id) do
      doc
      |> Document.changeset(%{"status" => "archived"})
      |> Repo.update()
    end
  end

  @doc """
  Change a document's `:type_key` (SPEC.md §18 — type *selection*, not
  conversion). Conversion goes through `Contract.Conversion`.
  """
  @spec set_type(Context.t(), T.id(), T.contract_type_key()) ::
          {:ok, Document.t()} | {:error, term()}
  def set_type(%Context{} = scope, document_id, type_key) when is_binary(type_key) do
    with {:ok, doc} <- get(scope, document_id) do
      doc
      |> Document.changeset(%{"type_key" => type_key})
      |> Repo.update()
    end
  end

  # ----------------------------------------------------------------------------
  # set_title/2, set_type/2, set_status/2 (called by Store on propagation)
  # ----------------------------------------------------------------------------

  @doc """
  Set a document's `:title`. Called from `Contract.Store.append/3` on the
  hot commit path to mirror the engine's document-level `:set_attr` op
  onto the `documents` table. Not gated by scope: the caller has already
  validated the lease + revision.

  Returns `:ok` regardless of whether the row exists — the documents
  table is a downstream projection and is allowed to lag in test/dev
  fixtures that bypass `Documents.create/2`.
  """
  @spec set_title(T.id(), String.t()) :: :ok
  def set_title(document_id, title) when is_binary(document_id) and is_binary(title) do
    from(d in Document, where: d.id == ^document_id, update: [set: [title: ^title, updated_at: ^now()]])
    |> Repo.update_all([])

    :ok
  rescue
    Postgrex.Error -> :ok
    DBConnection.ConnectionError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def set_title(_, _), do: :ok

  @doc """
  Set a document's `:type_key`. Scope-less variant of `set_type/3` used
  by `Contract.Store.append/3` to propagate engine `:set_attr` ops onto
  the `documents` table. See `set_title/2` for rationale.
  """
  @spec set_type(T.id(), String.t() | nil) :: :ok
  def set_type(document_id, type_key) when is_binary(document_id) do
    cast =
      cond do
        is_binary(type_key) -> type_key
        is_atom(type_key) and not is_nil(type_key) -> Atom.to_string(type_key)
        true -> nil
      end

    from(d in Document, where: d.id == ^document_id, update: [set: [type_key: ^cast, updated_at: ^now()]])
    |> Repo.update_all([])

    :ok
  rescue
    Postgrex.Error -> :ok
    DBConnection.ConnectionError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def set_type(_, _), do: :ok

  @doc """
  Set a document's `:status`. Scope-less variant used by
  `Contract.Store.append/3` to propagate engine `:set_attr` ops onto
  the `documents` table.
  """
  @spec set_status(T.id(), atom() | String.t()) :: :ok
  def set_status(document_id, status) when is_binary(document_id) do
    cast =
      case status do
        s when is_atom(s) -> s
        s when is_binary(s) ->
          try do
            String.to_existing_atom(s)
          rescue
            ArgumentError -> nil
          end
        _ -> nil
      end

    if cast in [:active, :archived, :template] do
      from(d in Document, where: d.id == ^document_id, update: [set: [status: ^cast, updated_at: ^now()]])
      |> Repo.update_all([])
    end

    :ok
  rescue
    Postgrex.Error -> :ok
    DBConnection.ConnectionError -> :ok
    Ecto.Query.CastError -> :ok
  end

  def set_status(_, _), do: :ok

  # ----------------------------------------------------------------------------
  # touch_revision/2 (called by Store)
  # ----------------------------------------------------------------------------

  @doc """
  Bump a document's `latest_revision` to `revision` IFF the supplied
  value is strictly greater than the stored one. Idempotent — replaying
  the same `(document_id, revision)` pair is safe.

  Called by `Contract.Store.append/3` on the hot commit path. Not gated
  by scope: the caller has already validated the lease + revision.
  """
  @spec touch_revision(T.id(), T.revision()) :: :ok
  def touch_revision(document_id, revision)
      when is_binary(document_id) and is_integer(revision) and revision >= 0 do
    from(d in Document,
      where: d.id == ^document_id and d.latest_revision < ^revision,
      update: [set: [latest_revision: ^revision, updated_at: ^now()]]
    )
    |> Repo.update_all([])

    :ok
  rescue
    # Document row may not exist yet (Store.append currently writes
    # Changes without requiring a matching Document row). Silently
    # ignore — `touch_revision` is best-effort.
    Postgrex.Error -> :ok
    DBConnection.ConnectionError -> :ok
  end

  def touch_revision(_, _), do: :ok

  # ----------------------------------------------------------------------------
  # search/2 — substring title search for the command palette
  # ----------------------------------------------------------------------------

  @doc """
  Search documents by case-insensitive title substring within the scope.
  Returns at most `limit` rows (default 20). Includes documents in
  hidden (auto-created) Workspaces — see `list_recent_for_scope/2`.
  """
  @spec search(Context.t(), String.t(), pos_integer()) :: [Document.t()]
  def search(%Context{} = scope, query, limit \\ 20) when is_binary(query) do
    matter_ids =
      Matters.list_for_scope(scope, include_hidden: true) |> Enum.map(& &1.id)

    if matter_ids == [] do
      []
    else
      pattern = "%" <> String.downcase(query) <> "%"

      from(d in Document,
        where: d.matter_id in ^matter_ids,
        where: fragment("lower(?) LIKE ?", d.title, ^pattern),
        order_by: [desc: d.updated_at],
        limit: ^limit
      )
      |> Repo.all()
    end
  end

  # ----------------------------------------------------------------------------
  # Lineage
  # ----------------------------------------------------------------------------

  @doc """
  Insert a single lineage row. Append-only — no update path. Used by
  `Contract.Conversion.create_variant/2`.
  """
  @spec insert_lineage(map()) ::
          {:ok, FieldLineage.t()} | {:error, Ecto.Changeset.t()}
  def insert_lineage(attrs) when is_map(attrs) do
    %FieldLineage{}
    |> FieldLineage.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  @doc """
  List lineage rows for a document.
  """
  @spec list_lineage(Context.t(), T.id()) :: [FieldLineage.t()]
  def list_lineage(%Context{} = scope, document_id) do
    case get(scope, document_id) do
      {:ok, _doc} ->
        from(l in FieldLineage,
          where: l.document_id == ^document_id,
          order_by: [asc: l.inserted_at]
        )
        |> Repo.all()

      _ ->
        []
    end
  end

  @doc """
  Look up a single lineage row for a specific field in a document.
  `field_id` is the TypeSpec field id (string), not a UUID.
  """
  @spec get_lineage_for_field(Context.t(), T.id(), String.t()) ::
          FieldLineage.t() | nil
  def get_lineage_for_field(%Context{} = scope, document_id, field_id) do
    case get(scope, document_id) do
      {:ok, _doc} ->
        Repo.one(
          from l in FieldLineage,
            where: l.document_id == ^document_id and l.field_id == ^field_id,
            limit: 1
        )

      _ ->
        nil
    end
  end

  @doc """
  Walks `:parent_document_id` upward from `document_id` and returns
  `true` if `candidate_parent_id` would close a cycle (i.e. it is
  already an ancestor or the document itself).
  """
  @spec would_create_cycle?(Context.t(), T.id(), T.id()) :: boolean()
  def would_create_cycle?(%Context{} = _scope, document_id, candidate_parent_id) do
    do_cycle_check(document_id, candidate_parent_id, MapSet.new())
  end

  defp do_cycle_check(_doc_id, nil, _seen), do: false

  defp do_cycle_check(doc_id, candidate, _seen) when doc_id == candidate, do: true

  defp do_cycle_check(doc_id, candidate, seen) do
    if MapSet.member?(seen, candidate) do
      true
    else
      case Repo.get(Document, candidate) do
        nil -> false
        %Document{parent_document_id: nil} -> false
        %Document{parent_document_id: ^doc_id} -> true
        %Document{parent_document_id: next} -> do_cycle_check(doc_id, next, MapSet.put(seen, candidate))
      end
    end
  rescue
    Ecto.Query.CastError -> false
  end

  # ----------------------------------------------------------------------------
  # internals
  # ----------------------------------------------------------------------------

  defp authorize_via_matter(_scope, nil), do: {:error, :not_found}

  defp authorize_via_matter(%Context{} = scope, matter_id) do
    case Matters.get(scope, matter_id) do
      {:ok, _matter} -> :ok
      {:error, _} = err -> err
    end
  end

  defp check_no_parent_cycle(%{"parent_document_id" => nil}), do: :ok

  defp check_no_parent_cycle(%{"parent_document_id" => parent}) when is_binary(parent) do
    case Repo.get(Document, parent) do
      nil -> :ok
      %Document{} -> :ok
    end
  rescue
    Ecto.Query.CastError -> :ok
  end

  defp check_no_parent_cycle(_), do: :ok

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()
  end
end
