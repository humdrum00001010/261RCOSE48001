defmodule Contract.Export do
  @moduledoc """
  Persisted export request and delivery record.

  Export rows are created synchronously when a user requests an export.
  `Contract.Workers.ExportJob` then renders the artifact, stores it under
  `key`, and marks the row ready with an authenticated download URL.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @formats [:pdf, :hwpx, :docx, :markdown, :lawyer_packet]
  @statuses [:queued, :running, :ready, :failed]

  schema "exports" do
    field :document_id, :binary_id
    field :requester_id, :binary_id

    field :format, Ecto.Enum, values: @formats
    field :status, Ecto.Enum, values: @statuses, default: :queued
    field :progress, :integer, default: 0

    field :key, :string
    field :download_url, :string
    field :url, :string, virtual: true
    field :content_type, :string
    field :byte_size, :integer
    field :error, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          document_id: Ecto.UUID.t() | nil,
          key: String.t() | nil,
          download_url: String.t() | nil,
          url: String.t() | nil,
          format: atom() | nil,
          requester_id: Ecto.UUID.t() | nil,
          status: atom() | nil,
          progress: non_neg_integer() | nil,
          content_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          error: map() | nil
        }

  @doc false
  def changeset(export, attrs) do
    export
    |> cast(attrs, [
      :document_id,
      :requester_id,
      :format,
      :status,
      :progress,
      :key,
      :download_url,
      :content_type,
      :byte_size,
      :error,
      :metadata
    ])
    |> validate_required([:document_id, :format, :status, :progress])
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end

defmodule Contract.Export.Renderer do
  @moduledoc """
  Format dispatcher.

  `render/3` is the typed export path used by the async worker. `render/1`
  remains as a legacy test/storage helper for callers that only have a
  document id and format payload.
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
