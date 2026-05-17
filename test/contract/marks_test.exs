defmodule Contract.MarksTest do
  use Contract.DataCase, async: true

  alias Contract.{Context, Documents, EvidenceSnapshot, Mark, Marks, Repo}

  describe "attach_evidence/3" do
    test "creates a durable Mark linking evidence to a document field" do
      owner = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Evidence target"})
      evidence = evidence_snapshot!(owner, document_id: doc.id)

      assert {:ok, %Mark{} = mark} =
               Marks.attach_evidence(owner, evidence.id, %{
                 document_id: doc.id,
                 field_path: ["payment", "late_fee"],
                 status: "attached"
               })

      assert mark.document_id == doc.id
      assert mark.evidence_snapshot_id == evidence.id
      assert mark.field_path == ["payment", "late_fee"]
      assert mark.change_id == nil
      assert mark.type == "evidence"
      assert mark.status == "attached"
    end

    test "creates a durable Mark linking evidence to a change" do
      owner = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Change target"})
      evidence = evidence_snapshot!(owner, document_id: doc.id)
      change_id = Ecto.UUID.generate()

      assert {:ok, mark} =
               Marks.attach_evidence(owner, evidence.id, %{
                 document_id: doc.id,
                 change_id: change_id
               })

      assert mark.change_id == change_id
      assert mark.field_path == []
    end

    test "foreign owner cannot read or attach another owner evidence" do
      owner = scope()
      foreign = scope()
      {:ok, owner_doc} = Documents.create(owner, %{title: "Owner doc"})
      {:ok, foreign_doc} = Documents.create(foreign, %{title: "Foreign doc"})
      evidence = evidence_snapshot!(owner, document_id: owner_doc.id)

      assert {:error, :forbidden} = Marks.get_evidence_snapshot(foreign, evidence.id)

      assert {:error, :forbidden} =
               Marks.attach_evidence(foreign, evidence.id, %{document_id: foreign_doc.id})

      assert Repo.aggregate(Mark, :count, :id) == 0
    end
  end

  defp evidence_snapshot!(%Context{user: %{id: owner_id}}, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    defaults = %{
      owner_id: owner_id,
      provider: "law_mcp.search_law",
      query: %{"query" => "민법"},
      result: %{"items" => [%{"law_id" => "001"}]},
      result_hash: "hash-#{System.unique_integer([:positive])}",
      captured_at: now
    }

    %EvidenceSnapshot{}
    |> EvidenceSnapshot.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp scope do
    id = Ecto.UUID.generate()
    %Context{user: %Contract.Accounts.User{id: id, email: "marks-#{id}@example.test"}}
  end
end
