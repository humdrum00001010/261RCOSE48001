defmodule Contract.Export do
  @moduledoc """
  Minimal export record returned by `Contract.IO.export/4`.

  Wave 4 will replace this with a full Oban job (`Contract.Export.Job`).
  For now it carries the four fields callers need post-upload: the export
  id, the R2 key, a presigned download URL, and the format atom.
  """

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          key: String.t(),
          url: String.t(),
          format: atom()
        }

  defstruct [:id, :key, :url, :format]
end

defmodule Contract.Export.Renderer do
  @moduledoc """
  Stub renderer. Wave 4 owns the real implementation (DOCX/PDF/HTML/MD).
  Callers may pass `:render_fun` to `Contract.IO.R2.export/4` to override.
  """

  @spec render(map()) :: {:ok, binary(), String.t()} | {:error, term()}
  def render(%{document_id: id, format: format}) do
    body = "EXPORT-STUB document=#{id} format=#{format}"
    content_type = content_type(format)
    {:ok, body, content_type}
  end

  defp content_type(:pdf), do: "application/pdf"

  defp content_type(:docx),
    do: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  defp content_type(:html), do: "text/html"
  defp content_type(:md), do: "text/markdown"
  defp content_type(:markdown), do: "text/markdown"
  defp content_type(_), do: "application/octet-stream"
end
