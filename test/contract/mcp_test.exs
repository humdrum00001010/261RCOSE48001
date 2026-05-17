defmodule Contract.MCPTest do
  use Contract.DataCase, async: false

  alias Contract.Change
  alias Contract.Command
  alias Contract.Context
  alias Contract.EvidenceSnapshot
  alias Contract.MCP
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Runtime
  alias Contract.SourceDocument

  describe "list_tools/2" do
    test "includes expanded document/source/law/evidence/collab tools" do
      assert %{"tools" => tools} = MCP.list_tools(%Context{}, nil)
      names = Enum.map(tools, & &1["name"])

      assert length(names) >= 20
      assert "document.open" in names
      assert "document.read" in names
      assert "document.search" in names
      assert "document.submit_command" in names
      assert "document.revoke_change" in names
      assert "source_document.read" in names
      assert "source_document.search_regions" in names
      assert "source_document.propose_claims" in names
      assert "source_document.confirm_claim" in names
      assert "source_document.correct_claim" in names
      assert "source_document.reject_claim" in names
      assert "source_document.link_claim_to_document" in names
      assert "law.search" in names
      assert "law.get_text" in names
      assert "law.search_precedents" in names
      assert "law.verify_citation" in names
      assert "evidence.attach_mark" in names
      assert "collab.ask_user" in names
      assert "collab.fetch_slack_context" in names
    end
  end

  describe "list_resources/2 and read_resource/3" do
    test "returns owner-scoped document/source/evidence resources" do
      owner = scope()
      foreign = scope()
      doc_id = create_doc(owner, title: "Owner MCP Resource")
      foreign_doc_id = create_doc(foreign, title: "Foreign MCP Resource")
      source = insert_source(owner, document_id: doc_id)
      foreign_source = insert_source(foreign, document_id: foreign_doc_id)
      evidence = insert_evidence(owner, document_id: doc_id, source_document_id: source.id)
      foreign_evidence = insert_evidence(foreign, document_id: foreign_doc_id)

      assert %{"resources" => resources} = MCP.list_resources(owner, nil)
      uris = Enum.map(resources, & &1["uri"])

      assert "document://#{doc_id}/state" in uris
      assert "source_document://#{source.id}" in uris
      assert "evidence://#{evidence.id}" in uris
      refute "document://#{foreign_doc_id}/state" in uris
      refute "source_document://#{foreign_source.id}" in uris
      refute "evidence://#{foreign_evidence.id}" in uris

      assert {:ok, doc_payload} = MCP.read_resource(owner, nil, "document://#{doc_id}/state")
      assert %{"contents" => [%{"uri" => "document://" <> _, "text" => doc_text}]} = doc_payload
      assert {:ok, %{"document_id" => ^doc_id}} = Jason.decode(doc_text)

      assert {:ok, source_payload} =
               MCP.read_resource(owner, nil, "source_document://#{source.id}")

      [%{"text" => source_text}] = source_payload["contents"]
      assert {:ok, %{"id" => source_id}} = Jason.decode(source_text)
      assert source_id == source.id

      assert {:ok, evidence_payload} = MCP.read_resource(owner, nil, "evidence://#{evidence.id}")
      [%{"text" => evidence_text}] = evidence_payload["contents"]
      assert {:ok, %{"id" => evidence_id}} = Jason.decode(evidence_text)
      assert evidence_id == evidence.id

      assert {:error, :forbidden} =
               MCP.read_resource(owner, nil, "document://#{foreign_doc_id}/state")

      assert {:error, :forbidden} =
               MCP.read_resource(owner, nil, "source_document://#{foreign_source.id}")

      assert {:error, :forbidden} =
               MCP.read_resource(owner, nil, "evidence://#{foreign_evidence.id}")
    end
  end

  describe "call_tool/4" do
    test "document.submit_command emits a Command through Runtime with owner ACL" do
      owner = scope()
      foreign = scope()
      doc_id = create_doc(owner, title: "Before MCP Rename")
      foreign_doc_id = create_doc(foreign, title: "Foreign Before MCP Rename")

      args = %{
        "command" => %{
          "kind" => "rename_document",
          "document_id" => doc_id,
          "base_revision" => 1,
          "idempotency_key" => "mcp-submit-command-1",
          "payload" => %{"title" => "After MCP Rename"}
        }
      }

      assert {:ok, %{"command_kind" => "rename_document", "result_revision" => 2}} =
               MCP.call_tool(owner, nil, "document.submit_command", args)

      assert {:ok, doc} = Contract.Documents.get(owner, doc_id)
      assert doc.title == "After MCP Rename"

      foreign_args = put_in(args, ["command", "document_id"], foreign_doc_id)

      assert {:error, :forbidden} =
               MCP.call_tool(owner, nil, "document.submit_command", foreign_args)

      assert {:ok, foreign_doc} = Contract.Documents.get(foreign, foreign_doc_id)
      assert foreign_doc.title == "Foreign Before MCP Rename"
    end

    test "route_ref-only access does not bypass owner ACL" do
      owner = scope()
      doc_id = create_doc(owner, title: "Route Ref Only")

      route_ref = %RouteRef{
        document_id: doc_id,
        purpose: "mcp-test",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second),
        scopes: ["read", "write"]
      }

      ctx = %Context{perms: %{route_ref: route_ref}}

      assert {:error, :forbidden} =
               MCP.read_resource(ctx, route_ref, "document://#{doc_id}/state")

      assert {:error, :forbidden} =
               MCP.call_tool(ctx, route_ref, "document.submit_command", %{
                 "command" => %{
                   "kind" => "rename_document",
                   "document_id" => doc_id,
                   "base_revision" => 1,
                   "idempotency_key" => "route-ref-only-denied",
                   "payload" => %{"title" => "Should Not Apply"}
                 }
               })
    end
  end

  describe "initialize/1" do
    test "returns MCP capabilities for tools and resources" do
      assert %{"protocolVersion" => _, "serverInfo" => server, "capabilities" => caps} =
               MCP.initialize(%{})

      assert server["name"] == "contract-studio"
      assert is_map(caps["tools"])
      assert is_map(caps["resources"])
    end
  end

  defp create_doc(%Context{} = ctx, opts) do
    doc_id = Ecto.UUID.generate()
    title = Keyword.fetch!(opts, :title)

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => title, "type_key" => "nda_v1"}
    }

    assert {:ok, %Change{}} = Runtime.apply(ctx, action)
    doc_id
  end

  defp insert_source(%Context{} = ctx, attrs) do
    {:ok, source} =
      %SourceDocument{}
      |> SourceDocument.changeset(%{
        owner_id: ctx.user.id,
        document_id: Keyword.get(attrs, :document_id),
        blob_ref_id: Ecto.UUID.generate(),
        mime_type: "application/pdf",
        original_filename: "source.pdf",
        regions: [%{"id" => "r1", "text" => "Party A"}],
        status: "ready"
      })
      |> Repo.insert()

    source
  end

  defp insert_evidence(%Context{} = ctx, attrs) do
    {:ok, evidence} =
      %EvidenceSnapshot{}
      |> EvidenceSnapshot.changeset(%{
        owner_id: ctx.user.id,
        document_id: Keyword.get(attrs, :document_id),
        source_document_id: Keyword.get(attrs, :source_document_id),
        provider: "test-law",
        query: %{"q" => "contract"},
        result: %{"summary" => "citation"},
        result_hash: Ecto.UUID.generate(),
        captured_at: DateTime.utc_now(:second)
      })
      |> Repo.insert()

    evidence
  end

  defp scope do
    user_id = Ecto.UUID.generate()

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "mcp-#{user_id}@example.test"
      }
    }
  end
end
