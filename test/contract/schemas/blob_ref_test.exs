defmodule Contract.Schemas.BlobRefTest do
  use ExUnit.Case, async: true
  alias Contract.BlobRef

  test "struct + valid changeset + required validation" do
    assert %BlobRef{} = struct(BlobRef, [])

    attrs = %{
      owner_id: Ecto.UUID.generate(),
      bucket: "uploads",
      object_key: "abc/123.pdf",
      kind: "source_upload"
    }

    assert BlobRef.changeset(%BlobRef{}, attrs).valid?
    refute BlobRef.changeset(%BlobRef{}, %{}).valid?
  end
end
