defmodule Ecrits.ChatThread do
  @moduledoc """
  A ChatThread is the conversation log between a user and the agent.

  See SPEC.md v0.5 §7.2.

  A thread may exist before any Document — chat is the entrypoint to the
  product. If a thread later produces structured context, that context
  becomes a Mark, Command, SourceClaim, or Change.

  This module is the schema only — no business rules. Context functions
  (create, attach, archive) land in later waves.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_threads" do
    field :owner_id, :binary_id
    field :document_id, :binary_id

    field :title, :string
    field :messages, {:array, :map}, default: []
    field :last_message_at, :utc_datetime

    field :status, :string, default: "active"

    timestamps(type: :utc_datetime)
  end

  @castable [
    :owner_id,
    :document_id,
    :title,
    :messages,
    :last_message_at,
    :status
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, @castable)
    |> validate_required([:owner_id])
  end
end
