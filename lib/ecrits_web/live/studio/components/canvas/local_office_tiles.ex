defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalOfficeTiles do
  @moduledoc """
  Local Microsoft Office document tile stack rendered by LibreOffice.
  """

  use EcritsWeb, :html

  attr :id, :string, required: true
  attr :tiles, :any, required: true
  attr :page_count, :integer, default: 0
  attr :document_id, :string, required: true
  attr :local_document_format, :string, required: true
  attr :local_document_revision, :integer, required: true
  attr :loading?, :boolean, default: false

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative h-full min-h-0 overflow-auto bg-white"
      data-component="canvas-local-office-tiles"
      data-renderer="libreofficex-png-tiles"
      data-role="local-office-viewer"
      data-local-document-id={@document_id}
      data-local-document-format={@local_document_format}
      data-local-document-revision={@local_document_revision}
      data-office-page-count={@page_count}
    >
      <div
        :if={@loading?}
        id={"#{@id}-loading"}
        data-role="local-office-loading"
        class="border-b border-base-300 bg-base-100 px-5 py-2 text-sm text-base-content/60"
      >
        Rendering document...
      </div>

      <div
        id={"#{@id}-tiles"}
        data-role="local-office-tiles"
        class="flex min-h-full flex-wrap content-start gap-2 bg-base-200 p-5"
        phx-update="stream"
      >
        <figure
          :for={{dom_id, tile} <- @tiles}
          id={dom_id}
          class="m-0 overflow-hidden border border-base-300 bg-white"
          data-role="local-office-tile"
          data-page-number={tile.page}
          data-tile-x={tile.x}
          data-tile-y={tile.y}
          data-tile-width={tile.width}
          data-tile-height={tile.height}
        >
          <img
            src={tile_src(tile)}
            alt={"Page #{tile.page}"}
            width={tile.width}
            height={tile.height}
            class="block max-w-full"
          />
        </figure>
      </div>
    </div>
    """
  end

  defp tile_src(%{data: data}) when is_binary(data) do
    "data:image/png;base64," <> Base.encode64(data)
  end

  defp tile_src(_tile), do: ""
end
