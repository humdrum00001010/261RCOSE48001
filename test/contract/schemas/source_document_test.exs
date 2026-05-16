defmodule Contract.Schemas.SourceDocumentTest do
  use ExUnit.Case, async: true
  alias Contract.SourceDocument

  test "struct + valid changeset + required validation" do
    assert %SourceDocument{} = struct(SourceDocument, [])

    attrs = %{owner_id: Ecto.UUID.generate(), blob_ref_id: Ecto.UUID.generate()}
    assert SourceDocument.changeset(%SourceDocument{}, attrs).valid?
    refute SourceDocument.changeset(%SourceDocument{}, %{}).valid?
  end

  test "status defaults to \"uploaded\" and accepts the SPEC §7.3 lifecycle strings" do
    # The W1 schema stores status as a string (no Ecto.Enum here yet —
    # later waves can tighten if needed). This test pins the current
    # contract: the default is `"uploaded"` and any SPEC §7.3 status
    # string is accepted.
    base = %{owner_id: Ecto.UUID.generate(), blob_ref_id: Ecto.UUID.generate()}

    cs = SourceDocument.changeset(%SourceDocument{}, base)
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :status) == "uploaded"

    for status <- ~w(uploaded parsing parsed interpreting ready failed) do
      cs2 = SourceDocument.changeset(%SourceDocument{}, Map.put(base, :status, status))
      assert cs2.valid?
      assert Ecto.Changeset.get_field(cs2, :status) == status
    end
  end
end
