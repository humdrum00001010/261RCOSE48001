defmodule Contract.Operation do
  @moduledoc """
  Mechanical operation. The hard half of `Action` → `Change`. See SPEC.md §7.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key false

  embedded_schema do
    field :op, Ecto.Enum,
      values: [
        :create_node,
        :delete_node,
        :move_node,
        :replace_content,
        :set_field,
        :set_attr,
        :bind_ref,
        :unbind_ref,
        :create_projection,
        :add_mark,
        :update_mark
      ]

    field :target_type, Ecto.Enum,
      values: [:artifact, :document, :node, :field, :mark, :projection]

    field :target_id, :binary_id
    field :args, :map, default: %{}
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:op, :target_type, :target_id, :args])
    |> validate_required([:op, :target_type])
  end
end
