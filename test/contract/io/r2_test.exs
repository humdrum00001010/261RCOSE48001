defmodule Contract.IO.R2Test do
  use ExUnit.Case, async: false

  alias Contract.IO.R2

  setup do
    bypass = Bypass.open()

    original = Application.get_env(:contract, :r2)

    Application.put_env(:contract, :r2,
      bucket: "test-bucket",
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "SECRET",
      endpoint: "http://localhost:#{bypass.port}"
    )

    on_exit(fn -> Application.put_env(:contract, :r2, original) end)

    {:ok, bypass: bypass}
  end

  describe "put/3" do
    test "PUTs bytes to bucket-prefixed path, returns key + etag", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/test-bucket/uploads/abc.pdf", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        assert body == "PDFBYTES"

        conn
        |> Plug.Conn.put_resp_header("etag", "\"abc123\"")
        |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, %{key: "uploads/abc.pdf", etag: "\"abc123\""}} =
               R2.put("uploads/abc.pdf", "PDFBYTES")
    end

    test "passes content_type opt through as request header", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/test-bucket/key", fn conn ->
        assert ["application/pdf"] = Plug.Conn.get_req_header(conn, "content-type")
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, _} = R2.put("key", "bytes", content_type: "application/pdf")
    end

    test "returns {:error, {:r2_put_failed, _}} on 500", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/test-bucket/key", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:error, {:r2_put_failed, _}} = R2.put("key", "bytes")
    end

    test "honors explicit :bucket override", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/other-bucket/k", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, _} = R2.put("k", "v", bucket: "other-bucket")
    end
  end

  describe "get/2" do
    test "GETs the object body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/snap.json", fn conn ->
        Plug.Conn.resp(conn, 200, "BODY-BYTES")
      end)

      assert {:ok, "BODY-BYTES"} = R2.get("snap.json")
    end

    test "returns {:error, {:r2_get_failed, _}} on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/missing", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert {:error, {:r2_get_failed, _}} = R2.get("missing")
    end
  end

  describe "delete/2" do
    test "DELETEs the object", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/test-bucket/k", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = R2.delete("k")
    end
  end

  describe "presigned_url/2" do
    test "returns a signed URL with auth params and honours :expires_in" do
      assert {:ok, default_url} = R2.presigned_url("downloads/abc.pdf")
      assert is_binary(default_url)
      assert default_url =~ "/test-bucket/downloads/abc.pdf"
      assert default_url =~ "X-Amz-Signature="

      assert {:ok, custom} = R2.presigned_url("k", expires_in: 60)
      assert custom =~ "X-Amz-Expires=60"
    end
  end
end
