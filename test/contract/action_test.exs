defmodule Contract.ActionTest do
  use ExUnit.Case, async: true

  alias Contract.Action

  describe "changeset/2" do
    test "requires :kind" do
      cs = Action.changeset(%Action{}, %{})
      refute cs.valid?
      assert {:kind, _} = List.keyfind(cs.errors, :kind, 0)
    end

    test "defaults actor_type to :user when missing" do
      cs = Action.changeset(%Action{}, %{kind: :create_document})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :actor_type) == :user
    end

    test "respects an explicit actor_type" do
      cs = Action.changeset(%Action{}, %{kind: :create_document, actor_type: :agent})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :actor_type) == :agent
    end

    test "rejects idempotency_key shorter than 6 chars" do
      cs =
        Action.changeset(%Action{}, %{
          kind: :create_document,
          idempotency_key: "abc"
        })

      refute cs.valid?
      assert List.keyfind(cs.errors, :idempotency_key, 0)
    end

    test "rejects idempotency_key longer than 128 chars" do
      cs =
        Action.changeset(%Action{}, %{
          kind: :create_document,
          idempotency_key: String.duplicate("x", 129)
        })

      refute cs.valid?
    end

    test "accepts a well-formed idempotency_key" do
      cs =
        Action.changeset(%Action{}, %{
          kind: :create_document,
          idempotency_key: "abc-123-xyz"
        })

      assert cs.valid?
    end

    for kind <- [
          :edit_document,
          :rename_document,
          :update_metadata,
          :set_contract_type,
          :add_mark,
          :update_mark,
          :revoke_change,
          :resolve_revoke,
          :request_export
        ] do
      test "#{kind} requires :document_id" do
        cs = Action.changeset(%Action{}, %{kind: unquote(kind)})
        refute cs.valid?
        assert List.keyfind(cs.errors, :document_id, 0)
      end

      test "#{kind} passes when :document_id is supplied" do
        cs =
          Action.changeset(%Action{}, %{
            kind: unquote(kind),
            document_id: "11111111-1111-1111-1111-111111111111"
          })

        assert cs.valid?
      end
    end

    test "kinds that aren't document-scoped do not require :document_id" do
      cs = Action.changeset(%Action{}, %{kind: :chat_message})
      assert cs.valid?
    end
  end

  describe "document_scoped_kinds/0" do
    test "returns the documented list" do
      kinds = Action.document_scoped_kinds()
      assert :edit_document in kinds
      assert :rename_document in kinds
      assert :update_metadata in kinds
      assert :set_contract_type in kinds
      assert :add_mark in kinds
      assert :update_mark in kinds
      assert :revoke_change in kinds
      assert :resolve_revoke in kinds
      assert :request_export in kinds
      refute :create_document in kinds
      refute :chat_message in kinds
    end
  end
end
