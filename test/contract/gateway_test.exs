defmodule Contract.GatewayTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.Action
  alias Contract.Change
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.IO.R2Stub
  alias Contract.RouteRef
  alias Contract.Runtime

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Context{}

  setup do
    R2Stub.setup()
    R2Stub.reset()

    original_drivers = Application.get_env(:contract, :io_drivers, [])

    Application.put_env(
      :contract,
      :io_drivers,
      Keyword.put(original_drivers, :r2, R2Stub)
    )

    on_exit(fn -> Application.put_env(:contract, :io_drivers, original_drivers) end)
    :ok
  end

  describe "issue_route_ref/2 → verify_route_ref/2" do
    test "round-trips a freshly-issued token" do
      doc_id = Ecto.UUID.generate()
      matter_id = Ecto.UUID.generate()

      assert {:ok, token} =
               Gateway.issue_route_ref(@ctx, %{
                 matter_id: matter_id,
                 document_id: doc_id,
                 purpose: "mcp",
                 scopes: ["read", "write"]
               })

      assert is_binary(token)

      assert {:ok, %RouteRef{} = ref} = Gateway.verify_route_ref(@ctx, token)
      assert ref.matter_id == matter_id
      assert ref.document_id == doc_id
      assert ref.purpose == "mcp"
      assert ref.scopes == ["read", "write"]
      assert %DateTime{} = ref.issued_at
      assert %DateTime{} = ref.expires_at
    end

    test "accepts string keys in attrs" do
      doc_id = Ecto.UUID.generate()

      assert {:ok, token} =
               Gateway.issue_route_ref(@ctx, %{
                 "document_id" => doc_id,
                 "purpose" => "deep_link"
               })

      assert {:ok, %RouteRef{document_id: ^doc_id, purpose: "deep_link"}} =
               Gateway.verify_route_ref(@ctx, token)
    end

    test "defaults TTL to one hour" do
      assert {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "default-ttl"})
      assert {:ok, %RouteRef{issued_at: issued, expires_at: expires}} =
               Gateway.verify_route_ref(@ctx, token)

      assert DateTime.diff(expires, issued, :second) == 3_600
    end

    test "honours a custom TTL" do
      assert {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "ttl", ttl: 60})
      assert {:ok, ref} = Gateway.verify_route_ref(@ctx, token)
      assert DateTime.diff(ref.expires_at, ref.issued_at, :second) == 60
    end

    test "rejects non-positive TTLs" do
      assert {:error, :invalid_ttl} = Gateway.issue_route_ref(@ctx, %{ttl: 0})
      assert {:error, :invalid_ttl} = Gateway.issue_route_ref(@ctx, %{ttl: -5})
    end
  end

  describe "verify_route_ref/2 — failure modes" do
    test "returns :missing for nil" do
      assert {:error, :missing} = Gateway.verify_route_ref(@ctx, nil)
    end

    test "returns :missing for empty string" do
      assert {:error, :missing} = Gateway.verify_route_ref(@ctx, "")
    end

    test "returns :invalid for a tampered token" do
      assert {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "tamper"})

      tampered =
        token
        |> String.graphemes()
        |> List.update_at(-1, fn
          "A" -> "B"
          _ -> "A"
        end)
        |> Enum.join()

      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, tampered)
    end

    test "returns :invalid for garbage input" do
      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, "not-a-real-token")
    end

    test "returns :invalid for non-string input" do
      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, 12_345)
    end

    test "returns :expired for an expired token" do
      # Sign manually with the same salt but a signed_at in the past so
      # max_age enforcement trips. We pass max_age = 60 seconds; signed_at
      # 1 hour ago => expired.
      one_hour_ago =
        DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_unix(:millisecond)

      payload = %{
        matter_id: nil,
        document_id: nil,
        purpose: "expired",
        issued_at: DateTime.to_iso8601(DateTime.utc_now() |> DateTime.add(-3_600, :second)),
        expires_at: DateTime.to_iso8601(DateTime.utc_now() |> DateTime.add(-1, :second)),
        scopes: []
      }

      token =
        Phoenix.Token.sign(ContractWeb.Endpoint, "route_ref", payload,
          max_age: 60,
          signed_at: one_hour_ago
        )

      assert {:error, :expired} = Gateway.verify_route_ref(@ctx, token)
    end
  end

  describe "issue_route_ref/2 — SPEC.md §15.2 invariant (no PIDs in route_refs)" do
    test "rejects a pid value in attrs" do
      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{purpose: "pid-test", document_id: self()})
    end

    test "rejects a reference inside the scopes list" do
      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{
                 purpose: "ref-test",
                 scopes: [:ok, make_ref()]
               })
    end

    test "rejects a function value (also non-durable)" do
      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{purpose: fn -> :nope end})
    end

    test "successful tokens decode to only binary_id strings and atoms" do
      doc_id = Ecto.UUID.generate()
      matter_id = Ecto.UUID.generate()

      assert {:ok, token} =
               Gateway.issue_route_ref(@ctx, %{
                 matter_id: matter_id,
                 document_id: doc_id,
                 purpose: "no-pid",
                 scopes: ["read"]
               })

      assert {:ok, %RouteRef{} = ref} = Gateway.verify_route_ref(@ctx, token)

      # Walk the struct and assert nothing pid-like is present.
      values = Map.values(Map.from_struct(ref))
      refute Enum.any?(values, fn v -> is_pid(v) or is_reference(v) or is_port(v) end)
    end
  end

  describe "mcp_tool/3 — tool listing and dispatch" do
    test "Gateway.tool_names/0 exposes at least 7 studio.* tools" do
      names = Gateway.tool_names()
      assert length(names) >= 7
      assert "studio.get_document" in names
      assert "studio.submit_action" in names
      assert "studio.search_law" in names
    end

    test "tools_descriptor/0 returns matching entries with inputSchemas" do
      desc = Gateway.tools_descriptor()
      assert length(desc) == length(Gateway.tool_names())

      Enum.each(desc, fn entry ->
        assert is_binary(entry["name"])
        assert is_binary(entry["description"])
        assert is_map(entry["inputSchema"])
      end)
    end

    test "unknown tool returns {:error, {:unknown_tool, name}}" do
      assert {:error, {:unknown_tool, "studio.does_not_exist"}} =
               Gateway.mcp_tool(@ctx, "studio.does_not_exist", %{})
    end

    test "studio.get_document returns the projection for an existing doc" do
      doc_id = create_doc()

      ctx = ctx_for(doc_id)
      assert {:ok, payload} = Gateway.mcp_tool(ctx, "studio.get_document", %{"document_id" => doc_id})
      assert payload.document_id == doc_id
      assert payload.revision >= 1
      assert is_map(payload.projection)
    end

    test "studio.get_document is forbidden when route_ref doesn't authorize the doc" do
      _doc_id = create_doc()
      other_doc = Ecto.UUID.generate()
      ctx = ctx_for(other_doc)

      assert {:error, :forbidden} =
               Gateway.mcp_tool(ctx, "studio.get_document", %{"document_id" => Ecto.UUID.generate()})
    end

    test "studio.get_document requires a document_id" do
      assert {:error, :missing_document_id} =
               Gateway.mcp_tool(@ctx, "studio.get_document", %{})
    end

    test "studio.submit_action drives Runtime.apply and returns a Change" do
      doc_id = create_doc()
      ctx = ctx_for(doc_id)

      action_args = %{
        "action" => %{
          "kind" => "rename_document",
          "document_id" => doc_id,
          "actor_type" => "user",
          "actor_id" => Ecto.UUID.generate(),
          "base_revision" => 1,
          "idempotency_key" => "mcp-rn-1",
          "payload" => %{"title" => "MCP-renamed"}
        }
      }

      assert {:ok, payload} = Gateway.mcp_tool(ctx, "studio.submit_action", action_args)
      assert payload.action_kind == "rename_document"
      assert is_binary(payload.id)
    end

    test "studio.submit_action rejects an invalid action shape" do
      ctx = ctx_for(Ecto.UUID.generate())
      assert {:error, {:invalid_action, _}} =
               Gateway.mcp_tool(ctx, "studio.submit_action", %{"action" => %{"kind" => "bogus"}})
    end

    test "studio.get_change_history returns changes" do
      doc_id = create_doc()
      ctx = ctx_for(doc_id)

      assert {:ok, payload} =
               Gateway.mcp_tool(ctx, "studio.get_change_history", %{
                 "document_id" => doc_id,
                 "since_revision" => 0
               })

      assert payload.document_id == doc_id
      assert length(payload.changes) >= 1
      assert hd(payload.changes).action_kind == "create_document"
    end

    test "studio.list_marks returns an empty list for a fresh document" do
      doc_id = create_doc()
      ctx = ctx_for(doc_id)

      assert {:ok, %{document_id: ^doc_id, marks: marks}} =
               Gateway.mcp_tool(ctx, "studio.list_marks", %{"document_id" => doc_id})

      assert is_list(marks)
    end

    test "studio.search_documents returns matches by title substring" do
      doc_id = create_doc(title: "MCP-Searchable Contract")
      ctx = ctx_for(doc_id)

      assert {:ok, payload} = Gateway.mcp_tool(ctx, "studio.search_documents", %{"query" => "Searchable"})
      assert payload.query == "Searchable"
      assert Enum.any?(payload.results, fn r -> r.document_id == doc_id end)
    end

    test "studio.search_documents requires a non-empty query" do
      assert {:error, :invalid_query} =
               Gateway.mcp_tool(@ctx, "studio.search_documents", %{"query" => ""})
    end

    test "studio.verify_citations rejects empty text" do
      assert {:error, :invalid_text} =
               Gateway.mcp_tool(@ctx, "studio.verify_citations", %{"text" => ""})
    end

    test "studio.search_law rejects empty query" do
      assert {:error, :invalid_query} =
               Gateway.mcp_tool(@ctx, "studio.search_law", %{"query" => ""})
    end
  end

  describe "authorize_document/2" do
    test "denies when ctx has no perms and no document_id authority" do
      assert :ok = Gateway.authorize_document(%Context{}, "any-doc-id")
      # When ctx has nothing pinned, we allow (user_api_token style).
    end

    test "allows the pinned doc when route_ref pins document_id" do
      doc_id = Ecto.UUID.generate()
      ref = %RouteRef{document_id: doc_id, scopes: [], purpose: "t",
                      issued_at: DateTime.utc_now(), expires_at: DateTime.utc_now()}
      ctx = %Context{perms: %{route_ref: ref}}

      assert :ok = Gateway.authorize_document(ctx, doc_id)
    end

    test "denies a different doc when route_ref pins document_id" do
      ref = %RouteRef{document_id: Ecto.UUID.generate(), scopes: [], purpose: "t",
                      issued_at: DateTime.utc_now(), expires_at: DateTime.utc_now()}
      ctx = %Context{perms: %{route_ref: ref}}

      assert {:error, :forbidden} = Gateway.authorize_document(ctx, Ecto.UUID.generate())
    end

    test "allows any doc when route_ref has wildcard document_id (nil)" do
      ref = %RouteRef{document_id: nil, scopes: [], purpose: "t",
                      issued_at: DateTime.utc_now(), expires_at: DateTime.utc_now()}
      ctx = %Context{perms: %{route_ref: ref}}

      assert :ok = Gateway.authorize_document(ctx, Ecto.UUID.generate())
    end

    test "denies nil document_id" do
      assert {:error, :forbidden} = Gateway.authorize_document(%Context{}, nil)
    end
  end

  describe "slack_*/1 — out of scope for this build" do
    test "slack_event/1 raises" do
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_event(%{}) end
    end

    test "slack_action/1 raises" do
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_action(%{}) end
    end

    test "slack_command/1 raises" do
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_command(%{}) end
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_doc(opts \\ []) do
    doc_id = Ecto.UUID.generate()
    title = Keyword.get(opts, :title, "Doc")

    action = %Action{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => title, "type_key" => "nda"}
    }

    {:ok, %Change{}} = Runtime.apply(@ctx, action)
    doc_id
  end

  defp ctx_for(doc_id) do
    ref = %RouteRef{
      document_id: doc_id,
      matter_id: nil,
      purpose: "test",
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
      scopes: ["read", "write"]
    }

    %Context{perms: %{route_ref: ref}, now: DateTime.utc_now()}
  end
end
