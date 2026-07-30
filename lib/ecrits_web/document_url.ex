defmodule EcritsWeb.DocumentUrl do
  @moduledoc """
  URLs for the two document routes in `EcritsWeb.Router`.

  These are the counterpart of the route declarations, not view logic, and they
  are the only place that knows how a document path is encoded into a URL. They
  live here rather than in `WorkspaceLive` so a test can call them: the builder
  and the router drifted apart once already (the builder emitted `/document/…`
  while the route was `/document/bytes/…`, so every viewer 404'd), and the
  LiveView tests missed it because they asserted a SUBSTRING of the broken URL
  rather than that the produced URL routes.
  """

  alias Ecrits.Document

  @doc """
  Live bytes: `GET /document/bytes/*document?path=<workspace root>`.

  `nil` for non-binary input, so callers can pipe an absent document straight
  through.
  """
  @spec bytes(String.t(), String.t(), term()) :: String.t() | nil
  def bytes(workspace_path, relative_path, version \\ nil)

  def bytes(workspace_path, relative_path, version)
      when is_binary(workspace_path) and is_binary(relative_path) do
    query =
      case version do
        nil -> %{"path" => workspace_path}
        v -> %{"path" => workspace_path, "v" => to_string(v)}
      end

    "/document/bytes/" <> encode_path(relative_path) <> "?" <> URI.encode_query(query)
  end

  def bytes(_workspace_path, _relative_path, _version), do: nil

  @doc """
  A pinned preview: `GET /document/snapshot/:document_id/:id`.

  Content-addressed, so it needs neither the workspace root nor the relative
  path — which is what lets the response be cached immutably, unlike `bytes/3`.
  """
  @spec snapshot(String.t(), String.t(), String.t()) :: String.t() | nil
  def snapshot(workspace_path, relative_path, snapshot_id)
      when is_binary(workspace_path) and is_binary(relative_path) and is_binary(snapshot_id) do
    # No encoding: `document_id` is `local-` + url-base64 and `snapshot_id` is
    # lowercase hex (both pinned by regex in `Ecrits.Document.PreviewSnapshot`),
    # so every character is already unreserved.
    "/document/snapshot/" <> Document.id_for(workspace_path, relative_path) <> "/" <> snapshot_id
  end

  def snapshot(_workspace_path, _relative_path, _snapshot_id), do: nil

  # Per SEGMENT, so a "/" inside a filename cannot forge a new one. Not
  # `encode_www_form/1`: it maps SPACE to "+", and a glob path param is decoded
  # with `URI.decode/1`, which leaves "+" literal — so "년간 보고서.hwpx" arrived
  # as "년간+보고서.hwpx" and 404'd. The old query-string form was decoded by
  # `Plug.Conn.Query`, which does undo "+", which is why moving the document
  # into the path introduced this.
  defp encode_path(relative_path) do
    relative_path
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end
end
