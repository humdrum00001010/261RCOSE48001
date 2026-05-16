defmodule Contract.SourceDocument do
  @moduledoc """
  A SourceDocument is an uploaded or imported document-shaped source —
  PDF contract, HWP/HWPX, DOCX, scanned contract, government form,
  prior draft, counterparty draft.

  See SPEC.md v0.5 §7.3.

  A SourceDocument is source evidence; it is NOT the working contract
  unless it has been explicitly converted/imported into a Document.

  This module is the schema only. Parsing, interpretation, and linking
  flows live in later waves.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "source_documents" do
    field :owner_id, :binary_id
    field :chat_thread_id, :binary_id
    field :document_id, :binary_id

    field :blob_ref_id, :binary_id
    field :mime_type, :string
    field :original_filename, :string
    field :parser_snapshot_ref, :string

    field :regions, {:array, :map}, default: []

    field :status, :string, default: "uploaded"

    timestamps(type: :utc_datetime)
  end

  @castable [
    :owner_id,
    :chat_thread_id,
    :document_id,
    :blob_ref_id,
    :mime_type,
    :original_filename,
    :parser_snapshot_ref,
    :regions,
    :status
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(source_document, attrs) do
    source_document
    |> cast(attrs, @castable)
    |> validate_required([:owner_id, :blob_ref_id])
  end
end
