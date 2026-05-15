defmodule Contract.Change do
  @moduledoc """
  Durable, reversible result of an Action. See SPEC.md §6.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "changes" do
    field :matter_id, :binary_id
    field :document_id, :binary_id
    field :artifact_id, :binary_id

    field :action_kind, :string

    field :actor_type, Ecto.Enum, values: [:user, :agent, :lawyer, :slack, :system]
    field :actor_id, :binary_id

    field :base_revision, :integer
    field :applied_revision, :integer
    field :idempotency_key, :string

    field :ops, {:array, :map}, default: []
    field :marks, {:array, :map}, default: []
    field :message, :string

    field :affected_refs, {:array, :map}, default: []
    field :preimage, :map
    field :inverse_ops, {:array, :map}, default: []

    field :status, Ecto.Enum,
      values: [:active, :revoked, :partially_revoked, :superseded],
      default: :active

    timestamps()
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :matter_id,
      :document_id,
      :artifact_id,
      :action_kind,
      :actor_type,
      :actor_id,
      :base_revision,
      :applied_revision,
      :idempotency_key,
      :ops,
      :marks,
      :message,
      :affected_refs,
      :preimage,
      :inverse_ops,
      :status
    ])
    |> validate_required([
      :document_id,
      :action_kind,
      :actor_type,
      :applied_revision
    ])
  end
end
