defmodule Contract.ToolCall do
  @moduledoc """
  One persisted tool invocation within an AgentRun.

  See SPEC.md v0.5 §7.9. Used for audit, replay, UI display, and legal
  evidence traceability.

  This module is the schema only. The wiring through Contract.Agent and
  the streaming UI lives in later waves.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tool_calls" do
    field :agent_run_id, :binary_id

    field :name, :string
    field :arguments, :map, default: %{}
    field :result, :map, default: %{}

    field :status, :string, default: "pending"

    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @castable [
    :agent_run_id,
    :name,
    :arguments,
    :result,
    :status,
    :started_at,
    :completed_at
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, @castable)
    |> validate_required([:agent_run_id, :name])
  end
end
