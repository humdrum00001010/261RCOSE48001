defmodule Ecrits.Packets.PacketDocument do
  @moduledoc """
  Join row linking a packet to a document.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ecrits.Documents.Document
  alias Ecrits.Packets.Packet

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "packet_documents" do
    belongs_to :packet, Packet
    belongs_to :document, Document

    field :role, :string, default: "primary"
    field :status, :string, default: "active"
    field :required, :boolean, default: true
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @castable [:role, :status, :required, :metadata]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(packet_document, attrs) do
    packet_document
    |> cast(attrs, @castable)
    |> validate_required([:packet_id, :document_id, :role, :status, :required])
    |> validate_length(:role, min: 1, max: 80)
    |> validate_length(:status, min: 1, max: 80)
    |> foreign_key_constraint(:packet_id)
    |> foreign_key_constraint(:document_id)
    |> unique_constraint([:packet_id, :document_id],
      name: :packet_documents_packet_id_document_id_index
    )
  end
end
