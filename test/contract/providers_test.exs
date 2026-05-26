defmodule Contract.ProvidersTest do
  @moduledoc """
  Unit tests for `Contract.Providers` (SPEC.md v0.5 §20).

  Per `[[feedback-review-adds-tests]]`, this file pins the contracts that
  downstream waves depend on:

    * `parse_document/2` returns regions with the active shape
      (`:kind, :region_id, :page, :bbox, :raw_text`).
    * `search_law/2` returns a law record list payload.
    * `verify_citation/2` round-trips through Korea Law MCP.
    * `render_export/3` handles `:markdown`, dispatches to renderers,
      and renders a deterministic lawyer packet artifact.
    * `search_precedents/2`, `get_law_text/2` go through MCP `tools/call`.
  """
  use Contract.DataCase, async: false

  alias Contract.Providers

  describe "parse_document/2 (Upstage)" do
    test "POSTs to Upstage and returns regions with v0.5 shape" do
      bypass = Bypass.open()

      original = Application.get_env(:contract, :upstage)

      Application.put_env(:contract, :upstage,
        endpoint: "http://localhost:#{bypass.port}/v1/document-ai/document-parse",
        api_key: "test-upstage-key"
      )

      on_exit(fn -> Application.put_env(:contract, :upstage, original) end)

      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        assert ["Bearer test-upstage-key"] = Plug.Conn.get_req_header(conn, "authorization")

        body = %{
          "elements" => [
            %{
              "id" => 0,
              "category" => "heading1",
              "content" => %{"text" => "TITLE"},
              "page" => 1,
              "coordinates" => [
                %{"x" => 0.0, "y" => 0.0},
                %{"x" => 1.0, "y" => 0.05}
              ]
            },
            %{
              "id" => 1,
              "category" => "paragraph",
              "content" => %{"text" => "body text"},
              "page" => 1,
              "coordinates" => [%{"x" => 0.0, "y" => 0.1}, %{"x" => 1.0, "y" => 0.2}]
            }
          ],
          "content" => %{}
        }

        Plug.Conn.resp(conn, 200, Jason.encode!(body))
      end)

      tmp = write_tempfile("PDFBYTES")

      assert {:ok, %{regions: regions, raw: %{}}} = Providers.parse_document(nil, tmp)

      assert length(regions) == 2

      [r1, r2] = regions

      # Pinned shape per task: kind, region_id, page, bbox, raw_text.
      for r <- [r1, r2] do
        assert Map.has_key?(r, :kind)
        assert Map.has_key?(r, :region_id)
        assert Map.has_key?(r, :page)
        assert Map.has_key?(r, :bbox)
        assert Map.has_key?(r, :raw_text)
      end

      assert r1.kind == :heading
      assert r1.region_id == "region:0"
      assert r1.page == 1
      assert r1.raw_text == "TITLE"
      assert is_list(r1.bbox)

      assert r2.kind == :paragraph
      assert r2.raw_text == "body text"
    end
  end

  describe "search_law/2 (Korea Law MCP)" do
    test "returns law record payload from MCP" do
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
        assert decoded["params"]["arguments"]["query"] == "민법"

        result =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => decoded["id"],
            "result" => %{
              "content" => [
                %{
                  "type" => "text",
                  "text" =>
                    Jason.encode!(%{
                      "items" => [
                        %{
                          "law_id" => "001",
                          "mst" => "MST-001",
                          "title" => "민법",
                          "score" => 0.92
                        }
                      ]
                    })
                }
              ]
            }
          })

        Plug.Conn.resp(conn, 200, result)
      end)

      assert {:ok, items} = Providers.search_law(nil, "민법")
      assert [law] = items
      assert law["law_id"] == "001"
      assert law["title"] == "민법"
      assert is_number(law["score"])
    end
  end

  describe "verify_citation/2 (Korea Law MCP)" do
    test "round-trips a single citation string" do
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
        assert decoded["params"]["name"] == "verify_citations"

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => decoded["id"],
            "result" => %{
              "content" => [
                %{
                  "text" => Jason.encode!([%{"citation" => "민법 제390조", "valid" => true}])
                }
              ]
            }
          })
        )
      end)

      assert {:ok, [%{"citation" => "민법 제390조", "valid" => true}]} =
               Providers.verify_citation(nil, "민법 제390조")
    end
  end

  describe "search_precedents/2, get_law_text/2" do
    setup do
      bypass = Bypass.open()
      original = Application.get_env(:contract, :law_mcp)

      Application.put_env(:contract, :law_mcp,
        endpoint: "http://localhost:#{bypass.port}/mcp",
        oc: "openapi"
      )

      on_exit(fn -> Application.put_env(:contract, :law_mcp, original) end)
      {:ok, bypass: bypass}
    end

    test "search_precedents goes through MCP tools/call", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["params"]["name"] == "search_precedents"

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => decoded["id"],
            "result" => %{
              "content" => [
                %{"text" => Jason.encode!(%{"items" => [%{"case_id" => "2020다1234"}]})}
              ]
            }
          })
        )
      end)

      assert {:ok, [%{"case_id" => "2020다1234"}]} =
               Providers.search_precedents(nil, "손해배상")
    end

    test "get_law_text goes through MCP tools/call", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["params"]["name"] == "get_law_text"
        assert decoded["params"]["arguments"]["law_ref"] == "민법"

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => decoded["id"],
            "result" => %{
              "content" => [%{"text" => Jason.encode!(%{"text" => "제1조 ..."})}]
            }
          })
        )
      end)

      assert {:ok, %{"text" => "제1조 ..."}} = Providers.get_law_text(nil, "민법")
    end
  end

  describe "render_export/3" do
    test ":lawyer_packet renders a deterministic packet artifact" do
      state = %Contract.Runtime.State{
        document_id: "doc-packet",
        revision: 3,
        projection: %{
          Contract.Runtime.State.empty_projection()
          | title: "Packet Contract",
            nodes: %{
              "n1" => %{id: "n1", kind: :paragraph, content: "Payment due in 10 days."}
            },
            node_order: ["n1"],
            marks: %{
              "m1" => %{
                id: "m1",
                intent: :source_claim,
                source: :parser,
                target_type: :node,
                target_id: "n1",
                text: "Source page 1"
              }
            }
        }
      }

      assert {:ok, body, "text/markdown"} =
               Providers.render_export(nil, state, :lawyer_packet)

      assert body =~ "# Lawyer Packet: Packet Contract"
      assert body =~ "## Rendered Contract"
      assert body =~ "Payment due in 10 days."
      refute body =~ "not_implemented"
    end

    test ":markdown via the legacy 1-arg renderer returns bytes + content_type" do
      assert {:ok, body, "text/markdown"} =
               Providers.render_export(nil, %{document_id: "d1"}, :markdown)

      assert is_binary(body)
      assert body =~ "d1"
      assert body =~ "markdown"
    end

    test "unsupported format returns {:error, {:unsupported_format, _}}" do
      assert {:error, {:unsupported_format, :tiff}} =
               Providers.render_export(nil, %{document_id: "x"}, :tiff)
    end
  end

  defp write_tempfile(contents) do
    path = Path.join(System.tmp_dir!(), "providers-test-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end
end
