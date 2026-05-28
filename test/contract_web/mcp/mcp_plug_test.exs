defmodule ContractWeb.MCP.MCPPlugTest do
  use ContractWeb.ConnCase, async: false

  import Mox
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Gateway
  alias Contract.IO.R2Stub

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Context{
    user: %Contract.Accounts.User{
      id: "00000000-0000-0000-0000-0000000000ab",
      email: "mcp-plug@example.test"
    }
  }

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
    test "rejects requests with no / malformed / unrecognized bearer (all 401 -32000)",
         %{conn: conn} do
      body = jsonrpc_body(1, "initialize", %{})

      # No Authorization header.
      no_auth =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert no_auth.status == 401
      assert {:ok, env} = Jason.decode(no_auth.resp_body)
      assert env["error"]["code"] == -32_000

      # Malformed header.
      malformed =
        conn
        |> put_req_header("authorization", "NotBearer x")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert malformed.status == 401

      # Unrecognized bearer.
      unknown =
        conn
        |> put_req_header("authorization", "Bearer not-a-valid-token")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert unknown.status == 401
    end

    test "accepts both route_ref and user-api-token bearers", %{conn: conn} do
      {:ok, route_token} = Gateway.issue_route_ref(@ctx, %{purpose: "test"})

      route_resp = jsonrpc_call(conn, route_token, 1, "initialize", %{})
      assert route_resp.status == 200
      assert {:ok, env} = Jason.decode(route_resp.resp_body)
      assert env["jsonrpc"] == "2.0"
      assert env["id"] == 1
      assert env["result"]["serverInfo"]["name"] == "contract-studio"

      api_token =
        Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: Ecto.UUID.generate()})

      assert jsonrpc_call(conn, api_token, 1, "initialize", %{}).status == 200
    end
  end

  describe "method: initialize" do
    test "returns server info and capabilities", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "init"})
      resp = jsonrpc_call(conn, token, 99, "initialize", %{})

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["id"] == 99
      # No `protocolVersion` in the request → server advertises the
      # newest version it implements (2025-03-26, Streamable HTTP).
      assert env["result"]["protocolVersion"] == "2025-03-26"
      assert env["result"]["serverInfo"]["name"] == "contract-studio"
      assert is_map(env["result"]["capabilities"]["tools"])
      assert is_map(env["result"]["capabilities"]["resources"])
    end

    test "echoes client's protocolVersion when supported", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "init"})

      # Older client (still on 2024-11-05) — we negotiate down.
      resp =
        jsonrpc_call(conn, token, 1, "initialize", %{"protocolVersion" => "2024-11-05"})

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["result"]["protocolVersion"] == "2024-11-05"
    end

    test "falls back to newest version on unknown protocolVersion", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "init"})

      resp =
        jsonrpc_call(conn, token, 1, "initialize", %{"protocolVersion" => "9999-99-99"})

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["result"]["protocolVersion"] == "2025-03-26"
    end
  end

  describe "method: tools/list" do
    test "returns only live doc.* tools each with name/description/inputSchema", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "list"})
      resp = jsonrpc_call(conn, token, 1, "tools/list", %{})
      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)

      tools = env["result"]["tools"]
      assert is_list(tools)
      assert Enum.map(tools, & &1["name"]) == ~w(doc.get doc.read doc.write)

      Enum.each(tools, fn t ->
        assert is_binary(t["name"])
        assert is_binary(t["description"])
        assert is_map(t["inputSchema"])
      end)
    end
  end

  describe "method: resources/list and resources/read" do
    test "resources are pruned", %{conn: conn} do
      user = user_fixture()
      token = Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: user.id})

      list_resp = jsonrpc_call(conn, token, 21, "resources/list", %{})
      assert list_resp.status == 200
      {:ok, list_env} = Jason.decode(list_resp.resp_body)
      assert list_env["result"]["resources"] == []

      read_resp =
        jsonrpc_call(conn, token, 22, "resources/read", %{
          "uri" => "document://#{Ecto.UUID.generate()}/state"
        })

      assert read_resp.status == 200
      {:ok, read_env} = Jason.decode(read_resp.resp_body)
      assert read_env["error"]["code"] == -32_602
    end
  end

  describe "method: tools/call — pruned studio surface" do
    test "returns 401 without bearer", %{conn: conn} do
      body =
        jsonrpc_body(1, "tools/call", %{
          "name" => "doc.get",
          "arguments" => %{}
        })

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert resp.status == 401
    end

    test "legacy studio and private mutation tool names are rejected by the gateway", %{
      conn: conn
    } do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "legacy-doc-tool"})

      for {tool, id} <-
            Enum.with_index(
              ~w(studio.get_document studio.submit_action studio.search_documents
                 studio.get_change_history studio.list_marks studio.search_law
                 doc.find doc.edit
                 studio.verify_citations doc.edit_text doc.insert_block
                 doc.delete_block doc.edit_table doc.set_field_value),
              1
            ) do
        resp =
          jsonrpc_call(conn, token, id, "tools/call", %{
            "name" => tool,
            "arguments" => %{}
          })

        assert resp.status == 200
        {:ok, env} = Jason.decode(resp.resp_body)
        assert env["error"]["code"] == -32_601
        assert env["error"]["message"] == "Tool not found: #{tool}"
      end
    end
  end

  describe "error handling" do
    test "maps unknown-tool / unknown-method / parse / invalid-request / missing-name to codes",
         %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "err"})

      # -32601 unknown tool.
      unk_tool =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.does_not_exist",
          "arguments" => %{}
        })

      {:ok, env1} = Jason.decode(unk_tool.resp_body)
      assert env1["error"]["code"] == -32_601

      # -32601 unknown JSON-RPC method.
      {:ok, env2} = Jason.decode(jsonrpc_call(conn, token, 1, "wat/wat", %{}).resp_body)
      assert env2["error"]["code"] == -32_601

      # -32700 malformed JSON.
      parse_resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", "{not valid")

      {:ok, env3} = Jason.decode(parse_resp.resp_body)
      assert env3["error"]["code"] == -32_700

      # -32600 body missing method.
      inv_resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", ~s({"jsonrpc":"2.0","id":1}))

      {:ok, env4} = Jason.decode(inv_resp.resp_body)
      assert env4["error"]["code"] == -32_600

      # -32602 tools/call missing name.
      noname =
        jsonrpc_call(conn, token, 1, "tools/call", %{"arguments" => %{}})

      {:ok, env5} = Jason.decode(noname.resp_body)
      assert env5["error"]["code"] == -32_602
    end
  end

  describe "SSE transport" do
    test "responds with text/event-stream when Accept asks for it", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "sse"})

      body = jsonrpc_body(1, "initialize", %{})

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
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "json"})

      body = jsonrpc_body(1, "initialize", %{})

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
    test "/slack/{events,actions,commands} all return 501", %{conn: conn} do
      for path <- ~w(/slack/events /slack/actions /slack/commands) do
        assert post(conn, path, %{}).status == 501
      end
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

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
