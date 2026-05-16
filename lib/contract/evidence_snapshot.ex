defmodule Contract.EvidenceSnapshot do
  @moduledoc """
  Immutable record of a single provider call (law-MCP statute lookup,
  case search, ...) captured for legal traceability.

  See SPEC.md v0.5 §7.8. The row is append-only: no `updated_at`, and
  `(result_hash, owner_id)` is unique so duplicate captures collapse.

  This module is the schema only. The capture pathway lives in
  `Contract.Providers` (Wave 5).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # No updated_at: EvidenceSnapshots are immutable after creation.
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  schema "evidence_snapshots" do
    field :owner_id, :binary_id

    field :chat_thread_id, :binary_id
    field :document_id, :binary_id
    field :source_document_id, :binary_id

    field :provider, :string
    field :query, :map, default: %{}
    field :result, :map, default: %{}
    field :result_hash, :string

    field :captured_at, :utc_datetime

    timestamps()
  end

  @castable [
    :owner_id,
    :chat_thread_id,
    :document_id,
    :source_document_id,
    :provider,
    :query,
    :result,
    :result_hash,
    :captured_at
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @castable)
    |> validate_required([:owner_id, :provider, :result_hash, :captured_at])
  end
end
