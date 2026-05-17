defmodule ContractWeb.ExportDownloadController do
  use ContractWeb, :controller

  alias Contract.Exports

  def show(conn, %{"export_id" => export_id}) do
    with {:ok, export} <- Exports.get_ready_for_download(conn.assigns.current_scope, export_id),
         key when is_binary(key) <- export.key,
         {:ok, body} <- r2_driver().get(key) do
      conn
      |> put_resp_content_type(export.content_type || "application/octet-stream")
      |> put_resp_header("content-disposition", content_disposition(export))
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp content_disposition(export) do
    ~s(attachment; filename="#{export_filename(export)}")
  end

  defp export_filename(%{id: id, format: format}) do
    "contract-export-#{id}.#{extension(format)}"
  end

  defp extension(:pdf), do: "pdf"
  defp extension(:docx), do: "docx"
  defp extension(:hwpx), do: "hwpx"
  defp extension(:lawyer_packet), do: "md"
  defp extension(:markdown), do: "md"
  defp extension(_), do: "bin"

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end
end
