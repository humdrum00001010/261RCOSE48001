defmodule Contract.Schemas.EvidenceSnapshotTest do
  use Contract.DataCase, async: true
  alias Contract.{EvidenceSnapshot, Repo}

  test "struct + valid changeset + required validation" do
    assert %EvidenceSnapshot{} = struct(EvidenceSnapshot, [])

    attrs = %{
      owner_id: Ecto.UUID.generate(),
      provider: "law_mcp",
      result_hash: "abc123",
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    assert EvidenceSnapshot.changeset(%EvidenceSnapshot{}, attrs).valid?
    refute EvidenceSnapshot.changeset(%EvidenceSnapshot{}, %{}).valid?
  end

  test "schema has no updated_at — the row is append-only after insert" do
    # SPEC.md v0.5 §7.8: EvidenceSnapshots are immutable after creation.
    # The schema enforces this by setting `updated_at: false` on
    # `@timestamps_opts`, and the migration intentionally adds only
    # `inserted_at` to the table. Pin both invariants.
    refute :updated_at in EvidenceSnapshot.__schema__(:fields)
    assert :inserted_at in EvidenceSnapshot.__schema__(:fields)
  end

  test "subsequent changesets on a persisted row do not produce an :updated_at change" do
    # Insert a row, then try to "update" it via changeset. The result is
    # still a valid changeset (Ecto won't bounce it), but because the
    # schema declares `updated_at: false`, no `:updated_at` change is
    # produced and re-fetching the row shows the original `inserted_at`.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, row} =
      %EvidenceSnapshot{}
      |> EvidenceSnapshot.changeset(%{
        owner_id: Ecto.UUID.generate(),
        provider: "law_mcp",
        result_hash: "hash-#{System.unique_integer([:positive])}",
        captured_at: now
      })
      |> Repo.insert()

    update_cs =
      row
      |> EvidenceSnapshot.changeset(%{provider: "openai", result: %{"x" => 1}})

    refute Map.has_key?(update_cs.changes, :updated_at)

    {:ok, updated} = Repo.update(update_cs)
    reloaded = Repo.get!(EvidenceSnapshot, row.id)

    # `inserted_at` is preserved across the update — the row is
    # append-only in spirit, and Ecto cannot stamp an `updated_at`.
    assert reloaded.inserted_at == row.inserted_at
    assert updated.id == row.id
  end
end
