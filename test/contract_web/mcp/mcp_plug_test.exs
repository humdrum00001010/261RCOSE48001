defmodule ContractWeb.MCP.MCPPlugTest do
  use ContractWeb.ConnCase, async: false

  import Mox

  alias Contract.Command
  alias Contract.Change
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.IO.R2Stub
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

  describe "auth — bearer enforcement" do
    test "returns 401 when no Authorization header is present", %{conn: conn} do
      body = jsonrpc_body(1, "initialize", %{})

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert resp.status == 401
      assert {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_000
    end

    test "returns 401 for a malformed Authorization header", %{conn: conn} do
      body = jsonrpc_body(1, "initialize", %{})

      resp =
        conn
        |> put_req_header("authorization", "NotBearer x")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert resp.status == 401
    end

    test "returns 401 for an unrecognized bearer", %{conn: conn} do
      body = jsonrpc_body(1, "initialize", %{})

      resp =
        conn
        |> put_req_header("authorization", "Bearer not-a-valid-token")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert resp.status == 401
    end

    test "accepts a valid route_ref bearer", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "test"})

      resp = jsonrpc_call(conn, token, 1, "initialize", %{})

      assert resp.status == 200
      assert {:ok, env} = Jason.decode(resp.resp_body)
      assert env["jsonrpc"] == "2.0"
      assert env["id"] == 1
      assert env["result"]["serverInfo"]["name"] == "contract-studio"
    end

    test "accepts a user-api-token bearer (Phoenix.Token api_token salt)", %{conn: conn} do
      user_id = Ecto.UUID.generate()

      token =
        Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: user_id})

      resp = jsonrpc_call(conn, token, 1, "initialize", %{})
      assert resp.status == 200
    end
  end

  describe "method: initialize" do
    test "returns server info and capabilities", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "init"})
      resp = jsonrpc_call(conn, token, 99, "initialize", %{})

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["id"] == 99
      assert env["result"]["protocolVersion"] == "2024-11-05"
      assert env["result"]["serverInfo"]["name"] == "contract-studio"
      assert is_map(env["result"]["capabilities"]["tools"])
    end
  end

  describe "method: tools/list" do
    test "returns at least 7 studio.* tools", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "list"})

      resp = jsonrpc_call(conn, token, 1, "tools/list", %{})
      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)

      tools = env["result"]["tools"]
      assert is_list(tools)
      assert length(tools) >= 7

      names = Enum.map(tools, & &1["name"])
      assert "studio.get_document" in names
      assert "studio.submit_action" in names
      assert "studio.search_documents" in names
      assert "studio.get_change_history" in names
      assert "studio.list_marks" in names
      assert "studio.search_law" in names
      assert "studio.verify_citations" in names
    end

    test "each tool entry has an inputSchema", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "list-schema"})
      resp = jsonrpc_call(conn, token, 1, "tools/list", %{})
      {:ok, env} = Jason.decode(resp.resp_body)

      Enum.each(env["result"]["tools"], fn t ->
        assert is_binary(t["name"])
        assert is_binary(t["description"])
        assert is_map(t["inputSchema"])
      end)
    end
  end

  describe "method: tools/call — studio.get_document" do
    test "returns 401 without bearer", %{conn: conn} do
      doc_id = create_doc()

      body =
        jsonrpc_body(1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert resp.status == 401
    end

    test "returns the projection for a valid route_ref + valid doc_id", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "get", document_id: doc_id})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["result"]["isError"] == false
      [%{"type" => "text", "text" => text}] = env["result"]["content"]
      assert {:ok, decoded} = Jason.decode(text)
      assert decoded["document_id"] == doc_id
      assert decoded["revision"] >= 1
    end

    test "forbidden when route_ref pins a different document", %{conn: conn} do
      doc_id = create_doc()
      other = Ecto.UUID.generate()

      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "wrong", document_id: other})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_001
    end

    test "returns -32602 when document_id is missing", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "miss"})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{}
        })

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_602
    end
  end

  describe "method: tools/call — studio.submit_action" do
    test "drives Runtime.apply and produces a Change via :rename_document", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "submit", document_id: doc_id})

      args = %{
        "name" => "studio.submit_action",
        "arguments" => %{
          "action" => %{
            "kind" => "rename_document",
            "document_id" => doc_id,
            "actor_type" => "user",
            "actor_id" => Ecto.UUID.generate(),
            "base_revision" => 1,
            "idempotency_key" => "plug-rn-1",
            "payload" => %{"title" => "Plug-Renamed"}
          }
        }
      }

      resp = jsonrpc_call(conn, token, 42, "tools/call", args)
      assert resp.status == 200

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["id"] == 42
      assert env["result"]["isError"] == false

      [%{"text" => text}] = env["result"]["content"]
      {:ok, payload} = Jason.decode(text)
      assert payload["action_kind"] == "rename_document"
      assert payload["applied_revision"] == 2
    end

    test "returns -32602 for an invalid action shape", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "submit-bad", document_id: doc_id})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.submit_action",
          "arguments" => %{"action" => %{"kind" => "not_a_real_kind"}}
        })

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_602
    end
  end

  describe "method: tools/call — studio.get_change_history and studio.list_marks" do
    test "studio.get_change_history returns recorded changes", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "hist", document_id: doc_id})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.get_change_history",
          "arguments" => %{"document_id" => doc_id, "since_revision" => 0}
        })

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      [%{"text" => text}] = env["result"]["content"]
      {:ok, payload} = Jason.decode(text)
      assert payload["document_id"] == doc_id
      assert is_list(payload["changes"])
      assert length(payload["changes"]) >= 1
    end

    test "studio.list_marks returns the marks list", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "marks", document_id: doc_id})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.list_marks",
          "arguments" => %{"document_id" => doc_id}
        })

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      [%{"text" => text}] = env["result"]["content"]
      {:ok, payload} = Jason.decode(text)
      assert payload["document_id"] == doc_id
      assert is_list(payload["marks"])
    end
  end

  describe "error handling" do
    test "returns -32601 for an unknown tool", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "unk"})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.does_not_exist",
          "arguments" => %{}
        })

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_601
    end

    test "returns -32601 for an unknown JSON-RPC method", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "unk-method"})

      resp = jsonrpc_call(conn, token, 1, "wat/wat", %{})
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_601
    end

    test "returns -32700 for malformed JSON", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "parse"})

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", "{not valid")

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_700
    end

    test "returns -32600 for a JSON body missing method", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "inv"})

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", ~s({"jsonrpc":"2.0","id":1}))

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_600
    end

    test "returns -32602 when tools/call is missing the tool name", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "noname"})

      resp = jsonrpc_call(conn, token, 1, "tools/call", %{"arguments" => %{}})
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_602
    end
  end

  describe "SSE transport" do
    test "responds with text/event-stream when Accept asks for it", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "sse", document_id: doc_id})

      body =
        jsonrpc_body(1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/mcp", body)

      assert resp.status == 200
      assert {"content-type", ct} = List.keyfind(resp.resp_headers, "content-type", 0)
      assert String.contains?(ct, "text/event-stream")
      assert String.starts_with?(resp.resp_body, "data: ")
      assert String.contains?(resp.resp_body, "\"jsonrpc\":\"2.0\"")
    end

    test "responds as JSON when Accept is application/json", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "json", document_id: doc_id})

      body =
        jsonrpc_body(1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> post("/mcp", body)

      assert resp.status == 200
      assert {"content-type", ct} = List.keyfind(resp.resp_headers, "content-type", 0)
      assert String.contains?(ct, "application/json")
      refute String.starts_with?(resp.resp_body, "data: ")
    end
  end

  describe "Slack ingress remains 501 (out of scope for this build)" do
    test "/slack/events returns 501", %{conn: conn} do
      resp = post(conn, "/slack/events", %{})
      assert resp.status == 501
    end

    test "/slack/actions returns 501", %{conn: conn} do
      resp = post(conn, "/slack/actions", %{})
      assert resp.status == 501
    end

    test "/slack/commands returns 501", %{conn: conn} do
      resp = post(conn, "/slack/commands", %{})
      assert resp.status == 501
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_doc do
    doc_id = Ecto.UUID.generate()

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => "Plug Doc", "type_key" => "nda"}
    }

    {:ok, %Change{}} = Runtime.apply(@ctx, action)
    doc_id
  end

  defp jsonrpc_body(id, method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp jsonrpc_call(conn, token, id, method, params) do
    body = jsonrpc_body(id, method, params)

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end
end
