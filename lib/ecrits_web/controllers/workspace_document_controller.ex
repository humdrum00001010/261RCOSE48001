defmodule EcritsWeb.WorkspaceDocumentController do
  @moduledoc """
  Streams the raw bytes of a local workspace document to the browser so an
  in-browser WASM engine can render + edit it on a `<canvas>`:

    * HWP/HWPX -> rhwp_core (`new HwpDocument(bytes)`)
    * docx/pptx/xlsx (office) -> LibreOffice WASM (`loadFromBytes(bytes)`)

  The server stays the source of truth for the bytes (persistence); the browser
  owns render/hit-test/edit.

  Two resources, deliberately separate so their cache policies can be honest:

    * `bytes/2` — live bytes from disk, `no-store`
    * `snapshot/2` — a pinned preview, content-addressed, `immutable`

  Gating for `bytes/2`: `Document.open_args/2` rejects traversal, confirms the
  file is a regular file INSIDE the workspace root, and confirms a supported
  format. Note the root itself is CALLER-SUPPLIED, so confinement is relative to
  whatever root the request names — the route will not escape that root, but it
  does not choose it. See `EcritsWeb.DocumentUrl` for the URL shapes.
  """

  use EcritsWeb, :controller

  alias Ecrits.Document
  alias Ecrits.Document.PreviewSnapshot

  # The glob delivers the document as PATH SEGMENTS. Join them and hand the
  # result to `Document.open_args/2` — never `Path.join(root, segments)`, which
  # skips every guard.
  def bytes(conn, %{"document" => segments, "path" => workspace_path})
      when is_list(segments) and is_binary(workspace_path) do
    relative_path = Enum.join(segments, "/")

    with {:ok, args} <- Document.open_args(workspace_path, relative_path),
         path = Keyword.fetch!(args, :path),
         format = Keyword.fetch!(args, :format),
         true <- Document.ehwp_format?(format) or Document.libreoffice_format?(format),
         {:ok, bytes} <- File.read(path) do
      conn
      |> put_resp_content_type(Document.content_type(format))
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, maybe_flatten_pptx(format, bytes))
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def bytes(conn, _params), do: send_resp(conn, 400, "")

  # A pinned preview keeps serving the bytes AS THEY WERE at edit time, after
  # the source file has moved on.
  def snapshot(conn, %{"document_id" => document_id, "id" => id})
      when is_binary(document_id) and is_binary(id) do
    with {:ok, bytes} <- PreviewSnapshot.fetch(document_id, id),
         {:ok, format} <- Document.detect_format_from_bytes(bytes),
         true <- Document.ehwp_format?(format) or Document.libreoffice_format?(format) do
      body = maybe_flatten_pptx(format, bytes)

      conn
      |> put_resp_content_type(Document.content_type(format))
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      # Tag the BODY: `maybe_flatten_pptx/2` may rewrite it, and is fail-safe,
      # so one `id` can yield either version.
      |> put_resp_header("etag", ~s("#{Document.sha256(body)}"))
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def snapshot(conn, _params), do: send_resp(conn, 400, "")

  # pptx "build" slides animate overlapping shapes; the static WASM viewer paints
  # all build states at once → ghosted glyphs (#57 D). Serve the animation
  # final-state for VIEWING. Fail-safe: any error serves the original bytes.
  defp maybe_flatten_pptx("pptx", bytes) do
    case Ecrits.Doc.PptxFlatten.flatten_animations(bytes) do
      {:ok, flattened} -> flattened
      _ -> bytes
    end
  end

  defp maybe_flatten_pptx(_format, bytes), do: bytes
end
