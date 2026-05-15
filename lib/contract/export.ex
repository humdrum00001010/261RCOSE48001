defmodule Contract.Export do
  @moduledoc """
  Minimal export record returned by `Contract.IO.export/4` and by the
  asynchronous `Contract.Workers.ExportJob` (Wave 4).

  ## Fields

    * `:id` — synthetic UUID for the export.
    * `:document_id` — source document.
    * `:format` — `:hwpx | :html | :pdf | :docx | :md`.
    * `:key` — R2 storage key (e.g. `exports/<uuid>.pdf`).
    * `:url` — presigned download URL.
    * `:requester_id` — actor that triggered the export (for PubSub fan-out).

  `:document_id` and `:requester_id` are populated by the async ExportJob
  path; the synchronous `Contract.IO.R2.export/4` path (carried over from
  earlier waves) leaves them `nil` because its caller passes them out of
  band.
  """

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          document_id: Ecto.UUID.t() | nil,
          key: String.t() | nil,
          url: String.t() | nil,
          format: atom() | nil,
          requester_id: Ecto.UUID.t() | nil
        }

  defstruct [:id, :document_id, :key, :url, :format, :requester_id]
end

defmodule Contract.Export.Renderer do
  @moduledoc """
  Format dispatcher.

  Two entry points:

    * `render/1` — legacy 1-arg shape used by `Contract.IO.R2.export/4`'s
      default render_fun. Returns the stub body for non-:hwpx formats so
      the upload path stays exercised by tests that don't hand off a
      `Runtime.State`.

    * `render/3` — typed entry point: takes a `Contract.Runtime.State`,
      a format atom, and opts. Dispatches to the matching format module
      (HWPX / HTML / PDF / DOCX). This is what the async ExportJob path
      and any caller-with-state-in-hand should use.
  """

  alias Contract.Runtime.State

  @doc """
  Legacy 1-arg renderer. Returns `{:ok, body, content_type}` for the
  stub formats. Kept for callers (notably `Contract.IO.R2.export/4`'s
  default `:render_fun`) that lack a `%Runtime.State{}` in scope.
  """
  @spec render(map()) :: {:ok, binary(), String.t()} | {:error, term()}
  def render(%{document_id: id, format: format}) do
    body = "EXPORT-STUB document=#{id} format=#{format}"
    content_type = content_type(format)
    {:ok, body, content_type}
  end

  @doc """
  Typed entry point: dispatches a `%Contract.Runtime.State{}` to the
  matching format module.
  """
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

  @doc "Content-type for a given export format."
  @spec content_type(atom()) :: String.t()
  def content_type(:pdf), do: "application/pdf"

  def content_type(:docx),
    do: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  def content_type(:html), do: "text/html; charset=utf-8"
  def content_type(:md), do: "text/markdown"
  def content_type(:markdown), do: "text/markdown"
  def content_type(:hwpx), do: "application/hwp+zip"
  def content_type(_), do: "application/octet-stream"
end
