defmodule Ecrits.Schemas.ChatThreadTest do
  use ExUnit.Case, async: true
  alias Ecrits.ChatThread

  test "struct + valid changeset + required validation" do
    assert %ChatThread{} = struct(ChatThread, [])
    assert ChatThread.changeset(%ChatThread{}, %{owner_id: Ecto.UUID.generate()}).valid?
    refute ChatThread.changeset(%ChatThread{}, %{}).valid?
  end

  test "document_id is allowed to be nil — a thread may exist before any Document" do
    # SPEC.md v0.5 §7.2: a ChatThread may exist before a Document.
    cs = ChatThread.changeset(%ChatThread{}, %{owner_id: Ecto.UUID.generate(), document_id: nil})

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :document_id) == nil
  end
end
