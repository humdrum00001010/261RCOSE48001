defmodule Contract.Schemas.SourceClaimTest do
  use ExUnit.Case, async: true
  alias Contract.SourceClaim

  test "struct + valid changeset + required validation" do
    assert %SourceClaim{} = struct(SourceClaim, [])

    attrs = %{
      source_document_id: Ecto.UUID.generate(),
      region_id: "r1",
      proposed_kind: "party_a"
    }

    assert SourceClaim.changeset(%SourceClaim{}, attrs).valid?
    refute SourceClaim.changeset(%SourceClaim{}, %{}).valid?
  end

  test "changeset requires source_document_id, region_id, proposed_kind" do
    base = %{
      source_document_id: Ecto.UUID.generate(),
      region_id: "r1",
      proposed_kind: "party_a"
    }

    for missing <- [:source_document_id, :region_id, :proposed_kind] do
      cs = SourceClaim.changeset(%SourceClaim{}, Map.delete(base, missing))
      refute cs.valid?, "expected #{missing} to be required"
      assert %{} = errors = Ecto.Changeset.traverse_errors(cs, fn {m, _} -> m end)
      assert Map.has_key?(errors, missing)
    end
  end
end
