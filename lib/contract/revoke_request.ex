defmodule Contract.RevokeRequest do
  @moduledoc """
  A revoke request that needs user reconciliation. Created by
  `Contract.Session.revoke/2` when the target change has later overlapping
  changes — the user must choose how to merge.

  See SPEC.md §17.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "revoke_requests" do
    field :document_id, :binary_id
    field :target_change_id, :binary_id
    field :overlap_changes, {:array, :binary_id}, default: []

    field :status, Ecto.Enum,
      values: [:pending, :resolved, :abandoned],
      default: :pending

    field :resolution_change_id, :binary_id
    field :requester_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(req, attrs) do
    req
    |> cast(attrs, [
      :document_id,
      :target_change_id,
      :overlap_changes,
      :status,
      :resolution_change_id,
      :requester_id
    ])
    |> validate_required([:document_id, :target_change_id, :status])
  end
end
