defmodule Contract.BlobsTest do
  @moduledoc """
  Unit tests for `Contract.Blobs` (SPEC.md v0.5 §19).

  Per `[[feedback-review-adds-tests]]`, every behaviour worth pinning gets
  a test in the same pass — these tests pin:

    * `put/3` PUTs raw bytes to R2 and returns `{:ok, %{key, etag}}`.
    * `put_upload/3` consumes a `%Plug.Upload{}`, uploads to R2 under
      `uploads/<owner>/<id>.<ext>`, inserts a `Contract.BlobRef` row via
      `Contract.Repo`, and returns the persisted struct (owner_id +
      sha256 + size_bytes are pinned).
    * `get/2`, `signed_url/3`, `delete/2` accept any blob-like input
      (`%BlobRef{object_key:}`, `%{object_key:}`, raw key) and
      round-trip through R2.
  """
  use Contract.DataCase, async: false

  alias Contract.{BlobRef, Blobs, Context, Repo}
  alias Contract.Accounts.User

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
    test "PUTs bytes to R2 and returns key + etag", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/test-bucket/foo/bar.bin", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        assert body == "BYTES"

        conn
        |> Plug.Conn.put_resp_header("etag", "\"deadbeef\"")
        |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, %{key: "foo/bar.bin", etag: "\"deadbeef\""}} =
               Blobs.put(nil, "foo/bar.bin", "BYTES")
    end
  end

  describe "put_upload/3" do
    test "stamps owner_id from ctx, uploads bytes, inserts a BlobRef row",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path =~ ~r{^/test-bucket/uploads/[^/]+/[^/]+\.pdf$}
        # The default content-type header from `Plug.Upload` is forwarded.
        assert ["application/pdf"] = Plug.Conn.get_req_header(conn, "content-type")

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        assert body == "PDFBYTES"

        conn
        |> Plug.Conn.put_resp_header("etag", "\"abc\"")
        |> Plug.Conn.resp(200, "")
      end)

      owner_id = Ecto.UUID.generate()
      ctx = %Context{user: %User{id: owner_id}}

      tmp = write_tempfile("PDFBYTES")

      upload = %Plug.Upload{
        path: tmp,
        filename: "contract.pdf",
        content_type: "application/pdf"
      }

      assert {:ok, %BlobRef{} = ref} = Blobs.put_upload(ctx, upload)

      # Pinned shape per task: owner_id stamped from ctx, W1 schema field
      # names (object_key / size_bytes / sha256), persisted row.
      assert ref.owner_id == owner_id
      assert is_binary(ref.id)
      assert String.starts_with?(ref.object_key, "uploads/#{owner_id}/")
      assert String.ends_with?(ref.object_key, ".pdf")
      assert ref.size_bytes == byte_size("PDFBYTES")
      assert ref.mime_type == "application/pdf"
      assert ref.kind == "source_upload"

      # sha256 is the lowercase hex of SHA-256(body).
      expected_sha =
        :crypto.hash(:sha256, "PDFBYTES") |> Base.encode16(case: :lower)

      assert ref.sha256 == expected_sha
      assert ref.metadata["client_name"] == "contract.pdf"

      # The row is actually persisted via Contract.Repo — fetch it back.
      reloaded = Repo.get!(BlobRef, ref.id)
      assert reloaded.owner_id == owner_id
      assert reloaded.object_key == ref.object_key
      assert reloaded.sha256 == expected_sha
      assert reloaded.size_bytes == byte_size("PDFBYTES")
      assert reloaded.kind == "source_upload"
    end

    test "works with the LiveView-style upload-info map", %{bypass: bypass} do
      Bypass.expect_once(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      tmp = write_tempfile("DATA")

      # LiveView-style upload-info maps have no owner — provide one via
      # ctx because `owner_id` is required by the W1 changeset.
      owner_id = Ecto.UUID.generate()
      ctx = %Context{user: %User{id: owner_id}}

      upload = %{
        path: tmp,
        client_name: "notes.txt",
        client_type: "text/plain",
        client_size: 4
      }

      assert {:ok, %BlobRef{} = ref} = Blobs.put_upload(ctx, upload)
      assert ref.mime_type == "text/plain"
      assert ref.size_bytes == 4
      assert String.ends_with?(ref.object_key, ".txt")
      assert ref.owner_id == owner_id
      assert String.starts_with?(ref.object_key, "uploads/#{owner_id}/")
    end

    test "returns {:error, {:upload_stat_failed, _}} when path is missing" do
      upload = %Plug.Upload{
        path: "/tmp/definitely-not-there-#{System.unique_integer([:positive])}",
        filename: "x",
        content_type: "application/octet-stream"
      }

      assert {:error, {:upload_stat_failed, _}} = Blobs.put_upload(nil, upload)
    end
  end

  describe "get/2 + delete/2 accept BlobRef, map, or raw key" do
    test "get/2 reads via BlobRef.object_key", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/uploads/x/y.pdf", fn conn ->
        Plug.Conn.resp(conn, 200, "BODY")
      end)

      ref = %BlobRef{object_key: "uploads/x/y.pdf"}
      assert {:ok, "BODY"} = Blobs.get(nil, ref)
    end

    test "get/2 reads via raw key string", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/test-bucket/k", fn conn ->
        Plug.Conn.resp(conn, 200, "X")
      end)

      assert {:ok, "X"} = Blobs.get(nil, "k")
    end

    test "delete/2 removes the object", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/test-bucket/k", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = Blobs.delete(nil, %BlobRef{object_key: "k"})
    end
  end

  describe "signed_url/3" do
    test "returns a presigned URL for a BlobRef" do
      assert {:ok, url} = Blobs.signed_url(nil, %BlobRef{object_key: "exports/abc.pdf"})
      assert is_binary(url)
      assert url =~ "/test-bucket/exports/abc.pdf"
      assert url =~ "X-Amz-Signature="
    end

    test "honors :expires_in" do
      assert {:ok, url} = Blobs.signed_url(nil, "k", expires_in: 120)
      assert url =~ "X-Amz-Expires=120"
    end
  end

  defp write_tempfile(contents) do
    path = Path.join(System.tmp_dir!(), "blobs-test-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end
end
