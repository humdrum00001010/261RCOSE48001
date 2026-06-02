defmodule Ecrits.Export.HTML do
  @moduledoc """
  Deterministic HTML5 renderer for a `Ecrits.Runtime.State`.

  Walks `state.projection.node_order` and emits one HTML element per
  top-level node, using `state.projection.nodes` as the lookup map.

  ## Supported node kinds

      :paragraph   →  <p>{content}</p>
      :heading     →  <h{level}>{content}</h{level}>  (level clamped 1..6)
      :list        →  <ul>{<li>...</li>...}</ul>
      :list_item   →  <li>{content}</li>          (children of :list)
      :table       →  <table><tbody><tr>...</tr></tbody></table>
      :cell        →  emitted from inside :table; bare :cell is a no-op
      :section     →  <section>{content}</section>
      :field_ref   →  inline <span data-field-id="..."> with resolved value
      _other       →  <p>{content}</p>  (SPEC §15 — kinds are opaque atoms)

  ## Determinism

  No timestamps, no random IDs, no escaping that depends on env locale.
  The same projection produces byte-identical output across invocations
  and machines.

  ## UTF-8

  HTML body is emitted as raw UTF-8 bytes; the `<meta charset="utf-8">`
  in the head matches. Korean (or any other non-ASCII) content
  round-trips byte-exact because the only entity substitutions are the
  five XML predefined entities.
  """

  alias Ecrits.Runtime.State

  @doctype "<!doctype html>\n"

  @style """
  <style>
    @page { margin: 24mm 20mm; }
    body { font-family: "Inter", "Pretendard", "Apple SD Gothic Neo", sans-serif; line-height: 1.65; color: #1a1a1a; margin: 0; }
    .ecrits-body { max-width: 64rem; margin: 0 auto; padding: 1rem; }
    h1 { font-size: 1.75rem; font-weight: 600; margin-top: 1.6em; }
    h2 { font-size: 1.5rem; font-weight: 600; margin-top: 1.4em; }
    h3 { font-size: 1.25rem; font-weight: 600; }
    p { margin: 0.8em 0; }
    ul, ol { padding-left: 1.5em; }
    section { margin: 1em 0; }
    table { border-collapse: collapse; width: 100%; margin: 1em 0; }
    th, td { border: 1px solid #d4d4d4; padding: 0.5em 0.75em; vertical-align: top; }
    .field-ref { background: #f7f7f7; padding: 0 0.2em; border-radius: 2px; }
  </style>
  """

  @spec render(State.t() | map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(state_or_projection, opts \\ [])

  def render(%State{projection: projection}, opts), do: render(projection, opts)

  def render(projection, _opts) when is_map(projection) do
    try do
      title = projection |> Map.get(:title) |> to_text()
      title = if title == "", do: "Untitled", else: title
      body = render_projection(projection)

      html =
        @doctype <>
          ~s(<html lang="ko">\n) <>
          "<head>\n" <>
          ~s(<meta charset="utf-8">\n) <>
          "<title>" <>
          escape_html(title) <>
          "</title>\n" <>
          @style <>
          "</head>\n" <>
          ~s(<body>\n) <>
          ~s(<main class="contract-body">\n) <>
          ~s(<h1 class="contract-title">) <>
          escape_html(title) <>
          "</h1>\n" <>
          body <>
          "\n</main>\n</body>\n</html>\n"

      {:ok, html}
    rescue
      e -> {:error, {:html_render_failed, Exception.message(e)}}
    end
  end

  # --------------------------------------------------------------------
  # projection walk
  # --------------------------------------------------------------------

  defp render_projection(projection) do
    nodes = Map.get(projection, :nodes, %{})
    order = Map.get(projection, :node_order, [])

    order
    |> Enum.map(&render_node(&1, nodes, projection))
    |> Enum.join("\n")
  end

  defp render_node(id, nodes, projection) do
    case Map.fetch(nodes, id) do
      :error -> ""
      {:ok, node} -> render_kind(Map.get(node, :kind, :paragraph), node, nodes, projection)
    end
  end

  defp render_kind(:paragraph, node, _nodes, projection) do
    "<p>" <> escape_html(collect_text(node, projection)) <> "</p>"
  end

  defp render_kind(:heading, node, _nodes, projection) do
    level = node |> Map.get(:attrs, %{}) |> Map.get(:level, 2) |> clamp(1, 6)
    text = collect_text(node, projection)
    "<h#{level}>" <> escape_html(text) <> "</h#{level}>"
  end

  defp render_kind(:list, node, nodes, projection) do
    children = Map.get(node, :children, [])

    items =
      children
      |> Enum.map(fn child_id -> render_list_item(child_id, nodes, projection) end)
      |> Enum.join("")

    "<ul>" <> items <> "</ul>"
  end

  defp render_kind(:list_item, node, _nodes, projection) do
    # Top-level :list_item (unusual) — render as a single-item <ul>.
    "<ul><li>" <> escape_html(collect_text(node, projection)) <> "</li></ul>"
  end

  defp render_kind(:table, node, nodes, projection) do
    cols = node |> Map.get(:attrs, %{}) |> Map.get(:cols) || fallback_cols(node, nodes)
    cols = max(1, cols)
    cell_ids = Map.get(node, :children, [])

    rows =
      cell_ids
      |> Enum.chunk_every(cols, cols, [])
      |> Enum.map(fn row_cells -> render_table_row(row_cells, cols, nodes, projection) end)
      |> Enum.join("")

    "<table><tbody>" <> rows <> "</tbody></table>"
  end

  defp render_kind(:cell, _node, _nodes, _projection) do
    # Bare :cell at top level produces nothing (structural error).
    ""
  end

  defp render_kind(:section, node, nodes, projection) do
    text = collect_text(node, projection)
    children = Map.get(node, :children, [])

    inner =
      cond do
        children != [] ->
          children
          |> Enum.map(&render_node(&1, nodes, projection))
          |> Enum.join("")

        true ->
          if text == "", do: "", else: "<p>" <> escape_html(text) <> "</p>"
      end

    "<section>" <> inner <> "</section>"
  end

  defp render_kind(:field_ref, node, _nodes, projection) do
    field_id = node |> Map.get(:attrs, %{}) |> Map.get(:field_id) |> to_text()
    text = resolve_field_text(node, projection)

    ~s(<p><span class="field-ref" data-field-id=") <>
      escape_html(field_id) <>
      ~s(">) <>
      escape_html(text) <>
      "</span></p>"
  end

  defp render_kind(_other, node, _nodes, projection) do
    # SPEC §15: node kinds are opaque atoms — render unknowns as paragraphs.
    "<p>" <> escape_html(collect_text(node, projection)) <> "</p>"
  end

  defp render_list_item(child_id, nodes, projection) do
    case Map.fetch(nodes, child_id) do
      {:ok, child} ->
        "<li>" <> escape_html(collect_text(child, projection)) <> "</li>"

      :error ->
        ""
    end
  end

  defp render_table_row(row_cell_ids, cols, nodes, projection) do
    padded =
      (row_cell_ids ++ List.duplicate(nil, max(0, cols - length(row_cell_ids))))
      |> Enum.take(cols)

    cells =
      padded
      |> Enum.map(fn
        nil ->
          "<td></td>"

        id ->
          case Map.fetch(nodes, id) do
            {:ok, cell} -> "<td>" <> escape_html(collect_text(cell, projection)) <> "</td>"
            :error -> "<td></td>"
          end
      end)
      |> Enum.join("")

    "<tr>" <> cells <> "</tr>"
  end

  defp fallback_cols(node, nodes) do
    cell_count =
      Map.get(node, :children, [])
      |> Enum.count(fn cid ->
        case Map.fetch(nodes, cid) do
          {:ok, c} -> Map.get(c, :kind) == :cell
          :error -> false
        end
      end)

    cond do
      cell_count == 0 -> 1
      true -> max(1, trunc(:math.sqrt(cell_count)))
    end
  end

  # --------------------------------------------------------------------
  # helpers
  # --------------------------------------------------------------------

  defp collect_text(%{kind: :field_ref} = node, projection),
    do: resolve_field_text(node, projection)

  defp collect_text(node, _projection) do
    node |> Map.get(:content) |> to_text()
  end

  defp resolve_field_text(node, projection) do
    field_id = node |> Map.get(:attrs, %{}) |> Map.get(:field_id)

    case field_id do
      nil ->
        ""

      id ->
        projection
        |> Map.get(:fields, %{})
        |> Map.get(id, %{})
        |> Map.get(:value)
        |> to_text()
    end
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, _), do: lo

  defp to_text(nil), do: ""
  defp to_text(s) when is_binary(s), do: s
  defp to_text(other), do: to_string(other)

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape_html(other), do: escape_html(to_text(other))
end
