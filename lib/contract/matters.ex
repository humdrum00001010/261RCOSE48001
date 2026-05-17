defmodule Contract.Matters do
  @moduledoc """
  Legacy compatibility helpers for the pre-v0.5 `matters` table.

  Matter is no longer a product/domain object and must not be used as an
  authorization boundary for Contract Studio. New document-facing code should
  use `Contract.Documents` with owner-scoped `Document` rows. This module is
  kept only so old seed/test data and migration-era cleanup code can still read
  or write the legacy table while those callers are retired.
  """
  import Ecto.Query

  alias Contract.Context
  alias Contract.Matters.Matter
  alias Contract.Repo
  alias Contract.Types, as: T

  @doc """
  Return legacy matter rows for migration-era callers.

  This is not a product document picker and must not be used as an
  authorization source for document access. New code should query
  `Contract.Documents`.
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

  @doc """
  Fetch one legacy matter row.

  The tenant check exists only to avoid leaking old rows while compatibility
  callers are retired. It is not document ACL.
  """
  @spec get(Context.t(), T.id()) ::
          {:ok, Matter.t()} | {:error, :not_found | :forbidden}
  def get(%Context{} = scope, matter_id) when is_binary(matter_id) do
    case Repo.get(Matter, matter_id) do
      nil -> {:error, :not_found}
      %Matter{} = matter -> legacy_visible?(matter, scope)
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get(_scope, _id), do: {:error, :not_found}

  @doc """
  Insert a legacy matter row for seed/test and migration compatibility.

  New document creation must use `Contract.Documents.create/2`.
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

  @doc """
  Mark a legacy matter row as archived.
  """
  @spec archive(Context.t(), T.id()) ::
          {:ok, Matter.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def archive(%Context{} = scope, matter_id) when is_binary(matter_id) do
    with {:ok, matter} <- get(scope, matter_id),
         :ok <- legacy_owner?(matter, scope) do
      matter
      |> Matter.changeset(%{"status" => "archived"})
      |> Repo.update()
    end
  end

  @spec legacy_visible?(Matter.t(), Context.t()) ::
          {:ok, Matter.t()} | {:error, :forbidden}
  defp legacy_visible?(%Matter{tenant_id: nil} = matter, _scope), do: {:ok, matter}

  defp legacy_visible?(%Matter{tenant_id: tid} = matter, %Context{} = scope) do
    case tenant_id_of(scope) do
      ^tid -> {:ok, matter}
      _ -> {:error, :forbidden}
    end
  end

  defp legacy_owner?(%Matter{owner_id: owner_id} = _matter, %Context{user: %{id: id}})
       when owner_id == id,
       do: :ok

  defp legacy_owner?(_matter, _scope), do: {:error, :forbidden}

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
