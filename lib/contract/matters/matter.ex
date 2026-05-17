defmodule Contract.Matters.Matter do
  @moduledoc """
  Legacy Ecto schema for the pre-v0.5 `matters` table.

  This schema is migration compatibility only. Matter is no longer the
  user-facing product container and no longer owns document ACL; document
  access is enforced by `Contract.Documents` through `documents.owner_id`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "matters" do
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :tenant_id, :binary_id
    field :owner_id, :binary_id
    field :metadata, :map, default: %{}
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Build a changeset for inserting or updating a Matter.

  `:name` and `:owner_id` are required on insert. `:status`,
  `:tenant_id`, and `:metadata` are optional.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(matter, attrs) do
    matter
    |> cast(attrs, [:name, :status, :tenant_id, :owner_id, :metadata])
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, min: 1, max: 200)
  end
end
