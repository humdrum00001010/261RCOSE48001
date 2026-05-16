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

    # SPEC.md v0.5 §7.9 — extended status set. Legacy values (:running,
    # :completed, :failed, :cancelled) remain; :pending and :streaming
    # are new. The string column allows downstream waves to migrate to
    # the v0.5 names without an enum rewrite.
    field :status, Ecto.Enum,
      values: [:pending, :running, :streaming, :completed, :failed, :cancelled],
      default: :running

    field :turn_index, :integer, default: 0
    field :previous_response_id, :string
    field :message, :string

    # SPEC.md v0.5 §7.9 — owner, thread, lifecycle, error map, model and
    # the set of tools the run was permitted to call.
    field :owner_id, :binary_id
    field :chat_thread_id, :binary_id
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :error, :map
    field :model, :string
    field :tools_enabled, {:array, :string}, default: []

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
      :message,
      :owner_id,
      :chat_thread_id,
      :started_at,
      :completed_at,
      :error,
      :model,
      :tools_enabled
    ])
    |> validate_required([:status])
  end
end
