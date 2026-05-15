defmodule Contract.Snapshot do
  @moduledoc """
  Persisted projection row written by `Contract.Store.snapshot/2`. The
  `projection` JSONB column holds the full materialized state at a given
  revision, and `r2_key` points at the durable copy in R2.

  Snapshots accelerate `Contract.Store.load/1` — instead of folding the
  entire change history, the Store fetches the latest snapshot and replays
  only changes whose `applied_revision > snapshot.revision`.

  See SPEC.md §16.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id

  schema "snapshots" do
    field :document_id, :binary_id, primary_key: true
    field :revision, :integer, primary_key: true
    field :projection, :map
    field :r2_key, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(snap, attrs) do
    snap
    |> cast(attrs, [:document_id, :revision, :projection, :r2_key])
    |> validate_required([:document_id, :revision, :projection, :r2_key])
  end
end
