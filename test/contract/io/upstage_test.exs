defmodule Contract.IO.UpstageTest do
  use ExUnit.Case, async: false

  alias Contract.IO.Upstage

  setup do
    bypass = Bypass.open()

    Application.put_env(:contract, :upstage,
      endpoint: "http://localhost:#{bypass.port}/v1/document-ai/document-parse",
      api_key: "test-upstage-key"
    )

    on_exit(fn -> Application.delete_env(:contract, :upstage) end)

    {:ok, bypass: bypass}
  end

  describe "parse/2" do
    test "POSTs multipart form, sends auth header, parses response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        assert ["Bearer test-upstage-key"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        assert body =~ ~r/form-data; name="document"/i
        assert body =~ ~r/name="ocr"/
        assert body =~ "auto"
        assert body =~ ~r/name="coordinates"/
        assert body =~ "true"
        assert body =~ ~r/name="output_formats"/
        assert body =~ "html"
        assert body =~ "markdown"
        assert body =~ ~r/name="model"/
        assert body =~ "document-parse"

        response = %{
          "elements" => [
            %{
              "id" => 0,
              "category" => "paragraph",
              "content" => %{"text" => "hello"}
            }
          ],
          "content" => %{"text" => "hello"},
          "model" => "document-parse",
          "usage" => %{"pages" => 1}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      tmpfile = write_tempfile("hello")
      assert {:ok, parsed} = Upstage.parse(tmpfile)
      assert is_list(parsed.elements)
      assert hd(parsed.elements)["category"] == "paragraph"
      assert parsed.content == %{"text" => "hello"}
    end

    test "non-200 returns {:error, {:upstage_http, ...}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        Plug.Conn.resp(conn, 502, ~s({"error":"bad gateway"}))
      end)

      tmpfile = write_tempfile("hello")
      assert {:error, {:upstage_http, 502, _}} = Upstage.parse(tmpfile)
    end

    test "transport failure returns {:error, {:upstage_transport, ...}}", %{bypass: bypass} do
      Bypass.down(bypass)

      tmpfile = write_tempfile("hello")
      assert {:error, {:upstage_transport, _}} = Upstage.parse(tmpfile)
    end

    test "honors api_key override", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        assert ["Bearer override-key"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"elements" => [], "content" => %{}}))
      end)

      tmpfile = write_tempfile("hello")
      assert {:ok, _} = Upstage.parse(tmpfile, api_key: "override-key")
    end
  end

  describe "normalize_elements/1" do
    test "maps paragraph category to :paragraph kind" do
      elements = [%{"id" => 0, "category" => "paragraph", "content" => %{"text" => "hi"}}]
      [node] = Upstage.normalize_elements(elements)
      assert node["kind"] == :paragraph
      assert node["content"]["text"] == "hi"
      assert node["id"] == "node:0"
    end

    test "maps heading1 through heading6 to :heading" do
      for level <- 1..6 do
        elements = [%{"id" => level, "category" => "heading#{level}", "content" => %{"text" => "x"}}]
        [node] = Upstage.normalize_elements(elements)
        assert node["kind"] == :heading
      end
    end

    test "maps list/list_item/table/figure categories" do
      for {cat, kind} <- [
            {"list", :list},
            {"list_item", :list_item},
            {"table", :table},
            {"figure", :figure}
          ] do
        elements = [%{"id" => 1, "category" => cat, "content" => %{"text" => "x"}}]
        [node] = Upstage.normalize_elements(elements)
        assert node["kind"] == kind, "expected #{cat} -> #{kind}, got #{inspect(node["kind"])}"
      end
    end

    test "falls back to :paragraph for unknown categories" do
      elements = [%{"id" => 9, "category" => "obscure-thing", "content" => %{"text" => "x"}}]
      [node] = Upstage.normalize_elements(elements)
      assert node["kind"] == :paragraph
    end

    test "preserves page + coordinates + original category in attrs" do
      coords = [%{"x" => 0.1, "y" => 0.1}, %{"x" => 0.9, "y" => 0.9}]

      elements = [
        %{
          "id" => 1,
          "category" => "table",
          "content" => %{"html" => "<table></table>"},
          "page" => 3,
          "coordinates" => coords
        }
      ]

      [node] = Upstage.normalize_elements(elements)
      assert node["attrs"]["page"] == 3
      assert node["attrs"]["coordinates"] == coords
      assert node["attrs"]["category"] == "table"
    end
  end

  describe "import_upload/3" do
    test "returns Action(:create_document) with normalized nodes + source ref", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/document-ai/document-parse", fn conn ->
        response = %{
          "elements" => [
            %{"id" => 0, "category" => "heading1", "content" => %{"text" => "TITLE"}},
            %{"id" => 1, "category" => "paragraph", "content" => %{"text" => "body"}}
          ],
          "content" => %{}
        }

        Plug.Conn.resp(conn, 200, Jason.encode!(response))
      end)

      tmpfile = write_tempfile("PDFBYTES")
      matter_id = Ecto.UUID.generate()

      upload = %{
        path: tmpfile,
        client_name: "contract.pdf",
        client_type: "application/pdf",
        client_size: 8
      }

      # Stub R2: rewire to a fake bucket-less endpoint that 200s.
      bypass_r2 = Bypass.open()

      Bypass.expect(bypass_r2, fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      original = Application.get_env(:contract, :r2)

      Application.put_env(:contract, :r2,
        bucket: "test-bucket",
        access_key_id: "k",
        secret_access_key: "s",
        endpoint: "http://localhost:#{bypass_r2.port}"
      )

      on_exit(fn -> Application.put_env(:contract, :r2, original) end)

      assert {:ok, %Contract.Action{} = action} =
               Upstage.import_upload(nil, matter_id, upload)

      assert action.kind == :create_document
      assert action.matter_id == matter_id
      assert is_list(action.payload["nodes"])
      assert length(action.payload["nodes"]) == 2
      assert hd(action.payload["nodes"])["kind"] == :heading
      assert action.payload["title"] == "contract.pdf"
      assert action.payload["mime_type"] == "application/pdf"
      assert is_binary(action.payload["artifact_id"])
      assert String.starts_with?(action.payload["source"]["key"], "matters/")
    end
  end

  defp write_tempfile(contents) do
    path = Path.join(System.tmp_dir!(), "upstage-test-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end
end
