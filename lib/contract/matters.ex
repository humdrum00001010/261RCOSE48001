defmodule Contract.Matters do
  @moduledoc """
  Context module for matters. Every public function takes a
  `%Contract.Context{}` as the first argument and enforces the ACL gate
  defined in SPEC.md §15:

    * tenant: if the matter has a `tenant_id`, it MUST equal the scope's
      `tenant` (or `tenant.id` for struct-shaped tenants). `nil`
      tenant_id matters are visible to any caller (single-tenant case).
    * owner: only the owner may archive (write).

  ACL failures return `{:error, :forbidden}` so callers can map them
  uniformly to 403-style UX.
  """

  import Ecto.Query

  alias Contract.Context
  alias Contract.Matters.Matter
  alias Contract.Repo
  alias Contract.Types, as: T

  # ----------------------------------------------------------------------------
  # list_for_scope/1,2
  # ----------------------------------------------------------------------------

  @doc """
  List active matters visible to the scope.

    * Matters where `tenant_id IS NULL` are always visible.
    * Matters where `tenant_id = scope.tenant.id` are visible.
    * Archived matters are filtered out.

  Per SPEC.md §1/§4 (Document-primary pivot, 2026-05-15): matters with
  `metadata.hidden_from_user = true` (i.e. system-created workspaces
  auto-synthesized by `Contract.Documents.create_with_auto_matter/2`) are
  filtered out of the default user view — the user-facing label is
  "Workspace" or hidden, and the auto-matter is an internal context
  container, not a UX surface.

  Pass `include_hidden: true` to bypass the hidden filter (e.g. lawyer
  packet surfaces, admin tooling). Backwards-compatible: existing
  user-created matters have no `hidden_from_user` flag and stay visible.
  """
  @spec list_for_scope(Context.t()) :: [Matter.t()]
  @spec list_for_scope(Context.t(), keyword()) :: [Matter.t()]
  def list_for_scope(scope, opts \\ [])

  def list_for_scope(%Context{} = scope, opts) when is_list(opts) do
    tenant_id = tenant_id_of(scope)
    include_hidden = Keyword.get(opts, :include_hidden, false)

    base = from m in Matter, where: m.status == :active, order_by: [desc: m.updated_at]

    query =
      case tenant_id do
        nil -> from m in base, where: is_nil(m.tenant_id)
        id -> from m in base, where: is_nil(m.tenant_id) or m.tenant_id == ^id
      end

    query =
      if include_hidden do
        query
      else
        from m in query,
          where: fragment("(?->>'hidden_from_user')::bool IS NOT TRUE", m.metadata)
      end

    Repo.all(query)
  end

  # ----------------------------------------------------------------------------
  # get/2
  # ----------------------------------------------------------------------------

  @doc """
  Fetch a single matter by id, gated by ACL.

  Returns `{:error, :not_found}` if missing, `{:error, :forbidden}` if
  the scope can't see this tenant's matters.
  """
  @spec get(Context.t(), T.id()) ::
          {:ok, Matter.t()} | {:error, :not_found | :forbidden}
  def get(%Context{} = scope, matter_id) when is_binary(matter_id) do
    case Repo.get(Matter, matter_id) do
      nil -> {:error, :not_found}
      %Matter{} = matter -> authorize_read(matter, scope)
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get(_scope, _id), do: {:error, :not_found}

  # ----------------------------------------------------------------------------
  # create/2
  # ----------------------------------------------------------------------------

  @doc """
  Create a matter owned by `scope.user`. The scope's `tenant.id` is
  copied onto the row so the resulting matter is naturally visible only
  to the same tenant.

  Returns `{:error, :forbidden}` if the scope has no user.
  """
  @spec create(Context.t(), map()) ::
          {:ok, Matter.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create(%Context{user: nil}, _attrs), do: {:error, :forbidden}

  def create(%Context{user: user} = scope, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("owner_id", user.id)
      |> Map.put_new("tenant_id", tenant_id_of(scope))

    %Matter{}
    |> Matter.changeset(attrs)
    |> Repo.insert()
  end

  # ----------------------------------------------------------------------------
  # archive/2
  # ----------------------------------------------------------------------------

  @doc """
  Mark a matter as archived. Only the owner may archive.
  """
  @spec archive(Context.t(), T.id()) ::
          {:ok, Matter.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def archive(%Context{} = scope, matter_id) when is_binary(matter_id) do
    with {:ok, matter} <- get(scope, matter_id),
         :ok <- authorize_write(matter, scope) do
      matter
      |> Matter.changeset(%{"status" => "archived"})
      |> Repo.update()
    end
  end

  # ----------------------------------------------------------------------------
  # ACL helpers
  # ----------------------------------------------------------------------------

  @doc """
  Returns `:ok` if the scope can see this matter, `{:error, :forbidden}`
  otherwise. Exposed so other contexts (Documents, Conversion) can reuse
  the same gate against a pre-loaded Matter.
  """
  @spec authorize_read(Matter.t(), Context.t()) ::
          {:ok, Matter.t()} | {:error, :forbidden}
  def authorize_read(%Matter{tenant_id: nil} = matter, _scope), do: {:ok, matter}

  def authorize_read(%Matter{tenant_id: tid} = matter, %Context{} = scope) do
    case tenant_id_of(scope) do
      ^tid -> {:ok, matter}
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_write(%Matter{owner_id: owner_id} = _matter, %Context{user: %{id: id}})
       when owner_id == id,
       do: :ok

  defp authorize_write(_matter, _scope), do: {:error, :forbidden}

  # `Context.tenant` is opaque per the moduledoc — it may be a UUID
  # string (current persona seeding) or a struct with an `:id` key. Be
  # permissive on read.
  defp tenant_id_of(%Context{tenant: nil}), do: nil
  defp tenant_id_of(%Context{tenant: id}) when is_binary(id), do: id
  defp tenant_id_of(%Context{tenant: %{id: id}}) when is_binary(id), do: id
  defp tenant_id_of(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
