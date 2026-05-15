defmodule Contract.IOTest do
  @moduledoc """
  Façade-level smoke tests for `Contract.IO`. Each function should
  dispatch to the right sub-module (verified by spinning up a Bypass
  server with the expected method/path).
  """
  use ExUnit.Case, async: false

  describe "search_law/3 dispatches to LawMCP" do
    test "POSTs JSON-RPC search_law" do
      bypass = Bypass.open()
      original = Application.get_env(:contract, :law_mcp)

      Application.put_env(:contract, :law_mcp,
        endpoint: "http://localhost:#{bypass.port}/mcp",
        oc: "openapi"
      )

      on_exit(fn -> Application.put_env(:contract, :law_mcp, original) end)

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["params"]["name"] == "search_law"

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => %{
              "content" => [%{"text" => Jason.encode!(%{"items" => [%{"law_id" => "1"}]})}]
            }
          })
        )
      end)

      assert {:ok, [%{"law_id" => "1"}]} = Contract.IO.search_law(nil, "민법")
    end
  end

  describe "verify_citation/3 dispatches to LawMCP.verify_citations" do
    test "POSTs JSON-RPC verify_citations" do
      bypass = Bypass.open()
      original = Application.get_env(:contract, :law_mcp)

      Application.put_env(:contract, :law_mcp,
        endpoint: "http://localhost:#{bypass.port}/mcp",
        oc: "openapi"
      )

      on_exit(fn -> Application.put_env(:contract, :law_mcp, original) end)

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => %{
              "content" => [%{"text" => Jason.encode!([%{"citation" => "민법 제390조", "valid" => true}])}]
            }
          })
        )
      end)

      assert {:ok, [%{"valid" => true}]} = Contract.IO.verify_citation(nil, "민법 제390조")
    end
  end

  describe "export/4 dispatches to R2.export" do
    test "uploads rendered bytes + returns presigned URL" do
      bypass = Bypass.open()
      original = Application.get_env(:contract, :r2)

      Application.put_env(:contract, :r2,
        bucket: "test-bucket",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "SECRET",
        endpoint: "http://localhost:#{bypass.port}"
      )

      on_exit(fn -> Application.put_env(:contract, :r2, original) end)

      Bypass.expect(bypass, fn conn ->
        assert conn.method == "PUT"
        Plug.Conn.resp(conn, 200, "")
      end)

      render_fun = fn _ -> {:ok, "RENDERED", "text/markdown"} end

      assert {:ok, %Contract.Export{format: :md, url: url}} =
               Contract.IO.export(nil, Ecto.UUID.generate(), :md, render_fun: render_fun)

      assert url =~ "/test-bucket/exports/"
    end
  end
end
