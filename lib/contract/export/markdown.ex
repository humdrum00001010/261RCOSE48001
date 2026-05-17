defmodule Contract.Export.Markdown do
  @moduledoc """
  Deterministic Markdown renderer for a `Contract.Runtime.State` projection.
  """

  alias Contract.Runtime.State

  @spec render(State.t() | map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(state_or_projection, opts \\ [])

  def render(%State{projection: projection}, opts), do: render(projection, opts)

  def render(projection, _opts) when is_map(projection) do
    try do
      title = projection |> Map.get(:title) |> to_text() |> blank_to("Untitled")
      body = render_projection(projection)

      markdown =
        ["# " <> title, body]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
        |> then(&(&1 <> "\n"))

      {:ok, markdown}
    rescue
      e -> {:error, {:markdown_render_failed, Exception.message(e)}}
    end
  end

  defp render_projection(projection) do
    nodes = Map.get(projection, :nodes, %{})
    order = Map.get(projection, :node_order, [])

    order
    |> Enum.map(&render_node(&1, nodes, projection))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp render_node(id, nodes, projection) do
    case Map.fetch(nodes, id) do
      {:ok, node} -> render_kind(Map.get(node, :kind, :paragraph), node, nodes, projection)
      :error -> ""
    end
  end

  defp render_kind(:heading, node, _nodes, projection) do
    level = node |> Map.get(:attrs, %{}) |> Map.get(:level, 2) |> clamp(1, 6)
    String.duplicate("#", level) <> " " <> collect_text(node, projection)
  end

  defp render_kind(:paragraph, node, _nodes, projection), do: collect_text(node, projection)

  defp render_kind(:section, node, nodes, projection) do
    children = Map.get(node, :children, [])

    if children == [] do
      collect_text(node, projection)
    else
      children
      |> Enum.map(&render_node(&1, nodes, projection))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
    end
  end

  defp render_kind(:list, node, nodes, projection) do
    node
    |> Map.get(:children, [])
    |> Enum.map(fn child_id -> "- " <> list_item_text(child_id, nodes, projection) end)
    |> Enum.reject(&(&1 == "- "))
    |> Enum.join("\n")
  end

  defp render_kind(:list_item, node, _nodes, projection),
    do: "- " <> collect_text(node, projection)

  defp render_kind(:table, node, nodes, projection) do
    cols = node |> Map.get(:attrs, %{}) |> Map.get(:cols) || fallback_cols(node, nodes)
    cols = max(1, cols)

    rows =
      node
      |> Map.get(:children, [])
      |> Enum.chunk_every(cols, cols, [])
      |> Enum.map(fn row ->
        cells =
          row
          |> Enum.map(&cell_text(&1, nodes, projection))
          |> pad_cells(cols)

        "| " <> Enum.join(cells, " | ") <> " |"
      end)

    case rows do
      [] -> ""
      [header | rest] -> Enum.join([header, separator(cols) | rest], "\n")
    end
  end

  defp render_kind(:cell, _node, _nodes, _projection), do: ""
  defp render_kind(:field_ref, node, _nodes, projection), do: resolve_field_text(node, projection)
  defp render_kind(_other, node, _nodes, projection), do: collect_text(node, projection)

  defp list_item_text(child_id, nodes, projection) do
    case Map.fetch(nodes, child_id) do
      {:ok, child} -> collect_text(child, projection)
      :error -> ""
    end
  end

  defp cell_text(child_id, nodes, projection) do
    case Map.fetch(nodes, child_id) do
      {:ok, child} -> collect_text(child, projection) |> String.replace("|", "\\|")
      :error -> ""
    end
  end

  defp separator(cols), do: "| " <> Enum.join(List.duplicate("---", cols), " | ") <> " |"

  defp pad_cells(cells, cols), do: (cells ++ List.duplicate("", cols)) |> Enum.take(cols)

  defp fallback_cols(node, nodes) do
    count =
      node
      |> Map.get(:children, [])
      |> Enum.count(fn id -> match?(%{kind: :cell}, Map.get(nodes, id, %{})) end)

    if count == 0, do: 1, else: max(1, trunc(:math.sqrt(count)))
  end

  defp collect_text(%{kind: :field_ref} = node, projection),
    do: resolve_field_text(node, projection)

  defp collect_text(node, _projection), do: node |> Map.get(:content) |> to_text()

  defp resolve_field_text(node, projection) do
    field_id = node |> Map.get(:attrs, %{}) |> Map.get(:field_id)

    projection
    |> Map.get(:fields, %{})
    |> Map.get(field_id, %{})
    |> Map.get(:value)
    |> to_text()
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, _hi), do: lo

  defp blank_to("", fallback), do: fallback
  defp blank_to(text, _fallback), do: text

  defp to_text(nil), do: ""
  defp to_text(s) when is_binary(s), do: s
  defp to_text(other), do: to_string(other)
end
