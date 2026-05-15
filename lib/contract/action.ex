defmodule Contract.Action do
  @moduledoc """
  The one intent shape. Users, agents, Slack, MCP, import jobs, export jobs,
  and system jobs all normalize into `Contract.Action`. See SPEC.md §5.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key false

  embedded_schema do
    field :kind, Ecto.Enum,
      values: [
        :open_document,
        :create_document,
        :upload_document,
        :duplicate_document,
        :archive_document,
        :restore_document,
        :rename_document,
        :update_metadata,
        :set_contract_type,
        :edit_document,
        :add_mark,
        :update_mark,
        :start_type_conversion,
        :set_field_migration_strategy,
        :create_converted_variant,
        :chat_message,
        :agent_change,
        :revoke_change,
        :resolve_revoke,
        :request_export
      ]

    field :matter_id, :binary_id
    field :document_id, :binary_id
    field :change_id, :binary_id
    field :agent_run_id, :binary_id

    field :actor_type, Ecto.Enum, values: [:user, :agent, :lawyer, :slack, :system]
    field :actor_id, :binary_id

    field :base_revision, :integer
    field :idempotency_key, :string

    field :payload, :map, default: %{}
    field :message, :string
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :kind,
      :matter_id,
      :document_id,
      :change_id,
      :agent_run_id,
      :actor_type,
      :actor_id,
      :base_revision,
      :idempotency_key,
      :payload,
      :message
    ])
    |> validate_required([:kind, :actor_type])
  end
end
