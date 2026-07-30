defmodule Doclang.Adapter.Office do
  @moduledoc """
  The office (LibreOffice / UNO) arm of the DocLang seam — the replacement for
  `Libreofficex.LokBackend.Ir`, which lived in the deleted `:libreofficex` dep.

  As with the rhwp arm, two surfaces live here: the DocLang lowering
  (`to_blocks/1` + `bindings/1`) and the nested-JSONL projection policy
  (`nested_payloads/1`, `canonicalize/1`, `shape_old/1`,
  `validate_property_changes/2`), which is still the mounted format until Layer 4
  lands the Qt6+JSPI transport.

  Unlike rhwp's integer-tuple positional grammar, UNO packs an ordinal leaf
  inside an opaque string that ALSO carries stable container names. The
  projection keeps no ref in the bytes either way and recovers the real one —
  ordinal or name — from the positionally-aligned live node at commit.

  ## Ref grammar

      p<idx>                       body paragraph (Writer)   — POSITIONAL ordinal
      p<idx>/r<ridx>               run inside a paragraph     — POSITIONAL; dup of the paragraph text
      fn[<n>] / en[<n>]            foot/endnote               — POSITIONAL ordinal
      tbl[<Name>]                  table                      — STABLE name
      tbl[<Name>]/cell[<B2>]       table cell                 — POSITIONAL coordinate (col/row, A1)
      section[<Name>]/columns      Writer text-section columns — STABLE name
      page_style[<Name>]           Writer page setup/decorations — STABLE name
      page_style[<Name>]/header    Writer page-style header text — STABLE name
      page_style[<Name>]/footer    Writer page-style footer text — STABLE name
      style[ParagraphStyles:<Name>] Writer paragraph style       — STABLE name
      style[CharacterStyles:<Name>] Writer character style       — STABLE name
      style[NumberingStyles:<Name>] Writer list/numbering style   — STABLE name
      document                     Writer document metadata       — STABLE singleton
      document/settings            Writer document settings       — STABLE singleton
      document/protection          Writer protection/tracking config — STABLE singleton
      bookmark[<Name>]              Writer bookmark                — STABLE name
      reference_mark[<Name>]        Writer reference mark          — STABLE name
      field[<n>]                    Writer field/comment            — POSITIONAL ordinal
      redline[<n>]                  Writer tracked change           — POSITIONAL ordinal
      frame[<Name>]                 Writer text frame                — STABLE name
      embedded[<Name>]              Writer OLE/chart/Math object     — STABLE name
      draw[<Name>]                  Writer drawing object/group      — STABLE name
      draw[<Name>]/shape[<Name>]    child of Writer drawing group    — STABLE name
      page[<Slide>]                slide (Impress)            — STABLE name
      page[<Slide>]/shape[<Name>]  shape / text frame         — STABLE name
      page[<Slide>]/notes          slide notes page            — STABLE slide name
      page[<Slide>]/notes/shape[<Name>]
                                   notes-page shape             — STABLE name
      master[<Name>]               master slide                 — STABLE name
      master[<Name>]/theme         master theme                 — STABLE master name
      master[<Name>]/shape[<Name>] master/placeholder shape     — STABLE name
      draw_page[<Name>]            Draw page                    — STABLE name
      draw_page[<Name>]/shape[<Name>]
                                   Draw shape                   — STABLE name
      draw_master[<Name>]          Draw master page             — STABLE name
      draw_master[<Name>]/theme    Draw master theme            — STABLE master name
      formula                      Math formula document         — STABLE singleton
      sheet[<Sheet>]               sheet (Calc)               — STABLE name
      sheet[<Sheet>]/cell[<B2>]    spreadsheet cell (Calc)    — POSITIONAL coordinate (col/row, A1)

  ## Derived (read-only) fields

  The walker attaches these for the `doc.find`/`read` surface, but they are NOT
  settable element properties — they must not appear in an editable projection,
  and their ABSENCE must not be read as a property edit on write-back:

      context     breadcrumb of ancestor text
      row, col    1-based cell coordinates (already encoded in the cell ref)
      sheet, address, display
                  Calc convenience fields mirrored from the cell ref/value

  Calc cells intentionally keep `row`, `col`, `sheet`, `address`, `display`,
  `value`, `value_type`, and `formula` in the canonical projection. They are the
  spreadsheet cell edit surface, not arbitrary UNO properties; the consumer must
  route them through Calc-specific `XCell` accessors on write-back.
  """

  import Ecrits.Guards

  @synthetic_fields ~w(context row col sheet address display value value_type formula)
  @common_synthetic_fields ~w(context row col)

  # UNO node types that carry editable text but have no DocLang element of their
  # own. They lower to `<text>` with a `<custom>` recording the UNO provenance,
  # so the text edit surface survives (that is what the buffer is for) while the
  # node kind is not silently lost.
  @text_bearing ~w(paragraph shape text_frame placeholder shape_group header footer)

  @typedoc "Classified element kind for a UNO ref."
  @type kind ::
          :document
          | :paragraph
          | :run
          | :table
          | :cell
          | :section
          | :page_style
          | :header
          | :footer
          | :paragraph_style
          | :character_style
          | :numbering_style
          | :bookmark
          | :cross_reference
          | :field
          | :tracked_change
          | :document_settings
          | :document_protection
          | :text_frame
          | :embedded_object
          | :drawing_object
          | :drawing_group
          | :slide
          | :shape
          | :shape_group
          | :placeholder
          | :notes_page
          | :master_slide
          | :theme
          | :draw_page
          | :draw_master_page
          | :formula
          | :sheet
          | :unknown

  @typedoc "A decoded element node (string-keyed map from the walk JSON)."
  @type element :: %{optional(String.t()) => term()}

  # ── DocLang: engine IR -> canonical blocks ────────────────────────────────

  @doc """
  Lower the live UNO element walk to canonical DocLang blocks: runs dropped
  (their text duplicates the parent paragraph), table cells folded into their
  `<table>`, text-bearing shapes lowered to `<text>` with a `<custom>` marking
  their UNO kind, and every other node to `<group><custom>`.
  """
  @spec to_blocks([element()]) :: [Doclang.block()]
  def to_blocks(nodes) when is_list(nodes), do: nodes |> build() |> Enum.map(&elem(&1, 0))

  @doc """
  The same lowering as `to_blocks/1`, each block paired with the live UNO ref.
  Ordered to match `Doclang.child_blocks/1`.
  """
  @spec bindings([element()]) :: [map()]
  def bindings(nodes) when is_list(nodes), do: nodes |> build() |> Enum.map(&elem(&1, 1))

  @doc """
  The UNO ref for `block`, recovered from the live `baseline`. Best-effort
  convenience for single lookups (first equal block wins); `Doclang.changes/3`
  recovers refs exactly, by aligned tree position.
  """
  @spec ref_for(Doclang.block(), [element()] | [map()]) :: String.t() | nil
  def ref_for(block, baseline) when is_list(baseline) do
    baseline
    |> normalize_baseline()
    |> flatten_bindings()
    |> Enum.find_value(fn binding ->
      if Doclang.shallow(binding.block) == Doclang.shallow(block), do: binding.ref
    end)
  end

  @doc """
  The ref a newly inserted block anchors to: the nearest preceding paragraph-ish
  ref, else the next one, else `"end"`. UNO refs are opaque strings, so unlike
  the rhwp arm there is no offset to compute — the Editor resolves the position.
  """
  @spec insertion_anchor([map()], non_neg_integer()) :: String.t()
  def insertion_anchor(bindings, index) when is_list(bindings) do
    previous =
      bindings
      |> Enum.take(index)
      |> Enum.reverse()
      |> Enum.find_value(&anchorable_ref/1)

    next = bindings |> Enum.drop(index) |> Enum.find_value(&anchorable_ref/1)

    previous || next || "end"
  end

  defp anchorable_ref(%{ref: ref}) when is_present(ref) do
    if classify(ref) in [:paragraph, :cell, :shape, :text_frame, :placeholder], do: ref
  end

  defp anchorable_ref(_binding), do: nil

  defp normalize_baseline([]), do: []
  defp normalize_baseline([%{block: _} | _] = bindings), do: bindings
  defp normalize_baseline(nodes), do: bindings(nodes)

  defp flatten_bindings(bindings) do
    Enum.flat_map(bindings, fn binding ->
      [binding | flatten_bindings(Map.get(binding, :children, []))]
    end)
  end

  defp build(nodes) do
    nodes
    |> Enum.reject(&run?/1)
    |> group_tables()
    |> Enum.map(&entry_to_block/1)
  end

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

          # A Calc cell has no owning `<table>` node in the walk — it hangs off
          # `sheet[..]`. Lower it on its own rather than swallowing it.
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
    positions = Enum.map(cells, &cell_position/1)
    rows = positions |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> -1 end) |> Kernel.+(1)
    cols = positions |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> -1 end) |> Kernel.+(1)

    # ROW-MAJOR, not walk order. `Doclang.render_otsl/1` emits the grid row by row
    # and `table_grid/1` re-parses it the same way, while `child_blocks/1` pairs
    # blocks to bindings BY INDEX. Emitting cells in the order the UNO walker
    # happened to return them therefore paired each cell's text with a different
    # cell's ref: a pure no-op read/write silently ROTATED the table's contents.
    # The HWP adapter already sorts (`entry_to_block/1` there); this arm did not.
    # Several cells can land on ONE grid position. Writer names split sub-cells
    # `A1.1`/`A1.2` and the engine's `cell_rc()` stops at the `.`, so both report
    # row 1 col 1. One block each meant `claim_cell/5` kept the first and dropped
    # the rest: the dropped text never reached the buffer at all, AND the block
    # count no longer matched the parse, so every subsequent edit to that document
    # was rejected as a structural change — silent data loss plus a permanent
    # lockout. Fold collisions into one cell's paragraphs, exactly as the HWP arm
    # already does for multi-paragraph cells. The real fix is upstream in
    # `cell_rc()`; this keeps the document readable and writable meanwhile.
    {cell_blocks, cell_bindings} =
      cells
      |> Enum.zip(positions)
      |> Enum.group_by(fn {_cell, position} -> position end, fn {cell, _} -> cell end)
      |> Enum.sort_by(fn {position, _cells} -> position end)
      |> Enum.reduce({[], []}, fn {{row, col}, grouped}, {blocks, binds} ->
        paragraphs =
          Enum.map(grouped, fn cell ->
            {%{"type" => "text", "text" => node_text(cell)}, cell}
          end)

        cell_block = %{
          "row" => row,
          "col" => col,
          "row_span" => 1,
          "col_span" => 1,
          "header" => false,
          "blocks" => Enum.map(paragraphs, &elem(&1, 0))
        }

        cell_binds =
          Enum.map(paragraphs, fn {paragraph, cell} ->
            Doclang.binding(paragraph,
              ref: Map.get(cell, "ref"),
              type: "cell",
              cell?: true,
              node: cell
            )
          end)

        {[cell_block | blocks], binds ++ cell_binds}
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
    ref = Map.get(node, "ref")

    cond do
      type in @text_bearing ->
        block =
          %{"type" => "text", "text" => node_text(node)}
          |> put_custom(custom_pairs(node, "uno:" <> to_string(type)), type != "paragraph")

        {block, Doclang.binding(block, ref: ref, type: type, node: node)}

      type == "picture" ->
        src = Map.get(node, "src") || Map.get(node, "path") || Map.get(node, "url")

        block =
          %{"type" => "picture"}
          |> maybe_put("src", src)
          |> put_custom(custom_pairs(node, "uno:picture"), false)

        {block, Doclang.binding(block, ref: ref, type: type, node: node)}

      type == "cell" ->
        block =
          %{"type" => "text", "text" => node_text(node)}
          |> put_custom(custom_pairs(node, "uno:cell"), true)

        {block, Doclang.binding(block, ref: ref, type: type, cell?: true, node: node)}

      true ->
        block =
          %{"type" => "group"}
          |> put_custom(custom_pairs(node, "uno:" <> to_string(type || "unknown")), true)

        {block, Doclang.binding(block, ref: ref, type: type, node: node)}
    end
  end

  # UNO cell refs carry an A1 coordinate (`tbl[Name]/cell[B2]`); the walk also
  # mirrors it as 1-based `row`/`col` convenience fields. DocLang's own grid is
  # 0-based (`Doclang.resolve_spans/4` anchors at row 0 and spans `0..rows-1`),
  # hence the shift.
  #
  # The 1-based reading is verified against the live office client, which treats
  # row 1 as the header row and gates validity on `row > 0 && col > 0`
  # (`office_wasm.ex` officeCompactTableCell / nearby-row selection).
  #
  # Only trust the mirror when it actually looks 1-based. Clamping a stray 0 with
  # `max(row - 1, 0)` would silently land it on top of legitimate row 1, collapsing
  # two distinct cells into one grid slot and surfacing much later as a bogus
  # `:structural_change` rejection. The A1 ref is authoritative, so fall back to it.
  defp cell_position(cell) do
    row = Map.get(cell, "row")
    col = Map.get(cell, "col")

    if is_integer(row) and is_integer(col) and row > 0 and col > 0 do
      {row - 1, col - 1}
    else
      cell |> Map.get("ref") |> a1_position() || {0, 0}
    end
  end

  defp a1_position(ref) when is_binary(ref) do
    case Regex.run(~r{/cell\[([A-Za-z]+)(\d+)\]}, ref) do
      [_, letters, digits] ->
        {String.to_integer(digits) - 1, column_index(letters) - 1}

      _ ->
        nil
    end
  end

  defp a1_position(_ref), do: nil

  defp column_index(letters) do
    letters
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, acc -> acc * 26 + (char - ?A + 1) end)
  end

  defp node_text(node) do
    case Map.get(node, "text") do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  # Preserve-mode `<custom>`: `ns` first (as `writer/custom.rs` does), then the
  # reflected UNO `props` in a deterministic key order. Derived fields never
  # ride along — their absence must not read as a property edit.
  defp custom_pairs(node, namespace) do
    props =
      case Map.get(node, "props") do
        %{} = props -> props
        _ -> %{}
      end

    extra =
      props
      |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_boolean(v) end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {k, v} -> [k, to_string(v)] end)

    [["ns", namespace] | extra]
  end

  # A bare `ns` is dropped when the DocLang element already says everything the
  # node kind said (a UNO paragraph IS a `<text>`); it is KEPT when the lowering
  # was lossy (a shape flattened to `<text>`, anything flattened to `<group>`),
  # because then `ns` is the only record of what the node really is.
  defp put_custom(block, [["ns", _]], false), do: block
  defp put_custom(block, pairs, _keep_bare_ns?), do: Map.put(block, "custom", pairs)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── nested JSONL projection policy (ported from Libreofficex.LokBackend.Ir) ─

  @doc """
  Convenience fields the walker emits outside `props`. Most are read-only
  metadata; Calc cell `value`/`value_type`/`formula` are exposed in the
  projection and must be written through Calc cell accessors, not `set` props.
  """
  @spec synthetic_fields() :: [String.t()]
  def synthetic_fields, do: @synthetic_fields

  @doc """
  Classify a UNO ref string into an element kind. `nil`/`""` is the whole
  document. Order matters: the specific suffixes (`/cell[…]`, `/shape[…]`, `/r…`)
  are tested before the container prefixes.
  """
  @spec classify(String.t() | nil) :: kind
  def classify(nil), do: :document
  def classify(""), do: :document

  def classify(ref) when is_binary(ref) do
    cond do
      ref == "document" -> :document
      ref == "document/settings" -> :document_settings
      ref == "document/protection" -> :document_protection
      ref == "formula" -> :formula
      String.starts_with?(ref, "bookmark[") -> :bookmark
      String.starts_with?(ref, "reference_mark[") -> :cross_reference
      String.starts_with?(ref, "field[") -> :field
      String.starts_with?(ref, "redline[") -> :tracked_change
      String.starts_with?(ref, "frame[") -> :text_frame
      String.starts_with?(ref, "embedded[") -> :embedded_object
      String.starts_with?(ref, "draw[") and String.contains?(ref, "/shape[") -> :drawing_object
      String.starts_with?(ref, "draw[") -> :drawing_object
      # A trailing `/r<n>` is unambiguously a run — even for a shape's text run
      # (`page[..]/shape[..]/p0/r0`), which also contains `/shape[`. Tested first.
      Regex.match?(~r{/r\d+$}, ref) -> :run
      String.contains?(ref, "/cell[") -> :cell
      String.contains?(ref, "/shape[") -> :shape
      String.starts_with?(ref, "page[") and String.ends_with?(ref, "/notes") -> :notes_page
      String.starts_with?(ref, "master[") and String.ends_with?(ref, "/theme") -> :theme
      String.starts_with?(ref, "master[") -> :master_slide
      String.starts_with?(ref, "draw_master[") and String.ends_with?(ref, "/theme") -> :theme
      String.starts_with?(ref, "draw_master[") -> :draw_master_page
      String.starts_with?(ref, "draw_page[") -> :draw_page
      String.starts_with?(ref, "page_style[") and String.ends_with?(ref, "/header") -> :header
      String.starts_with?(ref, "page_style[") and String.ends_with?(ref, "/footer") -> :footer
      String.starts_with?(ref, "page_style[") -> :page_style
      String.starts_with?(ref, "style[ParagraphStyles:") -> :paragraph_style
      String.starts_with?(ref, "style[CharacterStyles:") -> :character_style
      String.starts_with?(ref, "style[NumberingStyles:") -> :numbering_style
      String.starts_with?(ref, "tbl[") -> :table
      String.starts_with?(ref, "section[") -> :section
      String.starts_with?(ref, "page[") -> :slide
      String.starts_with?(ref, "sheet[") -> :sheet
      Regex.match?(~r{(^|/)p\d+$}, ref) -> :paragraph
      true -> :unknown
    end
  end

  def classify(_ref), do: :unknown

  @doc """
  Whether `ref` addresses by positional index/coordinate (paragraph, run, cell,
  foot/endnote) rather than by a stable name (table, slide, shape). A positional
  ref is read-stable but edit-fragile: it renumbers on structural insert/delete,
  so it must never be persisted across an edit.
  """
  @spec positional?(String.t() | nil) :: boolean
  def positional?(ref) when is_binary(ref) do
    classify(ref) in [:paragraph, :run, :cell, :field, :tracked_change] or
      Regex.match?(~r{^(fn|en)\[}, ref)
  end

  def positional?(_ref), do: false

  @doc "A run node — its text duplicates the parent paragraph, so the projection drops it."
  @spec run?(element()) :: boolean
  def run?(%{"type" => "run"} = node), do: classify(node["ref"]) == :run
  def run?(%{}), do: false
  def run?(_node), do: false

  @doc """
  Canonical node shape for projection AND write-back diffing: drop the ref (the
  nested position is the identity) and the derived fields (not editable).
  Applying the SAME canonicalization to both the old (live) and new (edited)
  nodes is what keeps a stripped derived field from reading as a property edit.
  """
  @spec canonicalize(element()) :: element()
  def canonicalize(%{} = node) do
    if calc_cell?(node) do
      Map.drop(node, ["ref", "context"])
    else
      Map.drop(node, ["ref" | @common_synthetic_fields])
    end
  end

  def canonicalize(other), do: other

  defp calc_cell?(%{"ref" => "sheet[" <> ref, "type" => "cell"}) do
    String.contains?(ref, "/cell[")
  end

  defp calc_cell?(_node), do: false

  @doc """
  Project the raw element walk to the nested, position-addressed payload list
  `[section[paragraph[payload]]]`: runs dropped, every surviving node
  canonicalized (ref + derived fields stripped), each node its own paragraph
  under a single section. Identity is the nested position; the real ref is
  recovered live on write-back via `shape_old/1`.
  """
  @spec nested_payloads([element()]) :: [[[element()]]]
  def nested_payloads(elements) when is_list(elements) do
    payloads =
      elements
      |> Enum.reject(&run?/1)
      |> Enum.map(&canonicalize/1)
      |> Enum.map(fn node -> [node] end)

    [payloads]
  end

  @doc """
  The live OLD nodes shaped for write-back: runs dropped, each entry carrying its
  `:canon` (the same canonical shape the projection emitted) plus the live
  `:ref`/`:type`/`:text` so a positional diff can recover the backend ref the
  ref-less projection omitted.
  """
  @spec shape_old([element()]) :: [%{canon: element(), ref: term(), type: term(), text: term()}]
  def shape_old(elements) when is_list(elements) do
    elements
    |> Enum.reject(&run?/1)
    |> Enum.map(fn node ->
      %{canon: canonicalize(node), ref: node["ref"], type: node["type"], text: node["text"]}
    end)
  end

  @doc """
  Validate edits to the reflected UNO `props` map before a consumer emits a
  `{:set, ...}` change. Only properties advertised by the live object's
  writable `XPropertySetInfo` surface are accepted, and values must match the
  reflected UNO type carried in `prop_types`.
  """
  @spec validate_property_changes(element(), element()) :: :ok | {:error, term()}
  def validate_property_changes(%{} = old_node, %{} = new_node) do
    old_props = Map.get(old_node, "props", %{})
    new_props = Map.get(new_node, "props", %{})
    prop_types = Map.get(old_node, "prop_types", %{})

    cond do
      not (is_map(old_props) and is_map(new_props) and is_map(prop_types)) ->
        {:error, :invalid_property_map}

      true ->
        changed_keys =
          old_props
          |> Map.keys()
          |> Kernel.++(Map.keys(new_props))
          |> Enum.uniq()
          |> Enum.filter(&(Map.get(old_props, &1) != Map.get(new_props, &1)))

        case Enum.find(changed_keys, fn key ->
               not Map.has_key?(old_props, key) or not Map.has_key?(new_props, key) or
                 not Map.has_key?(prop_types, key)
             end) do
          nil -> validate_property_types(changed_keys, old_props, new_props, prop_types)
          key -> {:error, {:invalid_property, key}}
        end
    end
  end

  def validate_property_changes(_old_node, _new_node), do: {:error, :invalid_property_map}

  defp validate_property_types(keys, old_props, new_props, prop_types) do
    case Enum.find(keys, fn key ->
           not uno_value_matches_type?(
             Map.fetch!(old_props, key),
             Map.fetch!(new_props, key),
             Map.fetch!(prop_types, key)
           )
         end) do
      nil -> :ok
      key -> {:error, {:invalid_property_type, key, Map.fetch!(prop_types, key)}}
    end
  end

  defp uno_value_matches_type?(_old, nil, _type), do: true
  defp uno_value_matches_type?(old, new, _type) when is_number(old), do: is_number(new)
  defp uno_value_matches_type?(old, new, _type) when is_boolean(old), do: is_boolean(new)
  defp uno_value_matches_type?(old, new, _type) when is_binary(old), do: is_binary(new)
  defp uno_value_matches_type?(old, new, _type) when is_list(old), do: is_list(new)
  defp uno_value_matches_type?(old, new, _type) when is_map(old), do: is_map(new)

  defp uno_value_matches_type?(_old, value, type) when is_binary(type) do
    normalized = String.downcase(type)

    cond do
      String.contains?(normalized, "boolean") -> is_boolean(value)
      String.contains?(normalized, "string") -> is_binary(value)
      String.contains?(normalized, "char") -> is_binary(value)
      String.contains?(normalized, "float") -> is_number(value)
      String.contains?(normalized, "double") -> is_number(value)
      String.contains?(normalized, "byte") -> is_integer(value)
      String.contains?(normalized, "short") -> is_integer(value)
      String.contains?(normalized, "long") -> is_integer(value)
      String.contains?(normalized, "hyper") -> is_integer(value)
      String.contains?(normalized, "enum") -> is_integer(value)
      String.contains?(normalized, "sequence") -> is_list(value)
      String.contains?(normalized, "[]") -> is_list(value)
      String.contains?(normalized, "struct") -> is_map(value)
      String.starts_with?(normalized, "com.sun.star.") -> is_map(value)
      true -> true
    end
  end

  defp uno_value_matches_type?(_old, _value, _type), do: false
end
