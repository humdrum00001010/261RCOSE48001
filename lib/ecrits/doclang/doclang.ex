defmodule Doclang do
  @moduledoc """
  DocLang v0.6 as the live document IR — the replacement for `Ehwp.Ir` (rhwp
  arm) and `Libreofficex.LokBackend.Ir` (office arm), per
  `docs/plans/2026-07-26-doclang-engine-migration.md` Layer 3.

  rhwp_core's `src/doclang/` is **export only**: it writes DocLang XML and has
  no importer (`eqedit/parser.rs` parses LaTeX, not DocLang). The write-back
  half of the VFS seam therefore needs a reader, and that is `parse/1` — the
  critical path of this module. Everything else (projection bytes, the
  positional diff) is built on top of it.

  Conversion is always `Mode::Preserve`: `Mode::Lean` discards
  `FontInfo | CharColor | NamedStyle | SectionSettings | FloatingObject |
  TextBox | TrackChanges | Caption` (see `src/doclang/loss/report.rs`), which
  would silently drop the very properties the mounted buffer is meant to expose.
  Preserved properties ride `<custom>` as `<hwp_prop name value/>` children,
  exactly as `writer/custom.rs` emits them — DocLang v0.6's `<custom>` is
  `<xs:any>`, element-only and attribute-free, so `ns` is a child prop too.

  ## Identity on the wire (the plan's open decision, settled here)

  **Tree position**, not a synthetic `<custom><prop name="ref"/>`.

  DocLang v0.6 has no `id` attribute (`writer/mod.rs:246`) and `Prov` is never
  emitted as XML (it is internal to `resolve_loc`/`emit_location`, and is
  absent entirely on `Block::{Custom, PageBreak, Thread*}` and on nested
  `Table`). Minting an identity element would mean writing a `<custom>` onto
  every addressable node — inflating every mounted document, changing the bytes
  a human reads, and still needing a positional fallback for the nodes DocLang
  cannot carry one on.

  So the buffer stays ref-less and identity is the node's position in the tree.
  The engine ref is recovered from the LIVE OLD node at the aligned position
  (`Doclang.Adapter.*.bindings/1`), never from the edited buffer, and any edit
  that cannot be aligned positionally fails closed with
  `{:error, :structural_change}`. This is the same contract the JSONL
  projection has today; the only change is that the scan is recursive over a
  tree instead of one flat pass.

  ## Canonical block shape

  `parse/1` yields plain string-keyed maps so `old == new` is a valid identity
  test (the diff's whole basis). Keys are omitted when they carry nothing, so a
  block built by an adapter and the same block round-tripped through XML
  compare equal. No derived/duplicated fields are stored.

      %{"type" => "text",         "text" => "…", "inlines" => [...]}
      %{"type" => "heading",      "level" => 1..6, "text" => "…"}
      %{"type" => "list",         "class" => "ordered"|"unordered",
                                  "items" => [%{"blocks" => [...], "marker" => "…"}]}
      %{"type" => "table",        "rows" => n, "cols" => n, "cells" => [cell],
                                  "caption" => "…"}
      %{"type" => "picture",      "src" => "uri"}
      %{"type" => "formula",      "text" => "latex"}
      %{"type" => "page_break"}
      %{"type" => "footnote",     "blocks" => [...]}
      %{"type" => "page_header",  "blocks" => [...]}   # and "page_footer"
      %{"type" => "group",        "thread_id" => n, "custom" => [[name, value]]}

      cell :: %{"row" => r, "col" => c, "row_span" => rs, "col_span" => cs,
                "header" => bool, "blocks" => [...]}

  Every block may additionally carry `"custom"` (an ORDERED list of
  `[name, value]` pairs — `writer/custom.rs` can emit `extra` more than once, so
  a map would lose data) and `"location"` (the four
  `<location value resolution/>` head elements, present only when the exporter
  ran with `with_location: true`).

  `"inlines"` is emitted only when the content carries markup; a plain run is
  described entirely by `"text"`. Inline nodes are binaries for plain runs,
  `%{"style" => "bold", "content" => [...]}` for style spans (the writer's
  canonical nesting order is bold → italic → underline → strikethrough →
  superscript → subscript), and `%{"href" => uri, "content" => [...]}` for links.

  ## Whitespace

  Character data inside inline content is preserved verbatim (spaces around
  `<bold>` are content). Whitespace-only character data BETWEEN block elements
  is discarded, so an agent may pretty-print the buffer without every block
  reading as edited. Non-whitespace character data in block position becomes an
  implicit paragraph rather than being dropped silently.
  """

  import Ecrits.Guards

  alias Doclang.Xml

  @version "0.6"

  @office_kinds [:docx, :pptx, :xlsx]

  @style_tags ~w(bold italic underline strikethrough superscript subscript)
  @otsl_anchor_tokens ~w(ched fcel ecel)
  @otsl_cover_tokens ~w(lcel ucel xcel)
  @otsl_tokens @otsl_anchor_tokens ++ @otsl_cover_tokens ++ ["nl"]
  @head_elements ~w(location custom thread caption)

  # Keys that describe children, not the node itself. Excluded from the shallow
  # identity test and from property diffing; the scan recurses into them.
  @child_keys ~w(blocks items cells)
  # Derived / non-editable. `location` only exists with `with_location: true`
  # (a full relayout) and is layout geometry, not an edit surface — its presence
  # or absence must never read as a property edit. `inlines` deliberately stays
  # IN the identity test so an inline-only formatting edit is detected (and
  # refused) rather than silently discarded.
  @derived_keys ~w(location)

  @typedoc "A canonical DocLang block (see the moduledoc)."
  @type block :: %{optional(String.t()) => term()}

  @typedoc "A canonical DocLang document."
  @type document :: %{required(String.t()) => term()}

  @typedoc "An inline node: a plain run, a style span, or a link."
  @type inline :: String.t() | %{optional(String.t()) => term()}

  @doc "The DocLang schema version this module reads and writes."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Whether `kind` routes to the office (UNO) adapter rather than the rhwp one."
  @spec office_kind?(atom()) :: boolean()
  def office_kind?(kind), do: kind in @office_kinds

  @doc "The adapter module for a document `kind`."
  @spec adapter(atom()) :: module()
  def adapter(kind) do
    if office_kind?(kind), do: Doclang.Adapter.Office, else: Doclang.Adapter.Hwp
  end

  # ── parse ─────────────────────────────────────────────────────────────────

  @doc """
  Parse DocLang v0.6 XML into a canonical, comparable document map.

  Returns `{:ok, %{"version" => v, "blocks" => [block]}}` or `{:error, reason}`.
  The output is canonical: adjacent character data is merged, absent fields are
  omitted rather than nil-filled, and inter-block whitespace is dropped — so
  `parse(x) == parse(to_xml(parse(x)))` holds and an untouched buffer diffs to
  no changes.
  """
  @spec parse(binary()) :: {:ok, document()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    case Xml.parse(xml) do
      {:ok, {:element, "doclang", attrs, children}} ->
        {:ok,
         %{
           "version" => Map.get(attrs, "version", @version),
           "blocks" => blocks_from(children)
         }}

      {:ok, {:element, name, _attrs, _children}} ->
        {:error, {:unexpected_root, name}}

      {:error, reason} ->
        {:error, {:malformed_xml, reason}}
    end
  end

  def parse(_xml), do: {:error, :not_a_binary}

  @doc "Like `parse/1` but returns only the block list."
  @spec parse_blocks(binary()) :: {:ok, [block()]} | {:error, term()}
  def parse_blocks(xml) do
    with {:ok, %{"blocks" => blocks}} <- parse(xml), do: {:ok, blocks}
  end

  # ── serialize ─────────────────────────────────────────────────────────────

  @doc """
  Serialize a canonical document (or a bare block list) back to DocLang v0.6
  XML, in the writer's element-head order: thread → location → caption →
  custom → content.
  """
  @spec to_xml(document() | [block()]) :: binary()
  def to_xml(%{"blocks" => blocks} = doc) do
    version = Map.get(doc, "version", @version)
    render_document(version, blocks)
  end

  def to_xml(blocks) when is_list(blocks), do: render_document(@version, blocks)

  defp render_document(version, blocks) do
    IO.iodata_to_binary([
      ~s(<doclang version="),
      Xml.escape_attr(to_string(version)),
      ~s(">),
      Enum.map(blocks, &render_block/1),
      "</doclang>"
    ])
  end

  # ── project ───────────────────────────────────────────────────────────────

  @doc """
  Project a document's live engine IR `nodes` to DocLang XML — the bytes the doc
  VFS mounts and the agent edits. Always `Mode::Preserve`.
  """
  @spec project([map()], atom()) :: binary()
  def project(nodes, kind) when is_list(nodes) do
    nodes |> adapter(kind).to_blocks() |> to_xml()
  end

  # ── diff ──────────────────────────────────────────────────────────────────

  @doc """
  Diff the LIVE `baseline` engine IR nodes against an edited DocLang buffer.

  Same two-cursor positional scan the JSONL projection runs today, made
  recursive over the block tree. Identity is `old == new` on the shallow
  (children-excluded) canonical block; the engine ref comes from the aligned
  live baseline node, never from `edited_xml`; anything that cannot be aligned
  returns `{:error, :structural_change}`.

  Returns the engine-neutral change tuples `Ecrits.Doc.Projection.apply_changes/3`
  already runs — `{:text, op, marker}`, `{:set, ref, type, props}`,
  `{:insert_table, op, marker}`, `{:insert_picture, op, marker, props}`,
  `{:delete_node, op, marker}` — or `{:error, reason}`.
  """
  @spec changes([map()], binary(), atom()) :: [tuple()] | {:error, term()}
  def changes(baseline, edited_xml, kind) when is_list(baseline) and is_binary(edited_xml) do
    with {:ok, new_blocks} <- parse_blocks(edited_xml) do
      adapter = adapter(kind)
      old = adapter.bindings(baseline)

      case scan(old, new_blocks, 0, 0, [], adapter) do
        {:ok, acc} -> Enum.reverse(acc)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  The ordered child blocks of a block, flattened across whatever container key
  holds them (`items` for lists, `cells` for tables, `blocks` otherwise). The
  scan descends through this, so a nested table's paragraphs are diffed exactly
  like top-level ones.
  """
  @spec child_blocks(block()) :: [block()]
  def child_blocks(%{"type" => "list", "items" => items}) when is_list(items),
    do: Enum.flat_map(items, &Map.get(&1, "blocks", []))

  def child_blocks(%{"type" => "table", "cells" => cells}) when is_list(cells),
    do: Enum.flat_map(cells, &Map.get(&1, "blocks", []))

  def child_blocks(%{"blocks" => blocks}) when is_list(blocks), do: blocks
  def child_blocks(%{}), do: []

  @doc """
  Build a baseline binding: one canonical block paired with the LIVE engine
  data the ref-less buffer omitted. `changes/3` walks these alongside the parsed
  buffer, so `:children` MUST be ordered exactly like `child_blocks/1` of the
  same block.

  Options: `:ref` (the engine ref — `nil` makes the node unroutable),
  `:type` (the engine's own node type, defaults to the block type),
  `:cell?` (route text edits through `set_cell`), `:node` (the raw IR node),
  `:children` (nested bindings).
  """
  @spec binding(block(), keyword()) :: map()
  def binding(block, opts \\ []) do
    %{
      block: block,
      ref: Keyword.get(opts, :ref),
      type: Keyword.get(opts, :type) || Map.get(block, "type"),
      cell?: Keyword.get(opts, :cell?, false),
      node: Keyword.get(opts, :node),
      children: Keyword.get(opts, :children, [])
    }
  end

  @doc """
  The block stripped of everything that belongs to its children — the unit the
  positional scan compares for identity. Table cell geometry and list item
  markers survive (they describe the node), cell/item CONTENT does not (the
  scan recurses into it).
  """
  @spec shallow(block()) :: block()
  def shallow(%{"type" => "table"} = block) do
    block
    |> Map.update("cells", [], fn cells ->
      Enum.map(cells, fn cell -> Map.delete(cell, "blocks") end)
    end)
    |> Map.drop(@derived_keys)
  end

  def shallow(%{"type" => "list"} = block) do
    block
    |> Map.update("items", [], fn items ->
      Enum.map(items, fn item -> Map.delete(item, "blocks") end)
    end)
    |> Map.drop(@derived_keys)
  end

  def shallow(%{} = block), do: block |> Map.drop(@child_keys) |> Map.drop(@derived_keys)

  @doc "Flatten a block's inline content to plain text."
  @spec text(block()) :: String.t()
  def text(%{"text" => text}) when is_binary(text), do: text
  def text(%{}), do: ""

  @doc """
  Look up a `<custom>` property by name. Returns the FIRST match; `extra` may
  legitimately repeat, so use `custom_props/2` for all of them.
  """
  @spec custom_prop(block(), String.t()) :: String.t() | nil
  def custom_prop(block, name), do: block |> custom_props(name) |> List.first()

  @doc "Every `<custom>` property value recorded under `name`, in document order."
  @spec custom_props(block(), String.t()) :: [String.t()]
  def custom_props(%{"custom" => pairs}, name) when is_list(pairs) do
    for [key, value] <- pairs, key == name, do: value
  end

  def custom_props(%{}, _name), do: []

  # ── parse: blocks ─────────────────────────────────────────────────────────

  defp blocks_from(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      {:element, _name, _attrs, _children} = element -> [block_from(element)]
      {:text, text} -> stray_text_block(text)
    end)
  end

  defp stray_text_block(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: [], else: [%{"type" => "text", "text" => trimmed}]
  end

  defp block_from({:element, "text", attrs, children}) do
    {head, content} = split_head(children)

    %{"type" => "text"}
    |> put_head(head)
    |> put_inline_content(content)
    |> put_extra_attrs(attrs, [])
  end

  defp block_from({:element, "heading", attrs, children}) do
    {head, content} = split_head(children)

    %{"type" => "heading", "level" => clamp_level(attrs["level"])}
    |> put_head(head)
    |> put_inline_content(content)
    |> put_extra_attrs(attrs, ["level"])
  end

  defp block_from({:element, "list", attrs, children}) do
    {head, content} = split_head(children)

    %{"type" => "list", "class" => Map.get(attrs, "class", "unordered")}
    |> put_head(head)
    |> Map.put("items", list_items(content))
    |> put_extra_attrs(attrs, ["class"])
  end

  defp block_from({:element, "table", attrs, children}) do
    {head, content} = split_head(children)

    %{"type" => "table"}
    |> put_head(head)
    |> Map.merge(table_grid(content))
    |> put_extra_attrs(attrs, [])
  end

  defp block_from({:element, "picture", attrs, children}) do
    {head, content} = split_head(children)

    src =
      Enum.find_value(content, fn
        {:element, "src", src_attrs, _} -> Map.get(src_attrs, "uri")
        _ -> nil
      end)

    %{"type" => "picture"}
    |> put_head(head)
    |> maybe_put("src", src)
    |> put_extra_attrs(attrs, [])
  end

  defp block_from({:element, "formula", attrs, children}) do
    {head, content} = split_head(children)

    %{"type" => "formula"}
    |> put_head(head)
    |> put_inline_content(content)
    |> put_extra_attrs(attrs, [])
  end

  defp block_from({:element, "page_break", attrs, _children}) do
    put_extra_attrs(%{"type" => "page_break"}, attrs, [])
  end

  defp block_from({:element, name, attrs, children})
       when name in ["footnote", "page_header", "page_footer"] do
    {head, content} = split_head(children)

    %{"type" => name}
    |> put_head(head)
    |> Map.put("blocks", blocks_from(content))
    |> put_extra_attrs(attrs, [])
  end

  defp block_from({:element, "group", attrs, children}) do
    {head, content} = split_head(children)
    nested = blocks_from(content)

    %{"type" => "group"}
    |> put_head(head)
    |> maybe_put("blocks", nested_or_nil(nested))
    |> put_extra_attrs(attrs, [])
  end

  # Forward compatibility: an element this reader does not know is kept whole
  # (name, attributes, children) rather than dropped, so a v0.7 buffer still
  # round-trips and still fails closed instead of silently losing content.
  defp block_from({:element, name, attrs, children}) do
    {head, content} = split_head(children)

    %{"type" => name}
    |> put_head(head)
    |> maybe_put("blocks", nested_or_nil(blocks_from(content)))
    |> put_extra_attrs(attrs, [])
  end

  defp nested_or_nil([]), do: nil
  defp nested_or_nil(blocks), do: blocks

  defp clamp_level(value) do
    case parse_int(value) do
      nil -> 1
      level -> level |> max(1) |> min(6)
    end
  end

  # ── parse: element head ───────────────────────────────────────────────────

  # `label → thread → xref/href → layer → location → caption → custom` is the
  # DocLang element-head order, but head members are unambiguous by name, so
  # they are lifted from anywhere in the child list. This tolerates a hand-edit
  # that moved a `<custom>` after the text it annotates.
  defp split_head(children) do
    {head, rest} =
      Enum.reduce(children, {%{}, []}, fn
        {:element, "location", attrs, _}, {head, rest} ->
          entry = %{
            "value" => parse_int(attrs["value"]),
            "resolution" => parse_int(attrs["resolution"])
          }

          {Map.update(head, "location", [entry], &(&1 ++ [entry])), rest}

        {:element, "custom", _attrs, kids}, {head, rest} ->
          {Map.update(head, "custom", custom_pairs(kids), &(&1 ++ custom_pairs(kids))), rest}

        {:element, "thread", attrs, _}, {head, rest} ->
          {Map.put(head, "thread_id", parse_int(attrs["thread_id"])), rest}

        {:element, "caption", _attrs, kids}, {head, rest} ->
          {Map.merge(head, caption_fields(kids)), rest}

        node, {head, rest} ->
          {head, [node | rest]}
      end)

    {head, Enum.reverse(rest)}
  end

  defp put_head(block, head) do
    Enum.reduce(head, block, fn {key, value}, acc -> maybe_put(acc, key, value) end)
  end

  # `<custom>` is `<xs:any>`: element-only, attribute-free. `writer/custom.rs`
  # emits `<hwp_prop name value/>` children and smuggles the namespace in as
  # `name="ns"`. Order matters and `extra` repeats, so this is a LIST of pairs.
  defp custom_pairs(children) do
    Enum.flat_map(children, fn
      {:element, "hwp_prop", attrs, _} ->
        [[Map.get(attrs, "name", ""), Map.get(attrs, "value", "")]]

      {:element, name, attrs, kids} ->
        [[name, Map.get(attrs, "value") || flatten_inlines(inlines_from(kids))]]

      {:text, _} ->
        []
    end)
  end

  defp caption_fields(children) do
    inlines = inlines_from(children)
    base = %{"caption" => flatten_inlines(inlines)}
    if plain_inlines?(inlines), do: base, else: Map.put(base, "caption_inlines", inlines)
  end

  # ── parse: lists ──────────────────────────────────────────────────────────

  # Per the schema `<ldiv>` is an item DELIMITER whose only child is an optional
  # `<marker>`; the item's blocks follow it as siblings inside `<list>`.
  defp list_items(content) do
    {items, current} =
      Enum.reduce(content, {[], nil}, fn
        {:element, "ldiv", _attrs, kids}, {items, current} ->
          {push_item(items, current), %{"blocks" => []} |> put_marker(kids)}

        {:element, _, _, _} = element, {items, current} ->
          item = current || %{"blocks" => []}
          {items, Map.update!(item, "blocks", &(&1 ++ [block_from(element)]))}

        {:text, text}, {items, current} ->
          case stray_text_block(text) do
            [] ->
              {items, current}

            [block] ->
              {items,
               Map.update(current || %{"blocks" => []}, "blocks", [block], &(&1 ++ [block]))}
          end
      end)

    items |> push_item(current) |> Enum.reverse()
  end

  defp push_item(items, nil), do: items
  defp push_item(items, item), do: [item | items]

  defp put_marker(item, kids) do
    marker =
      Enum.find_value(kids, fn
        {:element, "marker", _attrs, marker_kids} ->
          marker_kids |> inlines_from() |> flatten_inlines()

        _ ->
          nil
      end)

    maybe_put(item, "marker", marker)
  end

  # ── parse: OTSL tables ────────────────────────────────────────────────────

  # The token stream reconstructs a rows×cols grid: anchors (`ched`/`fcel`/
  # `ecel`) are followed by their block content; `lcel`/`ucel`/`xcel` mark
  # positions covered by a span; `nl` terminates a row. `ecel` is emitted both
  # for an empty anchor and for a hole in the geometry — indistinguishable on
  # read, so every `ecel` is treated as an empty anchor, which re-serializes to
  # the identical token.
  defp table_grid(content) do
    {grid, cells, row, col} =
      Enum.reduce(content, {%{}, [], 0, 0}, fn
        {:element, "nl", _, _}, {grid, cells, row, _col} ->
          {grid, cells, row + 1, 0}

        {:element, token, _, _}, {grid, cells, row, col} when token in @otsl_anchor_tokens ->
          cell = %{
            "row" => row,
            "col" => col,
            "header" => token == "ched",
            "blocks" => []
          }

          {Map.put(grid, {row, col}, :anchor), [cell | cells], row, col + 1}

        {:element, token, _, _}, {grid, cells, row, col} when token in @otsl_cover_tokens ->
          {Map.put(grid, {row, col}, String.to_atom(token)), cells, row, col + 1}

        {:element, _, _, _} = element, {grid, cells, row, col} ->
          {grid, prepend_to_current_cell(cells, block_from(element)), row, col}

        {:text, text}, {grid, cells, row, col} ->
          case stray_text_block(text) do
            [] -> {grid, cells, row, col}
            [block] -> {grid, prepend_to_current_cell(cells, block), row, col}
          end
      end)

    rows = if col > 0, do: row + 1, else: row
    cols = grid |> Map.keys() |> Enum.map(fn {_r, c} -> c + 1 end) |> Enum.max(fn -> 0 end)

    cells =
      cells
      |> Enum.reverse()
      |> Enum.map(&resolve_spans(&1, grid, rows, cols))

    %{"rows" => rows, "cols" => cols, "cells" => cells}
  end

  defp prepend_to_current_cell([], _block), do: []

  defp prepend_to_current_cell([cell | rest], block),
    do: [Map.update!(cell, "blocks", &(&1 ++ [block])) | rest]

  defp resolve_spans(%{"row" => row, "col" => col} = cell, grid, rows, cols) do
    col_span = 1 + count_run(grid, rows, cols, row, col + 1, {0, 1}, [:lcel, :xcel])
    row_span = 1 + count_run(grid, rows, cols, row + 1, col, {1, 0}, [:ucel, :xcel])

    cell
    |> Map.put("row_span", col_span_guard(row_span))
    |> Map.put("col_span", col_span_guard(col_span))
  end

  defp col_span_guard(value) when is_integer(value) and value > 0, do: value
  defp col_span_guard(_value), do: 1

  defp count_run(grid, rows, cols, row, col, {dr, dc}, tokens) do
    if row < rows and col < cols and Map.get(grid, {row, col}) in tokens do
      1 + count_run(grid, rows, cols, row + dr, col + dc, {dr, dc}, tokens)
    else
      0
    end
  end

  # ── parse: inlines ────────────────────────────────────────────────────────

  defp inlines_from(nodes) do
    nodes
    |> Enum.reduce([], fn node, acc ->
      case inline_from(node) do
        nil -> acc
        inline -> merge_inline(acc, inline)
      end
    end)
    |> Enum.reverse()
  end

  defp inline_from({:text, ""}), do: nil

  # DocLang never emits `xml:space="preserve"` (`writer/escape.rs`) — the adapter
  # trim-normalises paragraph whitespace, so the format treats element-content
  # whitespace as insignificant, and the writer puts the whole document on ONE
  # line with no indentation. A whitespace-only run that is a newline PLUS more
  # whitespace can therefore only be an editor's indentation, never content:
  # dropping it is what lets an agent reformat the buffer without every block
  # reading as edited. A bare "\n" is kept here — `Inline::LineBreak` lowers to
  # exactly that — and is only flattened away when it is a block's ENTIRE
  # content (see `put_inline_content/2`).
  defp inline_from({:text, text}) do
    if indentation?(text), do: nil, else: text
  end

  defp inline_from({:element, tag, _attrs, children}) when tag in @style_tags,
    do: %{"style" => tag, "content" => inlines_from(children)}

  defp inline_from({:element, "href", attrs, children}),
    do: %{"href" => Map.get(attrs, "uri", ""), "content" => inlines_from(children)}

  # An element in inline position that is neither a style nor a link (a stray
  # head element already lifted out, or a block that a hand-edit nested wrongly)
  # contributes its plain text so nothing vanishes.
  defp inline_from({:element, name, _attrs, children}) do
    if name in @head_elements or name in @otsl_tokens do
      nil
    else
      case children |> inlines_from() |> flatten_inlines() do
        "" -> nil
        text -> text
      end
    end
  end

  defp merge_inline([prev | acc], text) when is_binary(prev) and is_binary(text),
    do: [prev <> text | acc]

  defp merge_inline(acc, inline), do: [inline | acc]

  defp flatten_inlines(inlines) when is_list(inlines) do
    inlines |> Enum.map(&flatten_inline/1) |> IO.iodata_to_binary()
  end

  defp flatten_inline(text) when is_binary(text), do: text
  defp flatten_inline(%{"content" => content}), do: flatten_inlines(content)
  defp flatten_inline(_other), do: ""

  defp plain_inlines?([]), do: true
  defp plain_inlines?([text]) when is_binary(text), do: true
  defp plain_inlines?(_inlines), do: false

  defp put_inline_content(block, content) do
    inlines = content |> inlines_from() |> drop_blank_content()
    block = Map.put(block, "text", flatten_inlines(inlines))
    if plain_inlines?(inlines), do: block, else: Map.put(block, "inlines", inlines)
  end

  # A block whose entire content is whitespace carrying a newline is an empty
  # block that was pretty-printed (`<text></text>` -> `<text>\n</text>`).
  defp drop_blank_content([text]) when is_binary(text) do
    if String.trim(text) == "" and String.contains?(text, "\n"), do: [], else: [text]
  end

  defp drop_blank_content(inlines), do: inlines

  defp indentation?(text) do
    byte_size(text) > 1 and String.trim(text) == "" and String.contains?(text, "\n")
  end

  # ── parse: helpers ────────────────────────────────────────────────────────

  defp put_extra_attrs(block, attrs, consumed) do
    extra = Map.drop(attrs, consumed)
    if extra == %{}, do: block, else: Map.put(block, "attrs", extra)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  # ── render ────────────────────────────────────────────────────────────────

  defp render_block(%{"type" => "text"} = block),
    do: element("text", attrs_of(block), [head_io(block), inline_io(block)])

  defp render_block(%{"type" => "heading"} = block) do
    attrs = [{"level", to_string(Map.get(block, "level", 1))} | attrs_of(block)]
    element("heading", attrs, [head_io(block), inline_io(block)])
  end

  defp render_block(%{"type" => "list"} = block) do
    attrs = [{"class", Map.get(block, "class", "unordered")} | attrs_of(block)]
    items = Enum.map(Map.get(block, "items", []), &render_list_item/1)
    element("list", attrs, [head_io(block), items])
  end

  defp render_block(%{"type" => "table"} = block),
    do: element("table", attrs_of(block), [head_io(block), render_otsl(block)])

  defp render_block(%{"type" => "picture"} = block) do
    src =
      case Map.get(block, "src") do
        uri when is_binary(uri) -> [~s(<src uri="), Xml.escape_attr(uri), ~s("/>)]
        _ -> []
      end

    element("picture", attrs_of(block), [head_io(block), src])
  end

  defp render_block(%{"type" => "formula"} = block),
    do: element("formula", attrs_of(block), [head_io(block), inline_io(block)])

  defp render_block(%{"type" => "page_break"} = block),
    do: void("page_break", attrs_of(block))

  defp render_block(%{"type" => type} = block)
       when type in ["footnote", "page_header", "page_footer", "group"] do
    children = Map.get(block, "blocks", []) |> Enum.map(&render_block/1)
    element(type, attrs_of(block), [head_io(block), children])
  end

  defp render_block(%{"type" => type} = block) do
    children = Map.get(block, "blocks", []) |> Enum.map(&render_block/1)
    element(type, attrs_of(block), [head_io(block), children])
  end

  defp render_list_item(item) do
    ldiv =
      case Map.get(item, "marker") do
        text when is_present(text) ->
          element("ldiv", [], element("marker", [], Xml.escape_text(text)))

        _ ->
          void("ldiv", [])
      end

    [ldiv, Enum.map(Map.get(item, "blocks", []), &render_block/1)]
  end

  # Rebuilds the occupancy grid exactly as `writer/otsl.rs` does — first anchor
  # to claim a position wins — so a parsed table re-serializes byte-identically.
  defp render_otsl(block) do
    rows = Map.get(block, "rows", 0)
    cols = Map.get(block, "cols", 0)
    cells = Map.get(block, "cells", [])

    if rows <= 0 or cols <= 0 do
      []
    else
      {grid, _} =
        Enum.reduce(cells, {%{}, 0}, fn cell, {grid, index} ->
          {claim_cell(grid, cell, index, rows, cols), index + 1}
        end)

      indexed = cells |> Enum.with_index() |> Map.new(fn {cell, i} -> {i, cell} end)

      for row <- 0..(rows - 1) do
        [
          for col <- 0..(cols - 1) do
            render_otsl_token(Map.get(grid, {row, col}, :empty), indexed)
          end,
          "<nl/>"
        ]
      end
    end
  end

  defp claim_cell(grid, cell, index, rows, cols) do
    anchor_row = Map.get(cell, "row", 0)
    anchor_col = Map.get(cell, "col", 0)

    if anchor_row >= rows or anchor_col >= cols do
      grid
    else
      row_span = cell |> Map.get("row_span", 1) |> max(1) |> min(rows - anchor_row)
      col_span = cell |> Map.get("col_span", 1) |> max(1) |> min(cols - anchor_col)

      for row <- anchor_row..(anchor_row + row_span - 1),
          col <- anchor_col..(anchor_col + col_span - 1),
          reduce: grid do
        acc ->
          cond do
            Map.has_key?(acc, {row, col}) ->
              acc

            row == anchor_row and col == anchor_col ->
              Map.put(acc, {row, col}, {:anchor, index})

            true ->
              Map.put(acc, {row, col}, {:cover, col > anchor_col, row > anchor_row})
          end
      end
    end
  end

  defp render_otsl_token(:empty, _cells), do: "<ecel/>"
  defp render_otsl_token({:cover, true, true}, _cells), do: "<xcel/>"
  defp render_otsl_token({:cover, true, false}, _cells), do: "<lcel/>"
  defp render_otsl_token({:cover, false, true}, _cells), do: "<ucel/>"
  defp render_otsl_token({:cover, false, false}, _cells), do: "<ecel/>"

  defp render_otsl_token({:anchor, index}, cells) do
    cell = Map.fetch!(cells, index)
    blocks = Map.get(cell, "blocks", [])

    token =
      cond do
        Map.get(cell, "header") == true -> "<ched/>"
        blocks == [] -> "<ecel/>"
        true -> "<fcel/>"
      end

    [token, Enum.map(blocks, &render_block/1)]
  end

  # Element-head order: thread → location → caption → custom.
  defp head_io(block) do
    [
      case Map.get(block, "thread_id") do
        id when is_integer(id) -> [~s(<thread thread_id="), Integer.to_string(id), ~s("/>)]
        _ -> []
      end,
      case Map.get(block, "location") do
        entries when is_list(entries) -> Enum.map(entries, &render_location/1)
        _ -> []
      end,
      case Map.get(block, "caption") do
        caption when is_binary(caption) ->
          element("caption", [], caption_io(block, caption))

        _ ->
          []
      end,
      case Map.get(block, "custom") do
        [_ | _] = pairs -> element("custom", [], Enum.map(pairs, &render_hwp_prop/1))
        _ -> []
      end
    ]
  end

  defp caption_io(block, caption) do
    case Map.get(block, "caption_inlines") do
      inlines when is_list(inlines) -> render_inlines(inlines)
      _ -> Xml.escape_text(caption)
    end
  end

  defp render_location(%{"value" => value, "resolution" => resolution}) do
    [
      ~s(<location value="),
      to_string(value),
      ~s(" resolution="),
      to_string(resolution),
      ~s("/>)
    ]
  end

  defp render_location(_entry), do: []

  defp render_hwp_prop([name, value]) do
    [
      ~s(<hwp_prop name="),
      Xml.escape_attr(to_string(name)),
      ~s(" value="),
      Xml.escape_attr(to_string(value)),
      ~s("/>)
    ]
  end

  defp render_hwp_prop(_pair), do: []

  defp inline_io(block) do
    case Map.get(block, "inlines") do
      inlines when is_list(inlines) -> render_inlines(inlines)
      _ -> block |> Map.get("text", "") |> Xml.escape_text()
    end
  end

  defp render_inlines(inlines), do: Enum.map(inlines, &render_inline/1)

  defp render_inline(text) when is_binary(text), do: Xml.escape_text(text)

  defp render_inline(%{"style" => tag, "content" => content}),
    do: element(tag, [], render_inlines(content))

  defp render_inline(%{"href" => uri, "content" => content}),
    do: element("href", [{"uri", uri}], render_inlines(content))

  defp render_inline(_inline), do: []

  defp attrs_of(block) do
    case Map.get(block, "attrs") do
      %{} = attrs -> attrs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> {k, v} end)
      _ -> []
    end
  end

  # DocLang's writer NEVER collapses a content-bearing element to a self-closing
  # tag — `<text></text>` is how it writes an empty paragraph, and empty
  # paragraphs are everywhere in a real HWP document. Only the genuinely void
  # elements (`page_break`, `ldiv`, `src`, `location`, `hwp_prop`, `thread` and
  # the OTSL tokens) self-close, so byte-level agreement with rhwp_core's own
  # output is preserved.
  defp element(name, attrs, children),
    do: ["<", name, attr_io(attrs), ">", children, "</", name, ">"]

  defp void(name, attrs), do: ["<", name, attr_io(attrs), "/>"]

  defp attr_io(attrs) do
    Enum.map(attrs, fn {k, v} -> [" ", k, ~s(="), Xml.escape_attr(to_string(v)), ~s(")] end)
  end

  # ── diff: the two-cursor positional scan, recursive ───────────────────────

  defp scan(old, new, old_index, new_index, acc, adapter) do
    old_done? = old_index >= length(old)
    new_done? = new_index >= length(new)

    cond do
      old_done? and new_done? ->
        {:ok, acc}

      new_done? ->
        with {:ok, delete} <- delete_change(Enum.at(old, old_index)) do
          scan(old, new, old_index + 1, new_index, [delete | acc], adapter)
        end

      old_done? ->
        with {:ok, insert} <-
               insert_change(Enum.at(new, new_index), anchor(adapter, old, old_index)) do
          scan(old, new, old_index, new_index + 1, [insert | acc], adapter)
        end

      true ->
        old_binding = Enum.at(old, old_index)
        new_block = Enum.at(new, new_index)

        cond do
          # DELETE is tested first. Now that `text` is insertable, a removed
          # picture (old=picture, new=text) also satisfies "insertable new block
          # of a different type", so a greedy insert branch would claim it and
          # emit an insert_text instead of the delete — then fail to realign.
          # Delete already proves itself with `aligns_after_delete?`, so letting
          # it win when it holds is both safe and unambiguous.
          deletable?(old_binding) and not same_identity?(old_binding.block, new_block) and
              aligns_after_delete?(old, old_index, new_block) ->
            with {:ok, delete} <- delete_change(old_binding) do
              scan(old, new, old_index + 1, new_index, [delete | acc], adapter)
            end

          # A type change is proof of an insert on its own (a table cannot be an
          # edit of a paragraph). A SAME-type insert — the new-paragraph case —
          # needs both halves of the mirror: this pair must not already match,
          # and skipping the new block must realign the old cursor. Requiring the
          # mismatch matters because this document class has long runs of empty
          # `<text></text>`, and without it every one of them would look like an
          # insert point.
          insertable?(new_block) and
              (not same_type?(old_binding, new_block) or
                 (not same_identity?(old_binding.block, new_block) and
                    aligns_after_insert?(old_binding, new, new_index))) ->
            with {:ok, insert} <- insert_change(new_block, anchor(adapter, old, old_index)) do
              scan(old, new, old_index, new_index + 1, [insert | acc], adapter)
            end

          true ->
            case node_changes(old_binding, new_block, adapter) do
              {:ok, node_changes} ->
                scan(
                  old,
                  new,
                  old_index + 1,
                  new_index + 1,
                  Enum.reverse(node_changes) ++ acc,
                  adapter
                )

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  # Self changes first, then the same scan one level down. A nested table's
  # cells are diffed by exactly the same rules as the body.
  defp node_changes(binding, new_block, adapter) do
    old_block = binding.block

    cond do
      Map.get(old_block, "type") != Map.get(new_block, "type") ->
        {:error, :structural_change}

      true ->
        with {:ok, self_changes} <- self_changes(binding, new_block) do
          case scan(
                 Map.get(binding, :children, []),
                 child_blocks(new_block),
                 0,
                 0,
                 [],
                 adapter
               ) do
            {:ok, child_acc} -> {:ok, self_changes ++ Enum.reverse(child_acc)}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp self_changes(binding, new_block) do
    old_shallow = shallow(binding.block)
    new_shallow = shallow(new_block)

    cond do
      old_shallow == new_shallow ->
        {:ok, []}

      is_nil(binding.ref) ->
        {:error, :unroutable}

      true ->
        with {:ok, text_change} <- text_change(binding, old_shallow, new_shallow),
             {:ok, prop_change} <- prop_change(binding, old_shallow, new_shallow) do
          {:ok, Enum.reject([text_change, prop_change], &is_nil/1)}
        end
    end
  end

  defp text_change(binding, old_shallow, new_shallow) do
    old_text = Map.get(old_shallow, "text")
    new_text = Map.get(new_shallow, "text")
    ref = binding.ref

    cond do
      old_text == new_text ->
        inline_only_guard(old_shallow, new_shallow)

      Map.get(binding, :cell?, false) and is_binary(new_text) ->
        {:ok, {:text, %{"op" => "set_cell", "ref" => ref, "text" => new_text}, new_text}}

      not (is_binary(old_text) and is_binary(new_text)) ->
        {:error, :unroutable}

      old_text == "" ->
        {:ok, {:text, %{"op" => "insert_text", "ref" => ref, "text" => new_text}, new_text}}

      true ->
        {:ok,
         {:text,
          %{
            "op" => "replace_text",
            "ref" => ref,
            "query" => old_text,
            "replacement" => new_text
          }, new_text}}
    end
  end

  # Inline formatting has no write-back route in v1 (the JSONL projection never
  # exposed one either). Fail closed rather than silently discarding the edit.
  defp inline_only_guard(old_shallow, new_shallow) do
    if Map.get(old_shallow, "inlines") == Map.get(new_shallow, "inlines") do
      {:ok, nil}
    else
      {:error, {:unsupported_edit, :inline_formatting}}
    end
  end

  defp prop_change(binding, old_shallow, new_shallow) do
    props =
      Map.merge(
        changed_top_level(old_shallow, new_shallow),
        changed_custom(old_shallow, new_shallow)
      )

    if props == %{} do
      {:ok, nil}
    else
      {:ok, {:set, binding.ref, binding.type, props}}
    end
  end

  @non_property_keys ~w(type text inlines custom location caption_inlines attrs)

  defp changed_top_level(old_shallow, new_shallow) do
    old_shallow
    |> Map.keys()
    |> Kernel.++(Map.keys(new_shallow))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @non_property_keys or &1 in @child_keys))
    |> Enum.filter(&(Map.get(old_shallow, &1) != Map.get(new_shallow, &1)))
    |> Map.new(fn key -> {key, Map.get(new_shallow, key)} end)
  end

  # `<custom>` carries the Preserve-mode properties (named_style, font_name,
  # font_size, text_color, section_info, extra). A changed pair becomes a plain
  # property write keyed by its name; `ns` is provenance, never an edit.
  defp changed_custom(old_shallow, new_shallow) do
    old_map = custom_map(old_shallow)
    new_map = custom_map(new_shallow)

    old_map
    |> Map.keys()
    |> Kernel.++(Map.keys(new_map))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "ns"))
    |> Enum.filter(&(Map.get(old_map, &1) != Map.get(new_map, &1)))
    |> Enum.filter(&Map.has_key?(new_map, &1))
    |> Map.new(fn key -> {key, Map.get(new_map, key)} end)
  end

  defp custom_map(%{"custom" => pairs}) when is_list(pairs) do
    Enum.reduce(pairs, %{}, fn
      [name, value], acc -> Map.update(acc, name, value, &join_custom(&1, value))
      _other, acc -> acc
    end)
  end

  defp custom_map(_block), do: %{}

  defp join_custom(existing, value) when is_binary(existing), do: existing <> ";" <> value
  defp join_custom(existing, _value), do: existing

  # ── diff: insert / delete classification ──────────────────────────────────

  defp insertable?(%{"type" => type}), do: type in ["table", "picture", "text", "heading"]
  defp insertable?(_block), do: false

  defp same_type?(binding, new_block),
    do: Map.get(binding.block, "type") == Map.get(new_block, "type")

  defp deletable?(%{block: %{"type" => "picture"}, ref: ref}) when not is_nil(ref), do: true

  defp deletable?(%{block: %{"type" => type}, ref: ref})
       when type in ["text", "heading"] and not is_nil(ref),
       do: true

  defp deletable?(_binding), do: false

  defp same_identity?(%{"type" => "picture"} = old, %{"type" => "picture"} = new),
    do: Map.get(old, "src") == Map.get(new, "src")

  defp same_identity?(old, new), do: shallow(old) == shallow(new)

  defp aligns_after_delete?(old, old_index, new_block) do
    case Enum.at(old, old_index + 1) do
      nil -> false
      next -> same_identity?(next.block, new_block)
    end
  end

  # Mirror of `aligns_after_delete?/3` for a NEW block whose type matches its
  # neighbour's.
  #
  # `table`/`picture` inserts are recognised by type alone — a table appearing
  # where a paragraph was cannot be anything but an insert. A new `<text>` has no
  # such tell: it looks exactly like an edit of the paragraph that was there. Take
  # the insert branch ONLY when skipping this one new block makes the old cursor
  # line up again, i.e. the old block reappears as the NEXT new block. Without
  # that lookahead a single inserted paragraph would be read as an edit of every
  # paragraph after it, and one insert would rewrite the rest of the document.
  defp aligns_after_insert?(old_binding, new, new_index) do
    case Enum.at(new, new_index + 1) do
      nil -> false
      next -> same_identity?(old_binding.block, next)
    end
  end

  defp anchor(adapter, old, old_index), do: adapter.insertion_anchor(old, old_index)

  defp insert_change(%{"type" => "table"} = block, anchor) do
    rows = Map.get(block, "rows", 0)
    cols = Map.get(block, "cols", 0)
    cells = table_cell_text(block)

    if rows > 0 and cols > 0 do
      op =
        %{"op" => "insert_table", "ref" => anchor, "rows" => rows, "cols" => cols}
        |> put_nonempty("cells", cells)

      {:ok, {:insert_table, op, first_cell_marker(cells)}}
    else
      {:error, {:invalid_table_payload, "table payload needs positive rows/cols"}}
    end
  end

  defp insert_change(%{"type" => "picture"} = block, anchor) do
    case Map.get(block, "src") do
      src when is_present(src) ->
        op = %{"op" => "insert_picture", "ref" => anchor, "src" => src}
        {:ok, {:insert_picture, op, src, custom_map(block)}}

      _ ->
        {:error, {:invalid_picture_payload, "picture payload needs a <src uri=…/>"}}
    end
  end

  # A NEW body paragraph. There is no `insert_paragraph` verb on the browser arm —
  # its whole vocabulary is insert_text / replace_text / delete_range / set_cell —
  # but a paragraph break inside `insert_text` genuinely splits the paragraph.
  # Measured live against a real Korean HWP: `insert_text` of "\nPROBE" at the
  # anchor took the document from 870 to 871 paragraphs and produced a new node,
  # with the following paragraphs shifted, so this needs no engine change.
  #
  # The anchor is the END of the preceding block (`insertion_anchor/2`), so the
  # break goes FIRST: the new text lands in the paragraph that break opens.
  defp insert_change(%{"type" => type} = block, anchor) when type in ["text", "heading"] do
    new_text = text(block)
    op = %{"op" => "insert_text", "ref" => anchor, "text" => "\n" <> new_text}
    {:ok, {:text, op, new_text}}
  end

  defp insert_change(_block, _anchor), do: {:error, :structural_change}

  defp delete_change(%{block: %{"type" => "picture"} = block, ref: ref}) when not is_nil(ref),
    do: {:ok, {:delete_node, %{"op" => "delete_node", "ref" => ref}, Map.get(block, "src")}}

  # Removing a body paragraph. `delete_range` cannot do this: it is intra-paragraph
  # by construction (`Paragraph::delete_text_at` clamps to the paragraph length), and
  # it used to report `ok:true` for a request clamped to nothing — a silent no-op the
  # host could not detect. Upstream now reports the real deleted count and refuses an
  # over-run, and routes a dedicated `delete_paragraph` verb to the engine's
  # `deleteParagraph`, which is what actually removes the break.
  defp delete_change(%{block: %{"type" => type} = block, ref: ref})
       when type in ["text", "heading"] and not is_nil(ref) do
    {:ok, {:delete_node, %{"op" => "delete_paragraph", "ref" => ref}, text(block)}}
  end

  defp delete_change(_binding), do: {:error, :structural_change}

  defp table_cell_text(block) do
    rows = Map.get(block, "rows", 0)
    cols = Map.get(block, "cols", 0)
    cells = Map.get(block, "cells", [])

    if rows <= 0 or cols <= 0 do
      []
    else
      by_position =
        Map.new(cells, fn cell ->
          {{Map.get(cell, "row", 0), Map.get(cell, "col", 0)}, cell_text(cell)}
        end)

      for row <- 0..(rows - 1) do
        for col <- 0..(cols - 1), do: Map.get(by_position, {row, col}, "")
      end
    end
  end

  defp cell_text(cell) do
    cell
    |> Map.get("blocks", [])
    |> Enum.map(&text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp first_cell_marker(cells) do
    cells |> List.flatten() |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)
end
