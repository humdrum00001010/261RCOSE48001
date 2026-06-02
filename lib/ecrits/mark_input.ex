defmodule Ecrits.MarkInput do
  @moduledoc """
  Soft-meaning attachment requested by an actor. See SPEC.md §7.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ecrits.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key false

  embedded_schema do
    field :target_type, Ecto.Enum,
      values: [:artifact, :document, :node, :field, :change, :op, :evidence, :projection]

    field :target_id, :binary_id

    field :intent, Ecto.Enum,
      values: [:ask, :explain, :flag, :label, :link, :source_claim, :source_claim_rejected]

    field :text, :string
    field :confidence, Ecto.Enum, values: [:low, :medium, :high, :confirmed]
    field :source, Ecto.Enum, values: [:user, :agent, :lawyer, :slack, :law_mcp, :system]
    field :data, :map, default: %{}
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(mark, attrs) do
    mark
    |> cast(attrs, [:target_type, :target_id, :intent, :text, :confidence, :source, :data])
    |> validate_required([:intent, :source])
  end
end
