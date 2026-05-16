defmodule Contract.SourceClaim do
  @moduledoc """
  A SourceClaim is the agent's supervised interpretation of a region of
  a SourceDocument: "this appears to be Party A", "this blank likely
  maps to contract_amount". The user can confirm, correct, reject, or
  link the claim to a working Document.

  See SPEC.md v0.5 §7.4.

  This module is the schema only — no business rules. Wave 3 (claims
  pipeline) will populate it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "source_claims" do
    field :source_document_id, :binary_id

    field :region_id, :string
    field :proposed_kind, :string
    field :proposed_value, :string
    field :proposed_structured, :map, default: %{}

    field :status, :string, default: "proposed"

    field :user_value, :string
    field :user_structured, :map, default: %{}

    field :linked_document_id, :binary_id
    field :linked_node_id, :string

    field :agent_run_id, :binary_id
    field :confidence, :decimal
    field :rationale, :string

    timestamps(type: :utc_datetime)
  end

  @castable [
    :source_document_id,
    :region_id,
    :proposed_kind,
    :proposed_value,
    :proposed_structured,
    :status,
    :user_value,
    :user_structured,
    :linked_document_id,
    :linked_node_id,
    :agent_run_id,
    :confidence,
    :rationale
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, @castable)
    |> validate_required([:source_document_id, :region_id, :proposed_kind])
  end
end
