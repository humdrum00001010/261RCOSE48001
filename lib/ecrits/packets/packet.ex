defmodule Ecrits.Packets.Packet do
  @moduledoc """
  Packet container above documents.

  Documents remain the primary truth. A packet owns metadata and links to
  documents through `packet_documents`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ecrits.Packets.PacketDocument

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "contract_packets" do
    field :owner_id, :binary_id
    field :title, :string
    field :counterparty, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    has_many :packet_documents, PacketDocument, foreign_key: :packet_id
    has_many :documents, through: [:packet_documents, :document]

    timestamps(type: :utc_datetime)
  end

  @castable [:title, :counterparty, :status, :metadata]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(packet, attrs) do
    packet
    |> cast(attrs, @castable)
    |> validate_required([:owner_id, :title, :status])
    |> validate_length(:title, min: 1, max: 300)
    |> validate_length(:counterparty, max: 300)
    |> validate_length(:status, min: 1, max: 80)
  end
end
