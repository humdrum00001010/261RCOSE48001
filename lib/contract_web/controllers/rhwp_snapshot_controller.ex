defmodule ContractWeb.RhwpSnapshotController do
  use ContractWeb, :controller

  alias Contract.Documents
  alias Contract.RhwpSnapshot

  def show(conn, %{"document_id" => document_id, "revision" => revision_param}) do
    with {:ok, revision, format} <- parse_revision(revision_param),
         {:ok, _document} <- Documents.get(conn.assigns.current_scope, document_id),
         %RhwpSnapshot.Record{r2_key: key, content_type: content_type} <-
           RhwpSnapshot.get(document_id, revision, format),
         {:ok, body} <- r2_driver().get(key) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("cache-control", "private, max-age=60")
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp parse_revision(value) when is_binary(value) do
    with [revision_text, format] <- String.split(value, ".", parts: 2),
         {:ok, format} <- RhwpSnapshot.normalize_format(format),
         {revision, ""} when revision >= 0 <- Integer.parse(revision_text) do
      {:ok, revision, format}
    else
      _ -> {:error, :invalid_revision}
    end
  end

  defp parse_revision(_), do: {:error, :invalid_revision}

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end
end
