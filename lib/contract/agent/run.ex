defmodule Contract.Agent.Run do
  @moduledoc """
  Durable record for one agent run. A run is created when a
  `:chat_message` or `:start_type_conversion` Action triggers the agent
  and lives until the agent emits a final `:agent_change` Action or is
  cancelled.

  See SPEC.md §20, §24.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_runs" do
    field :document_id, :binary_id
    field :triggered_by_action_id, :binary_id

    field :status, Ecto.Enum,
      values: [:running, :completed, :failed, :cancelled],
      default: :running

    field :turn_index, :integer, default: 0
    field :previous_response_id, :string
    field :message, :string

    timestamps()
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :document_id,
      :triggered_by_action_id,
      :status,
      :turn_index,
      :previous_response_id,
      :message
    ])
    |> validate_required([:status])
  end
end
