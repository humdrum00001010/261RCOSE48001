defmodule EcritsWeb.LocalDocumentBytesController do
  @moduledoc """
  Streams the raw bytes of a local workspace HWP/HWPX document to the browser so
  the in-browser rhwp_core WASM engine can `new HwpDocument(bytes)` and render +
  hit-test locally on a `<canvas>`. The server stays the source of truth for the
  bytes (persistence); the browser owns render/hit-test/edit.

  Gating: the request carries the workspace root `path` and the document
  `document` relative path. Both are validated through `Document.open_args/3`,
  which normalizes the relative path (rejecting traversal), confirms it resolves
  to a regular file INSIDE the workspace root, and confirms the file is a
  supported HWP/HWPX format by magic bytes. Anything else is a 404 — this route
  never serves arbitrary filesystem paths.
  """

  use EcritsWeb, :controller

  alias Ecrits.Local.Document

  def show(conn, %{"path" => workspace_path, "document" => relative_path})
      when is_binary(workspace_path) and is_binary(relative_path) do
    with {:ok, args} <- Document.open_args(workspace_path, relative_path),
         path = Keyword.fetch!(args, :path),
         format = Keyword.fetch!(args, :format),
         true <- Document.ehwp_format?(format),
         {:ok, bytes} <- File.read(path) do
      conn
      |> put_resp_content_type(Document.content_type(format))
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "")
end
