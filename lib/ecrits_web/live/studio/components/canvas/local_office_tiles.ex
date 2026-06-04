defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalOfficeTiles do
  @moduledoc """
  Local Microsoft Office document page stack rendered by LibreOffice.

  Each slide/page is its own correctly-sized page box. The page's raster tiles
  are placed absolutely at their `(x, y, width, height)` inside that box so they
  compose without overlap. Pages are virtualized: only near-viewport pages carry
  their (heavy base64 PNG) tiles in the DOM; the rest stay lightweight,
  box-reserving placeholders that hydrate on scroll (see the `LazyOfficeTile`
  hook). This keeps each LiveView diff small so a 1000-tile deck never overflows
  the socket frame.
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
      class="relative h-full min-h-0 overflow-auto bg-base-200"
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
        id={"#{@id}-pages"}
        data-role="local-office-pages"
        class="flex min-h-full flex-col items-center gap-4"
        phx-update="stream"
      >
        <figure
          :for={{dom_id, page} <- @tiles}
          id={dom_id}
          class="relative m-0 max-w-full overflow-hidden border border-base-300 bg-white shadow-sm"
          data-role="local-office-page"
          data-page-number={page.page}
          phx-hook="LazyOfficeTile"
          style={page_box_style(page)}
        >
          <%!-- Only a page that has at least one of ITS OWN tiles renders images.
                A hydrated-but-tileless page (and any placeholder) renders the blank
                box-reserving fill instead — never an ambiguous empty <figure> that
                could borrow another slot's pixels or collapse its reserved box. An
                empty list is NOT truthy here on purpose (it means "no tiles yet"). --%>
          <%= if match?([_ | _], page[:tiles]) do %>
            <img
              :for={tile <- page.tiles}
              src={tile_src(tile)}
              alt={"Page #{page.page}"}
              width={tile.width}
              height={tile.height}
              class="absolute block max-w-none"
              style={tile_style(tile)}
            />
          <% else %>
            <div class="absolute inset-0 bg-base-100" aria-hidden="true"></div>
          <% end %>
        </figure>
      </div>
    </div>
    """
  end

  # Each page reserves its raster box; max-width caps it to the viewport while
  # aspect-ratio keeps the height proportional, so placeholders occupy the same
  # space the hydrated tiles will.
  defp page_box_style(%{page_width: w, page_height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: "width:#{w}px;max-width:100%;aspect-ratio:#{w} / #{h}"

  defp page_box_style(_), do: nil

  # Tiles position as a percentage of the page so they stay glued when the page
  # box is scaled down to fit the viewport (the page box's aspect-ratio + the
  # img's percentage geometry scale together).
  defp tile_style(%{x: x, y: y, width: w, height: h} = tile) do
    {pw, ph} = page_dims(tile)

    "left:#{pct(x, pw)}%;top:#{pct(y, ph)}%;width:#{pct(w, pw)}%;height:#{pct(h, ph)}%"
  end

  defp page_dims(%{page_width: pw, page_height: ph})
       when is_integer(pw) and is_integer(ph) and pw > 0 and ph > 0,
       do: {pw, ph}

  defp page_dims(_tile), do: {1240, 1754}

  defp pct(_value, total) when total <= 0, do: 0
  defp pct(value, total), do: Float.round(value / total * 100, 4)

  # The data URI is precomputed once when the tile arrives (see
  # `tile_data_uri/1` in the LiveView) so re-streaming a page during the cold
  # render burst is a string copy, not a fresh base64 encode of every tile.
  defp tile_src(%{src: src}) when is_binary(src) and src != "", do: src

  # Backward-compatible fallback for any tile still carrying raw PNG bytes.
  defp tile_src(%{data: data}) when is_binary(data) and byte_size(data) > 0 do
    "data:image/png;base64," <> Base.encode64(data)
  end

  defp tile_src(_tile), do: ""
end
