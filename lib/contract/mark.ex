defmodule Contract.Mark do
  @moduledoc """
  Durable attachment from a document, field, or change to legal evidence.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "marks" do
    field :document_id, :binary_id
    field :evidence_snapshot_id, :binary_id
    field :field_path, {:array, :string}, default: []
    field :change_id, :binary_id
    field :type, :string, default: "evidence"
    field :status, :string, default: "attached"
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(mark, attrs) do
    mark
    |> cast(attrs, [
      :document_id,
      :evidence_snapshot_id,
      :field_path,
      :change_id,
      :type,
      :status,
      :metadata
    ])
    |> validate_required([:document_id, :evidence_snapshot_id, :type, :status])
  end
end
