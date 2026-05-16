defmodule Contract.Studio.ContextReservoirTest do
  use ExUnit.Case, async: true

  alias Contract.Studio.ContextReservoir

  describe "default struct" do
    test "all fields default to empty containers" do
      reservoir = %ContextReservoir{}

      assert reservoir.brief == %{}
      assert reservoir.shared_fields == []
      assert reservoir.open_questions == []
      assert reservoir.related_documents == []
      assert reservoir.sources == []
      assert reservoir.evidence == []
      assert reservoir.recent_changes == []
      assert reservoir.recent_revokes == []
      assert reservoir.readiness == %{}
    end
  end

  describe "changeset/2" do
    test "accepts empty attrs and applies all defaults" do
      changeset = ContextReservoir.changeset(%ContextReservoir{}, %{})
      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset) == %ContextReservoir{}
    end

    test "accepts a full reservoir map and preserves each section" do
      attrs = %{
        brief: %{
          purpose: "Negotiate NDA",
          status: :active,
          user_role: "discloser",
          counterparty_role: "recipient",
          title: "Mutual NDA",
          type_key: "nda"
        },
        shared_fields: [
          %{field_id: "party_a", label: "Party A", value: "Acme", attrs: %{}},
          %{field_id: "party_b", label: "Party B", value: "Initech", attrs: %{}}
        ],
        open_questions: [
          %{
            question_id: "m1",
            text: "Mutual or one-way?",
            asked_by: :agent,
            answered_at: nil
          }
        ],
        related_documents: [
          %{
            document_id: "00000000-0000-0000-0000-000000000001",
            label_ko: "현재 문서",
            label_en: "Current draft",
            role: :current_draft
          }
        ],
        sources: [
          %{
            artifact_id: "00000000-0000-0000-0000-000000000002",
            kind: :upload,
            created_at: ~U[2026-01-01 00:00:00Z],
            label: "Original upload"
          }
        ],
        evidence: [
          %{
            evidence_id: "ev1",
            source: :law_mcp,
            summary: "Korea law citation"
          }
        ],
        recent_changes: [
          %{
            change_id: "00000000-0000-0000-0000-000000000003",
            action_kind: "rename_document",
            applied_at: ~N[2026-01-01 00:00:00],
            summary_ko: "이름 변경",
            summary_en: "Renamed"
          }
        ],
        recent_revokes: [
          %{
            change_id: "00000000-0000-0000-0000-000000000004",
            action_kind: "revoke_change",
            applied_at: ~N[2026-01-01 00:00:00],
            summary_ko: "취소",
            summary_en: "Revoked"
          }
        ],
        readiness: %{
          unresolved_questions: 1,
          source_modified_notes: 0,
          export_warnings: 0,
          lawyer_packet_status: :not_started
        }
      }

      changeset = ContextReservoir.changeset(%ContextReservoir{}, attrs)
      assert changeset.valid?

      result = Ecto.Changeset.apply_changes(changeset)

      assert result.brief.purpose == "Negotiate NDA"
      assert length(result.shared_fields) == 2
      assert hd(result.shared_fields).field_id == "party_a"
      assert length(result.open_questions) == 1
      assert hd(result.open_questions).text == "Mutual or one-way?"
      assert hd(result.related_documents).role == :current_draft
      assert hd(result.sources).kind == :upload
      assert hd(result.evidence).source == :law_mcp
      assert hd(result.recent_changes).action_kind == "rename_document"
      assert hd(result.recent_revokes).action_kind == "revoke_change"
      assert result.readiness.unresolved_questions == 1
      assert result.readiness.lawyer_packet_status == :not_started
    end

    test "ignores unknown top-level keys (cast only knows declared fields)" do
      attrs = %{not_a_field: "ignored", brief: %{purpose: "Keep"}}
      changeset = ContextReservoir.changeset(%ContextReservoir{}, attrs)
      assert changeset.valid?
      result = Ecto.Changeset.apply_changes(changeset)
      assert result.brief.purpose == "Keep"
      refute Map.has_key?(result, :not_a_field)
    end
  end
end
