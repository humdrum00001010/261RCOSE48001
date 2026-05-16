defmodule Contract.BlobRef do
  @moduledoc """
  Opaque handle to a stored blob (source upload, parser snapshot, export
  output, generated image, …).

  See SPEC.md v0.5 §19. `(bucket, object_key)` is the unique address; the
  row also carries content-addressing data (`sha256`, `size_bytes`,
  `mime_type`) and a `kind` discriminator used by `Contract.Blobs`.

  This module is the schema only. Upload, signing, and retrieval move
  through `Contract.Blobs` (Wave 8, replacing the old `Contract.IO`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "blob_refs" do
    field :owner_id, :binary_id

    field :bucket, :string
    field :object_key, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :sha256, :string

    field :kind, :string

    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @castable [
    :owner_id,
    :bucket,
    :object_key,
    :mime_type,
    :size_bytes,
    :sha256,
    :kind,
    :metadata
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(blob_ref, attrs) do
    blob_ref
    |> cast(attrs, @castable)
    |> validate_required([:owner_id, :bucket, :object_key, :kind])
  end
end
