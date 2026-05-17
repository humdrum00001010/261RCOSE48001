defmodule Contract.ChangeTest do
  use Contract.DataCase, async: true

  alias Contract.{Change, Context}

  describe "Matter cleanup" do
    test "Context drops :matter; Types drops legacy matter_id/artifact_id aliases" do
      refute :matter in Map.keys(%Context{})

      source = File.read!("lib/contract/types.ex")
      refute source =~ "@type matter_id"
      refute source =~ "@type artifact_id"
    end
  end

  describe "v0.5 runtime shape" do
    test "exposes document/chat/source command fields and no legacy Action or Matter fields" do
      fields = Map.keys(%Change{})

      refute :matter_id in fields
      refute :artifact_id in fields
      refute :action_kind in fields

      assert :document_id in fields
      assert :chat_thread_id in fields
      assert :source_document_id in fields
      assert :source_claim_id in fields
      assert :agent_run_id in fields
      assert :command_kind in fields
      assert :field_path in fields
      assert :op in fields
      assert :payload in fields
      assert :inverse in fields
      assert :base_revision in fields
      assert :result_revision in fields
    end

    test "changeset accepts the v0.5 durable Change fields" do
      attrs = %{
        document_id: Ecto.UUID.generate(),
        chat_thread_id: Ecto.UUID.generate(),
        source_document_id: Ecto.UUID.generate(),
        source_claim_id: Ecto.UUID.generate(),
        agent_run_id: Ecto.UUID.generate(),
        command_kind: "rename_document",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 0,
        result_revision: 1,
        idempotency_key: "change-v05-shape",
        field_path: ["document", "title"],
        op: "set_attr",
        payload: [%{"op" => "set_attr", "target_type" => "document"}],
        inverse: [%{"op" => "set_attr", "target_type" => "document"}],
        marks: [],
        affected_refs: [],
        preimage: %{},
        status: :active
      }

      changeset = Change.changeset(%Change{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :command_kind) == "rename_document"
      assert Ecto.Changeset.get_field(changeset, :result_revision) == 1
    end

    test "active?/1 and touches?/2 describe committed Change state" do
      ref = %{ref_id: "ref-1", target_id: "node-1"}
      change = %Change{status: :active, affected_refs: [ref]}

      assert Change.active?(change)
      assert Change.touches?(change, ref)
      assert Change.touches?(change, %{ref_id: "ref-1"})
      refute Change.touches?(change, %{ref_id: "ref-2"})
      refute Change.active?(%Change{status: :revoked})
    end
  end
end
