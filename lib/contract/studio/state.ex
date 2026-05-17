defmodule Contract.Studio.State do
  @moduledoc """
  Per-LiveView session state. NOT durable. See SPEC.md §9.

  v0.5: `:matter_id` and `:context_reservoir` are gone. The Matter
  container was removed from the product model; Document is the only
  scope. The Context Reservoir is no longer in v0.5 — the left rail is
  optional outline / related-docs in a later wave.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key false

  embedded_schema do
    field :selected_document_id, :binary_id
    field :selected_node_id, :binary_id

    field :last_seen_revision, :integer

    field :chat_open?, :boolean, default: true
    field :document_picker_open?, :boolean, default: false
    field :metadata_panel_open?, :boolean, default: false
    field :migration_panel_open?, :boolean, default: false
    field :upload_panel_open?, :boolean, default: false
    field :type_picker_open?, :boolean, default: false
    field :export_picker_open?, :boolean, default: false

    # When the user picks "다른 문서에서 변형 만들기" from the no-document
    # agent prompt (SPEC.md §10), we open the document_picker modal and
    # set this flag so the modal knows the next pick should kick off a
    # type-conversion flow rather than just open the document.
    field :variant_source_picker?, :boolean, default: false

    field :agent_run_id, :binary_id

    field :mode, Ecto.Enum, values: [:no_document, :briefing, :editing, :reviewing]
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :selected_document_id,
      :selected_node_id,
      :last_seen_revision,
      :chat_open?,
      :document_picker_open?,
      :metadata_panel_open?,
      :migration_panel_open?,
      :upload_panel_open?,
      :type_picker_open?,
      :export_picker_open?,
      :variant_source_picker?,
      :agent_run_id,
      :mode
    ])
  end
end
