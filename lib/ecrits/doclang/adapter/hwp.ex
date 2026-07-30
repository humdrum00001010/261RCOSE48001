defmodule Doclang.Adapter.Hwp do
  @moduledoc """
  The rhwp (HWP/HWPX) arm of the DocLang seam — the replacement for `Ehwp.Ir`,
  which lived in the deleted `:ehwp` dep.

  Two surfaces live here because the arm has two consumers:

    * **DocLang** — `to_blocks/1` lowers the engine's full-IR element
      enumeration to canonical DocLang blocks, and `bindings/1` keeps the live
      ref for each one so `Doclang.changes/3` can recover it on write-back.
    * **The nested JSONL projection** — `nested_payloads/1`, `expand_node/1` and
      `changes/2`, ported verbatim from `Ehwp.Ir`. That is still the mounted
      format; the DocLang mount lands with Layer 4 (the engine transports), and
      keeping both here means the ref grammar has exactly one home.

  ## Ref grammar (JSON-object positional refs from the element enumerator)

      %{"section"=>S, "paragraph"=>P, "offset"=>O, "length"=>L}     a char run
      %{"section"=>S, "paragraph"=>P, "control"=>C, "type"=>T}      a control (picture/…)
      %{"section"=>S, "paragraph"=>P, "offset"=>O, "cell"=>%{…}}    a char run in a table cell
      %{"section"=>S}                                               a section

  These are distinct from the agent-facing `hwp:s0/p7` strings that
  `Ecrits.Doc.Rhwp.Ref` handles for MCP routing. Because they are purely
  positional and the nested list already encodes the position, `nested_payloads/1`
  COMPACTS them to a bare tuple and drops them from the payload JSON;
  `expand_node/1` is the inverse. Richer/non-positional refs are kept verbatim so
  no semantic addressing is lost.
  """

  import Ecrits.Guards

  @typedoc "A decoded IR element node (string- or atom-keyed map)."
  @type element :: %{optional(term()) => term()}

  # Types the enumerator emits that DocLang has a first-class block for. Every
  # other type becomes a `<group><custom>` — DocLang's own escape hatch for
  # structure it cannot represent (`Block::Custom`), which is why Preserve mode
  # is mandatory.
  @doclang_text_types ~w(paragraph)

  # ── DocLang: engine IR -> canonical blocks ────────────────────────────────

  @doc """
  Lower the live element enumeration to canonical DocLang blocks.

  Sections are NOT delimited in DocLang XML (`writer/mod.rs::write_section`
  writes each section's blocks straight into the root), so the result is one
  flat block list in document order. Table cells are folded back into their
  `<table>`; every node type DocLang has no element for becomes
  `<group><custom><hwp_prop name="ns" value="hwp:TYPE"/>…</custom></group>`.
  """
  @spec to_blocks([element()]) :: [Doclang.block()]
  def to_blocks(nodes) when is_list(nodes) do
    nodes |> build() |> Enum.map(&elem(&1, 0))
  end

  @doc """
  The same lowering as `to_blocks/1`, but each block paired with the live ref
  the ref-less buffer omits. Ordered to match `Doclang.child_blocks/1`.
  """
  @spec bindings([element()]) :: [map()]
  def bindings(nodes) when is_list(nodes) do
    nodes |> build() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The engine ref for `block`, recovered from the live `baseline` nodes.

  Best-effort convenience for single lookups: it matches the FIRST baseline
  block equal to `block`. `Doclang.changes/3` does not use it — its recovery is
  exact, by aligned tree position.
  """
  @spec ref_for(Doclang.block(), [element()] | [map()]) :: term() | nil
  def ref_for(block, baseline) when is_list(baseline) do
    baseline
    |> normalize_baseline()
    |> flatten_bindings()
    |> Enum.find_value(fn binding ->
      if Doclang.shallow(binding.block) == Doclang.shallow(block), do: binding.ref
    end)
  end

  @doc """
  The ref a newly inserted block anchors to: the end of the nearest preceding
  body paragraph, else the start of the next one, else `"end"`.
  """
  @spec insertion_anchor([map()], non_neg_integer()) :: term()
  def insertion_anchor(bindings, index) when is_list(bindings) do
    nodes = Enum.map(bindings, & &1.node) |> Enum.reject(&is_nil/1)
    old_index = min(index, length(nodes))
    ir_insertion_anchor(nodes, old_index)
  end

  defp normalize_baseline([]), do: []
  defp normalize_baseline([%{block: _} | _] = bindings), do: bindings
  defp normalize_baseline(nodes), do: bindings(nodes)

  defp flatten_bindings(bindings) do
    Enum.flat_map(bindings, fn binding ->
      [binding | flatten_bindings(Map.get(binding, :children, []))]
    end)
  end

  # Build `[{block, binding}]` in document order. Both public entry points share
  # this one traversal, so they can never disagree on ordering — which
  # `Doclang.changes/3` relies on when it walks bindings alongside parsed blocks.
  defp build(nodes) do
    nodes
    |> Enum.map(&normalize_ir_value/1)
    |> group_tables()
    |> Enum.map(&entry_to_block/1)
  end

  # A table node followed by its cell nodes is one DocLang `<table>`; everything
  # else passes through as a singleton.
  defp group_tables(nodes) do
    {entries, pending} =
      Enum.reduce(nodes, {[], nil}, fn node, {entries, pending} ->
        case {Map.get(node, "type"), pending} do
          {"table", nil} ->
            {entries, {node, []}}

          {"table", {table, cells}} ->
            {[{:table, table, Enum.reverse(cells)} | entries], {node, []}}

          {"cell", {table, cells}} ->
            {entries, {table, [node | cells]}}

          {_other, {table, cells}} ->
            {[{:node, node} | [{:table, table, Enum.reverse(cells)} | entries]], nil}

          {_other, nil} ->
            {[{:node, node} | entries], nil}
        end
      end)

    entries =
      case pending do
        nil -> entries
        {table, cells} -> [{:table, table, Enum.reverse(cells)} | entries]
      end

    Enum.reverse(entries)
  end

  defp entry_to_block({:table, table, cells}) do
    rows = positive_int(Map.get(table, "rows")) || table_rows_from_cells(cells)
    cols = positive_int(Map.get(table, "cols")) || table_cols_from_cells(cells)

    grouped =
      cells
      |> Enum.with_index()
      |> Enum.group_by(fn {cell, index} -> cell_position(cell, index, cols) end)
      |> Enum.sort_by(fn {{row, col}, _} -> {row, col} end)

    # A grid position with no cell renders as `<ecel/>` (Doclang's `:empty`
    # token), and on the way back in EVERY `ecel` parses as an empty anchor cell
    # — `ecel` cannot distinguish "empty cell" from "hole in the geometry". So a
    # table with holes parsed back to MORE cells than we built, the block counts
    # disagreed, and `Doclang.changes/3` failed the document against ITSELF with
    # `:structural_change` — every edit on such a document, not just one in the
    # table. Materialize the holes here so what we render is exactly what parsing
    # it yields. The XML is unchanged (these already rendered as `<ecel/>`); only
    # the block tree gains the cells the parser was always going to invent.
    # Only a position claimed by NOTHING is a hole. A position covered by a
    # neighbour's span renders as `<lcel/>`/`<ucel/>`/`<xcel/>`, which parse back
    # as COVERS, not cells — materializing those too would overshoot the parser
    # in the other direction. This mirrors `Doclang.claim_cell/5`.
    occupied =
      Enum.reduce(grouped, MapSet.new(), fn {{row, col}, entries}, acc ->
        first = entries |> hd() |> elem(0)
        row_span = positive_int(Map.get(first, "rowSpan")) || 1
        col_span = positive_int(Map.get(first, "colSpan")) || 1

        for r <- row..(row + row_span - 1),
            c <- col..(col + col_span - 1),
            reduce: acc,
            do: (inner -> MapSet.put(inner, {r, c}))
      end)

    holes =
      for row <- 0..(max(rows, 1) - 1),
          col <- 0..(max(cols, 1) - 1),
          not MapSet.member?(occupied, {row, col}),
          do: {{row, col}, :hole}

    grouped = Enum.sort_by(grouped ++ holes, fn {{row, col}, _} -> {row, col} end)

    {cell_blocks, cell_bindings} =
      Enum.reduce(grouped, {[], []}, fn
        {{row, col}, :hole}, {blocks, binds} ->
          # No engine ref: there is no cell to address. An edit here still fails
          # closed as a structural change, which is correct — but a no-op now
          # aligns instead of poisoning the whole document.
          hole = %{
            "row" => row,
            "col" => col,
            "row_span" => 1,
            "col_span" => 1,
            "header" => false,
            "blocks" => []
          }

          {[hole | blocks], binds}

        {{row, col}, entries}, {blocks, binds} ->
          first = entries |> hd() |> elem(0)

          # One IR "cell" node is one paragraph INSIDE a cell (`cellParaIndex`),
          # so several nodes can share a grid position.
          paragraphs =
            Enum.map(entries, fn {cell, _index} ->
              {%{"type" => "text", "text" => node_text(cell)}, cell}
            end)

          cell_block = %{
            "row" => row,
            "col" => col,
            "row_span" => positive_int(Map.get(first, "rowSpan")) || 1,
            "col_span" => positive_int(Map.get(first, "colSpan")) || 1,
            "header" => Map.get(first, "header") == true,
            "blocks" => Enum.map(paragraphs, &elem(&1, 0))
          }

          child_bindings =
            Enum.map(paragraphs, fn {block, cell} ->
              Doclang.binding(block,
                ref: Map.get(cell, "ref"),
                type: "cell",
                cell?: true,
                node: cell
              )
            end)

          {[cell_block | blocks], binds ++ child_bindings}
      end)

    block = %{
      "type" => "table",
      "rows" => max(rows, 1),
      "cols" => max(cols, 1),
      "cells" => Enum.reverse(cell_blocks)
    }

    binding =
      Doclang.binding(block,
        ref: Map.get(table, "ref"),
        type: "table",
        node: table,
        children: cell_bindings
      )

    {block, binding}
  end

  defp entry_to_block({:node, node}) do
    type = Map.get(node, "type")

    cond do
      type in @doclang_text_types ->
        block =
          %{"type" => "text", "text" => node_text(node)}
          |> put_custom(custom_pairs(node, "hwp:style", ~w(ref type text)), false)

        {block, Doclang.binding(block, ref: Map.get(node, "ref"), type: type, node: node)}

      type == "picture" ->
        src = Map.get(node, "src") || Map.get(node, "path")

        block =
          %{"type" => "picture"}
          |> maybe_put("src", src)
          |> put_custom(
            custom_pairs(node, "hwp:picture", ~w(ref type src path bins image_base64)),
            false
          )

        {block, Doclang.binding(block, ref: Map.get(node, "ref"), type: type, node: node)}

      true ->
        block =
          %{"type" => "group"}
          |> put_custom(
            custom_pairs(node, "hwp:" <> to_string(type || "unknown"), ~w(ref type)),
            true
          )

        {block, Doclang.binding(block, ref: Map.get(node, "ref"), type: type, node: node)}
    end
  end

  defp cell_position(cell, index, cols) do
    ref = Map.get(cell, "ref") || %{}
    cell_ref = if is_map(ref), do: Map.get(ref, "cell") || %{}, else: %{}

    row = integer_field(cell, "row")
    col = integer_field(cell, "col")

    cond do
      is_integer(row) and is_integer(col) ->
        {row, col}

      is_integer(Map.get(cell_ref, "cellIndex")) and cols > 0 ->
        cell_index = Map.get(cell_ref, "cellIndex")
        {div(cell_index, cols), rem(cell_index, cols)}

      cols > 0 ->
        {div(index, cols), rem(index, cols)}

      true ->
        {index, 0}
    end
  end

  defp table_rows_from_cells([]), do: 0

  defp table_rows_from_cells(cells) do
    cells
    |> Enum.map(&(integer_field(&1, "row") || 0))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp table_cols_from_cells([]), do: 0

  defp table_cols_from_cells(cells) do
    cells
    |> Enum.map(&(integer_field(&1, "col") || 0))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp node_text(node) do
    case Map.get(node, "text") do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  # Preserve-mode `<custom>`: `ns` first (as `writer/custom.rs` does), then every
  # remaining scalar field of the live node, in a deterministic key order.
  defp custom_pairs(node, namespace, dropped) do
    extra =
      node
      |> Map.drop(dropped)
      |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_boolean(v) end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {k, v} -> [k, to_string(v)] end)

    [["ns", namespace] | extra]
  end

  # A bare `ns` is dropped when the DocLang element already says everything the
  # node kind said (an HWP paragraph IS a `<text>`); it is KEPT when the lowering
  # was lossy (anything flattened to `<group>`), because then `ns` is the only
  # record of what the node really is.
  defp put_custom(block, [["ns", _]], false), do: block
  defp put_custom(block, pairs, _keep_bare_ns?), do: Map.put(block, "custom", pairs)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp integer_field(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  # ── nested JSONL projection (ported verbatim from Ehwp.Ir) ────────────────

  @doc """
  Project the raw IR element list to the nested, position-addressed payload list
  `[section[paragraph[payload]]]`. Each node's positional ref is elided (the list
  position is its address); non-positional refs are kept.
  """
  @spec nested_payloads([element()]) :: [[[element()]]]
  def nested_payloads(nodes) when is_list(nodes), do: do_nested_payloads(nodes)

  @doc """
  Inverse of `nested_payloads/1`'s per-node compaction: re-attach a positional
  ref to a parsed payload node from its compacted tuple. A node with no
  compactable positional ref is returned unchanged, so this is a safe no-op on
  payloads from other engines.
  """
  @spec expand_node(element()) :: element()
  def expand_node(node), do: expand_projected_node(node)

  defp do_nested_payloads(nodes) do
    payload_entries =
      nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, fallback_index} ->
        {section_id, paragraph_id} = node_position(node, fallback_index)
        %{section_id: section_id, paragraph_id: paragraph_id, node: node}
      end)

    section_ids =
      payload_entries
      |> Enum.map(& &1.section_id)
      |> uniq_preserving_order()

    Enum.map(section_ids, fn section_id ->
      section_payloads = Enum.filter(payload_entries, &(&1.section_id == section_id))

      section_payloads
      |> Enum.map(& &1.paragraph_id)
      |> uniq_preserving_order()
      |> Enum.map(fn paragraph_id ->
        section_payloads
        |> Enum.filter(&(&1.paragraph_id == paragraph_id))
        |> Enum.map(fn entry -> projected_node(entry.node) end)
      end)
    end)
  end

  defp uniq_preserving_order(values) do
    values
    |> Enum.reduce({[], MapSet.new()}, fn value, {acc, seen} ->
      if MapSet.member?(seen, value) do
        {acc, seen}
      else
        {[value | acc], MapSet.put(seen, value)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp projected_node(node) do
    node = normalize_ir_value(node)
    type = Map.get(node, "type")

    case compact_positional_ref(Map.get(node, "ref"), type) do
      nil -> node
      _positional_ref -> Map.delete(node, "ref")
    end
  end

  defp compact_positional_ref(%{"cell" => %{} = cell} = ref, _type) do
    with section when is_integer(section) <- Map.get(ref, "section", 0),
         parent_para when is_integer(parent_para) <-
           Map.get(cell, "parentParaIndex", Map.get(ref, "paragraph")),
         control when is_integer(control) <- Map.get(cell, "controlIndex"),
         cell_index when is_integer(cell_index) <- Map.get(cell, "cellIndex"),
         cell_para when is_integer(cell_para) <- Map.get(cell, "cellParaIndex"),
         offset when is_integer(offset) <- Map.get(ref, "offset", 0) do
      [section, parent_para, control, cell_index, cell_para, offset]
    else
      _ -> nil
    end
  end

  defp compact_positional_ref(%{} = ref, type) when type not in [nil, "", "paragraph"] do
    allowed = MapSet.new(["section", "paragraph", "control", "type"])

    with true <- ref_keys_subset?(ref, allowed),
         section when is_integer(section) <- Map.get(ref, "section", 0),
         paragraph when is_integer(paragraph) <- Map.get(ref, "paragraph"),
         control when is_integer(control) <- Map.get(ref, "control") do
      [section, paragraph, control]
    else
      _ -> nil
    end
  end

  defp compact_positional_ref(%{} = ref, _type) do
    allowed = MapSet.new(["section", "paragraph", "offset", "length"])

    with true <- ref_keys_subset?(ref, allowed),
         section when is_integer(section) <- Map.get(ref, "section", 0),
         paragraph when is_integer(paragraph) <- Map.get(ref, "paragraph"),
         offset when is_integer(offset) <- Map.get(ref, "offset", 0) do
      case Map.get(ref, "length") do
        length when is_integer(length) -> [section, paragraph, offset, length]
        nil -> [section, paragraph, offset]
        _other -> nil
      end
    else
      _ -> compact_section_ref(ref)
    end
  end

  defp compact_positional_ref(_ref, _type), do: nil

  defp compact_section_ref(ref) do
    allowed = MapSet.new(["section"])

    with true <- ref_keys_subset?(ref, allowed),
         section when is_integer(section) <- Map.get(ref, "section") do
      [section]
    else
      _ -> nil
    end
  end

  defp ref_keys_subset?(ref, allowed) do
    ref
    |> Map.keys()
    |> Enum.all?(&MapSet.member?(allowed, &1))
  end

  defp node_position(node, fallback_index) do
    ref =
      node
      |> node_field("ref")
      |> normalize_ir_value()

    cond do
      is_map(ref) ->
        section_id = integer_ref_field(ref, "section") || 0

        paragraph_id =
          integer_ref_field(ref, "paragraph") ||
            nested_integer_ref(ref, ["cell", "parentParaIndex"])

        {section_id, paragraph_id || fallback_index}

      true ->
        {0, fallback_index}
    end
  end

  defp integer_ref_field(ref, key) do
    case Map.get(ref, key) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp nested_integer_ref(ref, path) do
    case get_in(ref, path) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp expand_projected_node(node) do
    node = normalize_ir_value(node)
    type = Map.get(node, "type")

    case expand_positional_ref(Map.get(node, "ref"), type) do
      nil -> node
      ref -> Map.put(node, "ref", ref)
    end
  end

  defp expand_positional_ref([section], _type) when is_integer(section) do
    %{"section" => section}
  end

  defp expand_positional_ref([section, paragraph, offset], "paragraph")
       when is_integer(section) and is_integer(paragraph) and is_integer(offset) do
    %{"section" => section, "paragraph" => paragraph, "offset" => offset}
  end

  defp expand_positional_ref([section, paragraph, offset, length], "paragraph")
       when is_integer(section) and is_integer(paragraph) and is_integer(offset) and
              is_integer(length) do
    %{"section" => section, "paragraph" => paragraph, "offset" => offset, "length" => length}
  end

  defp expand_positional_ref(
         [section, parent_para, control, cell_index, cell_para, offset],
         "cell"
       )
       when is_integer(section) and is_integer(parent_para) and is_integer(control) and
              is_integer(cell_index) and is_integer(cell_para) and is_integer(offset) do
    %{
      "section" => section,
      "paragraph" => parent_para,
      "offset" => offset,
      "cell" => %{
        "parentParaIndex" => parent_para,
        "controlIndex" => control,
        "cellIndex" => cell_index,
        "cellParaIndex" => cell_para
      }
    }
  end

  defp expand_positional_ref([section, paragraph, control], type)
       when is_integer(section) and is_integer(paragraph) and is_integer(control) and
              is_binary(type) and type not in ["", "paragraph", "cell"] do
    %{"section" => section, "paragraph" => paragraph, "control" => control, "type" => type}
  end

  defp expand_positional_ref(_ref, _type), do: nil

  defp normalize_ir_value(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_ir_value(v)} end)
  end

  defp normalize_ir_value(list) when is_list(list), do: Enum.map(list, &normalize_ir_value/1)
  defp normalize_ir_value(other), do: other

  defp node_field(node, key) when is_map_key(node, key), do: Map.get(node, key)

  defp node_field(node, key) do
    atom = String.to_existing_atom(key)
    Map.get(node, atom)
  rescue
    ArgumentError -> nil
  end

  # ── write-back diff: old (live) IR vs new (edited) payloads ───────────────

  @doc """
  Diff the live OLD IR nodes against the NEW (edited) payload nodes — both flat
  node lists — into the engine-neutral change tuples the ecrits consumer applies
  via the Editor: `{:text, op, marker}`, `{:set, ref, type, props}`,
  `{:insert_table, op, marker}`, `{:insert_picture, op, marker, props}`,
  `{:delete_node, op, marker}`. Returns the change list, or `{:error, reason}`.
  Pure — no process, no engine handle; the caller owns applying + persisting.
  """
  @spec changes([element()], [element()]) :: [tuple()] | {:error, term()}
  def changes(old_nodes, new_nodes) do
    case scan_ir_changes(old_nodes, new_nodes, 0, 0, []) do
      {:ok, changes} -> Enum.reverse(changes)
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan_ir_changes(old_nodes, new_nodes, old_index, new_index, acc) do
    old_done? = old_index >= length(old_nodes)
    new_done? = new_index >= length(new_nodes)

    cond do
      old_done? and new_done? ->
        {:ok, acc}

      new_done? ->
        with {:ok, delete} <- payload_delete_change(Enum.at(old_nodes, old_index)) do
          scan_ir_changes(old_nodes, new_nodes, old_index + 1, new_index, [delete | acc])
        end

      old_done? ->
        with {:ok, insert} <-
               payload_insert_change(
                 Enum.at(new_nodes, new_index),
                 ir_insertion_anchor(old_nodes, old_index)
               ) do
          scan_ir_changes(old_nodes, new_nodes, old_index, new_index + 1, [insert | acc])
        end

      true ->
        old = Enum.at(old_nodes, old_index)
        new = Enum.at(new_nodes, new_index)

        cond do
          inserted_payload?(new) and not existing_insert_payload_match?(old, new) ->
            with {:ok, insert} <-
                   payload_insert_change(new, ir_insertion_anchor(old_nodes, old_index)) do
              scan_ir_changes(old_nodes, new_nodes, old_index, new_index + 1, [insert | acc])
            end

          deletable_payload?(old) and not same_payload_identity?(old, new) and
              aligns_after_deleted_payload?(old_nodes, old_index, new) ->
            with {:ok, delete} <- payload_delete_change(old) do
              scan_ir_changes(old_nodes, new_nodes, old_index + 1, new_index, [delete | acc])
            end

          true ->
            case existing_node_changes(old, new) do
              {:ok, node_changes} ->
                scan_ir_changes(
                  old_nodes,
                  new_nodes,
                  old_index + 1,
                  new_index + 1,
                  Enum.reverse(node_changes) ++ acc
                )

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  defp existing_node_changes(old, new) do
    old_node = normalize_ir_value(old)
    new_node = normalize_ir_value(new)
    old_ref = Map.get(old_node, "ref")
    new_ref = Map.get(new_node, "ref")
    old_type = Map.get(old_node, "type")
    new_type = Map.get(new_node, "type")
    raw_ref = node_field(old, "ref") || old_ref

    cond do
      Map.has_key?(new_node, "ref") and old_ref != new_ref ->
        {:error, :structural_change}

      old_type != new_type ->
        {:error, :structural_change}

      old_node == new_node ->
        {:ok, []}

      is_nil(raw_ref) ->
        {:error, :unroutable}

      true ->
        changes_for_node(old_node, new_node, raw_ref, old_type)
    end
  end

  defp inserted_table_payload?(node) do
    node = normalize_ir_value(node)

    Map.get(node, "type") == "table" and
      (is_list(Map.get(node, "cells")) or positive_int?(Map.get(node, "rows")) or
         positive_int?(Map.get(node, "cols")))
  end

  defp inserted_picture_payload?(node) do
    node = normalize_ir_value(node)

    Map.get(node, "type") == "picture" and
      (present_string?(Map.get(node, "src")) or present_string?(Map.get(node, "path")) or
         present_string?(Map.get(node, "image_base64")) or nonempty_list?(Map.get(node, "bins")))
  end

  defp inserted_payload?(node),
    do: inserted_table_payload?(node) or inserted_picture_payload?(node)

  defp existing_table_payload_match?(old, new) do
    old = normalize_ir_value(old)
    new = normalize_ir_value(new)

    Map.get(old, "type") == "table" and Map.get(new, "type") == "table" and
      not Map.has_key?(new, "cells")
  end

  defp existing_picture_payload_match?(old, new) do
    old = normalize_ir_value(old)
    new = normalize_ir_value(new)

    Map.get(old, "type") == "picture" and Map.get(new, "type") == "picture"
  end

  defp existing_insert_payload_match?(old, new),
    do: existing_table_payload_match?(old, new) or existing_picture_payload_match?(old, new)

  defp deletable_payload?(node) do
    node = normalize_ir_value(node)
    Map.get(node, "type") == "picture" and not is_nil(node_field(node, "ref"))
  end

  defp aligns_after_deleted_payload?(old_nodes, old_index, new) do
    case Enum.at(old_nodes, old_index + 1) do
      nil -> false
      next_old -> same_payload_identity?(next_old, new)
    end
  end

  defp same_payload_identity?(old, new) do
    old = normalize_ir_value(old)
    new = normalize_ir_value(new)

    cond do
      Map.get(old, "type") != Map.get(new, "type") ->
        false

      Map.get(old, "type") == "picture" ->
        same_picture_identity?(old, new)

      true ->
        strip_ref(old) == strip_ref(new)
    end
  end

  defp same_picture_identity?(old, new) do
    case {picture_identity_marker(old), picture_identity_marker(new)} do
      {old_marker, new_marker} when is_binary(old_marker) and is_binary(new_marker) ->
        old_marker == new_marker

      _ ->
        strip_ref(old) == strip_ref(new)
    end
  end

  defp picture_identity_marker(node) do
    Enum.find_value(["description", "alt", "src", "path"], fn key ->
      value = Map.get(node, key)
      if is_present(value), do: value
    end)
  end

  defp strip_ref(node), do: node |> normalize_ir_value() |> Map.delete("ref")

  defp payload_insert_change(node, anchor) do
    cond do
      inserted_table_payload?(node) -> table_insert_change(node, anchor)
      inserted_picture_payload?(node) -> picture_insert_change(node, anchor)
      true -> {:error, :structural_change}
    end
  end

  defp payload_delete_change(node) do
    node = normalize_ir_value(node)

    cond do
      not deletable_payload?(node) ->
        {:error, :structural_change}

      true ->
        marker = picture_marker(node)
        {:ok, {:delete_node, %{"op" => "delete_node", "ref" => node_field(node, "ref")}, marker}}
    end
  end

  defp positive_int?(value), do: is_integer(value) and value > 0
  defp nonempty_list?(value), do: is_list(value) and value != []
  defp present_string?(value), do: is_present(value)

  defp table_insert_change(node, anchor) do
    node = normalize_ir_value(node)
    cells = coerce_table_cells(Map.get(node, "cells", []))
    rows = table_rows(node, cells)
    cols = table_cols(node, cells)

    cond do
      Map.get(node, "type") != "table" ->
        {:error, :structural_change}

      not (rows > 0 and cols > 0) ->
        {:error, {:invalid_table_payload, "table payload needs cells or positive rows/cols"}}

      true ->
        op =
          %{
            "op" => "insert_table",
            "ref" => anchor,
            "rows" => rows,
            "cols" => cols
          }
          |> maybe_put_nonempty("cells", cells)
          |> maybe_put_bool("header", Map.get(node, "header"))
          |> maybe_put_string("header_color", Map.get(node, "header_color"))

        {:ok, {:insert_table, op, first_table_marker(cells)}}
    end
  end

  defp picture_insert_change(node, anchor) do
    node = normalize_ir_value(node)
    src = Map.get(node, "src") || Map.get(node, "path")
    bins = picture_bins(node)

    cond do
      Map.get(node, "type") != "picture" ->
        {:error, :structural_change}

      not (present_string?(src) or nonempty_list?(bins)) ->
        {:error, {:invalid_picture_payload, "picture payload needs src/path/image_base64/bins"}}

      true ->
        description = picture_insert_description(node, src)

        op =
          %{"op" => "insert_picture", "ref" => anchor}
          |> maybe_put_string("src", src)
          |> maybe_put_nonempty("bins", bins)
          |> maybe_put_string("extension", Map.get(node, "extension"))
          |> maybe_put_integer("width", Map.get(node, "width") || Map.get(node, "Width"))
          |> maybe_put_integer("height", Map.get(node, "height") || Map.get(node, "Height"))
          |> maybe_put_integer("natural_width_px", Map.get(node, "natural_width_px"))
          |> maybe_put_integer("natural_height_px", Map.get(node, "natural_height_px"))
          |> maybe_put_string("description", description)
          |> maybe_put_bool("inline_in_cell", picture_insert_inline_in_cell?(anchor, node))

        {:ok, {:insert_picture, op, picture_marker(node), picture_insert_props(node)}}
    end
  end

  defp picture_insert_description(node, src) do
    Map.get(node, "description") || Map.get(node, "alt") || picture_src_description(src)
  end

  defp picture_src_description(src) when is_binary(src) do
    src
    |> Path.basename()
    |> case do
      "." -> nil
      "/" -> nil
      "" -> nil
      basename -> basename
    end
  end

  defp picture_src_description(_src), do: nil

  defp picture_insert_inline_in_cell?(anchor, node) do
    not picture_insert_floating?(node) and cell_anchor?(anchor)
  end

  defp cell_anchor?(anchor) do
    case normalize_ir_value(anchor) do
      %{} = anchor ->
        case Map.get(anchor, "cell") do
          %{} -> true
          _ -> match?([_ | _], Map.get(anchor, "cellPath"))
        end

      _other ->
        false
    end
  end

  defp picture_bins(node) do
    cond do
      nonempty_list?(Map.get(node, "bins")) -> Map.get(node, "bins")
      present_string?(Map.get(node, "image_base64")) -> [Map.get(node, "image_base64")]
      true -> []
    end
  end

  @picture_insert_only_fields ~w(type text src path image_base64 bins extension description alt
                                 width height Width Height natural_width_px natural_height_px)
  @picture_insert_property_fields ~w(width height Width Height x y PosX PosY horzOffset
                                     vertOffset TreatAsChar treatAsChar Caption caption
                                     horzRelTo vertRelTo horzAlign vertAlign textWrap)
  @picture_insert_position_fields ~w(x y PosX PosY horzOffset vertOffset
                                     horzRelTo vertRelTo horzAlign vertAlign)

  defp picture_insert_props(node) do
    node = normalize_ir_value(node)

    node
    |> Map.take(picture_insert_property_fields(node))
    |> Enum.reject(fn {key, value} ->
      key in @picture_insert_only_fields or is_nil(value)
    end)
    |> Map.new()
  end

  defp picture_insert_property_fields(node) do
    if picture_insert_floating?(node) do
      @picture_insert_property_fields
    else
      @picture_insert_property_fields -- @picture_insert_position_fields
    end
  end

  defp picture_insert_floating?(node) do
    Map.get(node, "treatAsChar") == false or Map.get(node, "TreatAsChar") == false
  end

  defp picture_marker(node) do
    Enum.find_value(["description", "alt", "src", "path", "text"], fn key ->
      value = Map.get(node, key)

      cond do
        is_present(value) -> value
        true -> nil
      end
    end)
  end

  defp coerce_table_cells(cells) when is_list(cells) do
    Enum.map(cells, fn
      row when is_list(row) -> Enum.map(row, &to_string/1)
      value -> [to_string(value)]
    end)
  end

  defp coerce_table_cells(_cells), do: []

  defp table_rows(node, cells) do
    case Map.get(node, "rows") do
      rows when is_integer(rows) and rows > 0 -> rows
      _ -> length(cells)
    end
  end

  defp table_cols(node, cells) do
    case Map.get(node, "cols") do
      cols when is_integer(cols) and cols > 0 ->
        cols

      _ ->
        cells
        |> Enum.map(&length/1)
        |> Enum.max(fn -> 0 end)
    end
  end

  defp first_table_marker(cells) do
    cells
    |> List.flatten()
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp maybe_put_nonempty(map, _key, []), do: map
  defp maybe_put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_bool(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_bool(map, _key, _value), do: map

  defp maybe_put_integer(map, key, value) when is_integer(value), do: Map.put(map, key, value)
  defp maybe_put_integer(map, _key, _value), do: map

  defp maybe_put_string(map, key, value) when is_present(value),
    do: Map.put(map, key, value)

  defp maybe_put_string(map, _key, _value), do: map

  defp ir_insertion_anchor(old_nodes, old_index) do
    unsafe_paragraphs = unsafe_insert_anchor_paragraphs(old_nodes)

    previous =
      old_nodes
      |> Enum.take(old_index)
      |> Enum.reverse()
      |> Enum.find_value(&previous_insert_ref_at_end(&1, unsafe_paragraphs))

    next =
      old_nodes
      |> Enum.drop(old_index)
      |> Enum.find_value(&body_ref_at_end(&1, unsafe_paragraphs))

    previous || next || "end"
  end

  defp previous_insert_ref_at_end(node, unsafe_paragraphs) do
    cell_ref_at_end(node) || body_ref_at_end(node, unsafe_paragraphs)
  end

  defp unsafe_insert_anchor_paragraphs(nodes) do
    Enum.reduce(nodes, MapSet.new(), fn node, acc ->
      node = normalize_ir_value(node)
      type = Map.get(node, "type")
      ref = node_field(node, "ref") |> normalize_ir_value()

      if unsafe_insert_anchor_type?(type) and is_map(ref) and
           is_integer(Map.get(ref, "paragraph")) do
        MapSet.put(acc, {Map.get(ref, "section", 0), Map.get(ref, "paragraph")})
      else
        acc
      end
    end)
  end

  defp unsafe_insert_anchor_type?(type),
    do: type in ["section_def", "column_def", "page_number_pos", "table", "picture"]

  defp cell_ref_at_end(node) do
    node = normalize_ir_value(node)

    with true <- Map.get(node, "type") == "cell",
         %{} = ref <- node_field(node, "ref") |> normalize_ir_value(),
         %{} = cell <- Map.get(ref, "cell") |> normalize_ir_value(),
         section when is_integer(section) <- Map.get(ref, "section", 0),
         paragraph when is_integer(paragraph) <- Map.get(ref, "paragraph"),
         parent_para when is_integer(parent_para) <-
           Map.get(cell, "parentParaIndex") || paragraph,
         control when is_integer(control) <- Map.get(cell, "controlIndex"),
         cell_index when is_integer(cell_index) <- Map.get(cell, "cellIndex"),
         cell_para when is_integer(cell_para) <- Map.get(cell, "cellParaIndex"),
         text when is_binary(text) <- Map.get(node, "text") do
      %{
        "section" => section,
        "paragraph" => parent_para,
        "offset" => String.length(text),
        "cell" => %{
          "parentParaIndex" => parent_para,
          "controlIndex" => control,
          "cellIndex" => cell_index,
          "cellParaIndex" => cell_para
        }
      }
    else
      _ -> nil
    end
  end

  defp body_ref_at_end(node, unsafe_paragraphs) do
    node = normalize_ir_value(node)

    with true <- Map.get(node, "type") == "paragraph",
         %{} = ref <- node_field(node, "ref") |> normalize_ir_value(),
         true <- body_paragraph_ref?(ref),
         false <- unsafe_insert_anchor_paragraph?(ref, unsafe_paragraphs),
         text when is_binary(text) <- node |> normalize_ir_value() |> Map.get("text") do
      %{
        "section" => Map.get(ref, "section", 0),
        "paragraph" => Map.get(ref, "paragraph"),
        "offset" => String.length(text)
      }
    else
      _ -> nil
    end
  end

  defp unsafe_insert_anchor_paragraph?(ref, unsafe_paragraphs) do
    MapSet.member?(unsafe_paragraphs, {Map.get(ref, "section", 0), Map.get(ref, "paragraph")})
  end

  defp body_paragraph_ref?(ref) do
    is_integer(Map.get(ref, "paragraph")) and is_nil(Map.get(ref, "cell")) and
      is_nil(Map.get(ref, "control")) and is_nil(Map.get(ref, "note"))
  end

  defp changes_for_node(old_node, new_node, raw_ref, type) do
    with {:ok, text_change} <- text_change_for_node(old_node, new_node, raw_ref, type),
         {:ok, prop_change} <- prop_change_for_node(old_node, new_node, raw_ref, type) do
      {:ok, Enum.reject([text_change, prop_change], &is_nil/1)}
    end
  end

  defp text_change_for_node(old_node, new_node, raw_ref, type) do
    old_text = Map.get(old_node, "text")
    new_text = Map.get(new_node, "text")

    cond do
      old_text == new_text ->
        {:ok, nil}

      type == "table" ->
        {:ok, nil}

      type == "cell" and is_nil(old_text) and is_binary(new_text) ->
        {:ok, {:text, %{"op" => "set_cell", "ref" => raw_ref, "text" => new_text}, new_text}}

      not (is_binary(old_text) and is_binary(new_text)) ->
        {:error, :unroutable}

      type == "cell" ->
        {:ok, {:text, %{"op" => "set_cell", "ref" => raw_ref, "text" => new_text}, new_text}}

      old_text == "" ->
        {:ok, {:text, %{"op" => "insert_text", "ref" => raw_ref, "text" => new_text}, new_text}}

      true ->
        {:ok,
         {:text,
          %{
            "op" => "replace_text",
            "ref" => raw_ref,
            "query" => old_text,
            "replacement" => new_text
          }, new_text}}
    end
  end

  defp prop_change_for_node(old_node, new_node, raw_ref, type) do
    props =
      old_node
      |> changed_property_keys(new_node)
      |> Map.new(fn key -> {key, Map.get(new_node, key)} end)

    if props == %{} do
      {:ok, nil}
    else
      {:ok, {:set, raw_ref, type, props}}
    end
  end

  defp changed_property_keys(old_node, new_node) do
    old_node
    |> Map.keys()
    |> Kernel.++(Map.keys(new_node))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in ["ref", "type", "text"]))
    |> Enum.filter(&(Map.get(old_node, &1) != Map.get(new_node, &1)))
  end
end
