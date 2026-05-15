defmodule Contract.Studio.State do
  @moduledoc """
  Per-LiveView session state. NOT durable. See SPEC.md §9.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key false

  embedded_schema do
    field :matter_id, :binary_id
    field :selected_document_id, :binary_id
    field :selected_node_id, :binary_id

    field :last_seen_revision, :integer

    field :chat_open?, :boolean, default: true
    field :document_picker_open?, :boolean, default: false
    field :metadata_panel_open?, :boolean, default: false
    field :migration_panel_open?, :boolean, default: false
    field :upload_panel_open?, :boolean, default: false

    field :agent_run_id, :binary_id

    field :mode, Ecto.Enum, values: [:no_document, :briefing, :editing, :reviewing]
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :matter_id,
      :selected_document_id,
      :selected_node_id,
      :last_seen_revision,
      :chat_open?,
      :document_picker_open?,
      :metadata_panel_open?,
      :migration_panel_open?,
      :upload_panel_open?,
      :agent_run_id,
      :mode
    ])
  end
end
