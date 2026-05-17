defmodule Contract.CommandTest do
  use ExUnit.Case, async: true

  alias Contract.Command

  describe "changeset/2" do
    test "requires :kind" do
      cs = Command.changeset(%Command{}, %{})
      refute cs.valid?
      assert {:kind, _} = List.keyfind(cs.errors, :kind, 0)
    end

    test "defaults actor_type to :user when missing" do
      cs = Command.changeset(%Command{}, %{kind: :create_document})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :actor_type) == :user
    end

    test "respects an explicit actor_type" do
      cs = Command.changeset(%Command{}, %{kind: :create_document, actor_type: :agent})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :actor_type) == :agent
    end

    test "idempotency_key must be 6..128 chars" do
      short =
        Command.changeset(%Command{}, %{kind: :create_document, idempotency_key: "abc"})

      long =
        Command.changeset(%Command{}, %{
          kind: :create_document,
          idempotency_key: String.duplicate("x", 129)
        })

      ok =
        Command.changeset(%Command{}, %{kind: :create_document, idempotency_key: "abc-123-xyz"})

      refute short.valid?
      assert List.keyfind(short.errors, :idempotency_key, 0)
      refute long.valid?
      assert ok.valid?
    end

    test "every document-scoped kind requires :document_id and accepts it when supplied" do
      doc_id = "11111111-1111-1111-1111-111111111111"

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
        missing = Command.changeset(%Command{}, %{kind: kind})
        refute missing.valid?, "expected #{kind} to require :document_id"
        assert List.keyfind(missing.errors, :document_id, 0)

        present = Command.changeset(%Command{}, %{kind: kind, document_id: doc_id})
        assert present.valid?, "expected #{kind} to be valid with :document_id"
      end
    end

    test "kinds that aren't document-scoped do not require :document_id" do
      cs = Command.changeset(%Command{}, %{kind: :chat_message})
      assert cs.valid?
    end
  end

  describe "document_scoped_kinds/0" do
    test "returns the documented list" do
      kinds = Command.document_scoped_kinds()
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

  describe "source-claim kinds (SPEC v0.5 §7.5)" do
    @source_claim_id "33333333-3333-3333-3333-333333333333"
    @document_id "11111111-1111-1111-1111-111111111111"

    for kind <- [
          :source_claim_confirm,
          :source_claim_correct,
          :source_claim_reject,
          :source_claim_link_to_document,
          :source_claim_unlink_from_document
        ] do
      test "#{kind} accepts a Command with example args" do
        attrs = source_claim_attrs(unquote(kind))
        cs = Command.changeset(%Command{}, attrs)
        assert cs.valid?, "expected valid, got errors: #{inspect(cs.errors)}"
        assert Ecto.Changeset.get_field(cs, :kind) == unquote(kind)
        assert Ecto.Changeset.get_field(cs, :source_claim_id) == @source_claim_id
      end

      test "#{kind} fails when :source_claim_id is missing" do
        attrs =
          unquote(kind)
          |> source_claim_attrs()
          |> Map.delete(:source_claim_id)

        cs = Command.changeset(%Command{}, attrs)
        refute cs.valid?
        assert List.keyfind(cs.errors, :source_claim_id, 0)
      end
    end

    test "source_claim_scoped_kinds/0 reports the new kinds" do
      kinds = Command.source_claim_scoped_kinds()
      assert :source_claim_confirm in kinds
      assert :source_claim_correct in kinds
      assert :source_claim_reject in kinds
      assert :source_claim_link_to_document in kinds
      assert :source_claim_unlink_from_document in kinds
    end

    defp source_claim_attrs(:source_claim_confirm) do
      %{
        kind: :source_claim_confirm,
        source_claim_id: @source_claim_id,
        actor_type: :user,
        payload: %{}
      }
    end

    defp source_claim_attrs(:source_claim_correct) do
      %{
        kind: :source_claim_correct,
        source_claim_id: @source_claim_id,
        actor_type: :user,
        payload: %{"corrected_value" => "new value"}
      }
    end

    defp source_claim_attrs(:source_claim_reject) do
      %{
        kind: :source_claim_reject,
        source_claim_id: @source_claim_id,
        actor_type: :user,
        payload: %{"reason" => "not applicable"}
      }
    end

    defp source_claim_attrs(:source_claim_link_to_document) do
      %{
        kind: :source_claim_link_to_document,
        source_claim_id: @source_claim_id,
        document_id: @document_id,
        actor_type: :user,
        payload: %{}
      }
    end

    defp source_claim_attrs(:source_claim_unlink_from_document) do
      %{
        kind: :source_claim_unlink_from_document,
        source_claim_id: @source_claim_id,
        document_id: @document_id,
        actor_type: :user,
        payload: %{}
      }
    end
  end
end
