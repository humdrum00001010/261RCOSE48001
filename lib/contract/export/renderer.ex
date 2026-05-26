defmodule Contract.Export.Renderer do
  @moduledoc """
  Stateless format dispatcher for in-memory export rendering.
  """

  alias Contract.Runtime.State

  @spec render(map()) :: {:ok, binary(), String.t()} | {:error, term()}
  def render(%{document_id: id, format: format}) do
    body = "EXPORT-STUB document=#{id} format=#{format}"
    content_type = content_type(format)
    {:ok, body, content_type}
  end

  @spec render(State.t(), atom(), keyword()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def render(state, format, opts \\ [])

  def render(%State{} = state, :hwpx, opts) do
    case Contract.Export.HWPX.render(state, opts) do
      {:ok, body} -> {:ok, body, content_type(:hwpx)}
      {:error, _} = err -> err
    end
  end

  def render(%State{} = state, :html, opts) do
    case Contract.Export.HTML.render(state, opts) do
      {:ok, body} -> {:ok, body, content_type(:html)}
      {:error, _} = err -> err
    end
  end

  def render(%State{} = state, :markdown, opts) do
    case Contract.Export.Markdown.render(state, opts) do
      {:ok, body} -> {:ok, body, content_type(:markdown)}
      {:error, _} = err -> err
    end
  end

  def render(%State{} = state, :md, opts), do: render(state, :markdown, opts)

  def render(%State{} = state, :lawyer_packet, opts) do
    case Contract.Export.LawyerPacket.render(state, opts) do
      {:ok, body} -> {:ok, body, content_type(:lawyer_packet)}
      {:error, _} = err -> err
    end
  end

  def render(%State{} = state, :pdf, opts) do
    case Contract.Export.PDF.render(state, opts) do
      {:ok, body} -> {:ok, body, content_type(:pdf)}
      {:error, _} = err -> err
    end
  end

  def render(%State{} = state, :docx, opts) do
    case Contract.Export.DOCX.render(state, opts) do
      {:ok, body} -> {:ok, body, content_type(:docx)}
      {:error, _} = err -> err
    end
  end

  def render(_state, format, _opts) do
    {:error, {:unsupported_format, format}}
  end

  @spec content_type(atom()) :: String.t()
  def content_type(:pdf), do: "application/pdf"

  def content_type(:docx),
    do: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  def content_type(:html), do: "text/html; charset=utf-8"
  def content_type(:md), do: "text/markdown"
  def content_type(:markdown), do: "text/markdown"
  def content_type(:lawyer_packet), do: "text/markdown"
  def content_type(:hwpx), do: "application/hwp+zip"
  def content_type(_), do: "application/octet-stream"
end
