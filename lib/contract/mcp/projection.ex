defmodule Contract.MCP.Projection do
  @moduledoc """
  Adapter from `Contract.Runtime.State` projection (node-graph) to the flat
  `sections → paragraphs` shape used by the document MCP projection helpers.

  ## Source of truth

  R2 is the canonical source. At snapshot time the client uploads both
  the native HWP/HWPX visual snapshot (`<rev>.hwp` or `<rev>.hwpx`) and the extracted agent IR
  (`<rev>.ir.json`); projection helpers read the `.ir.json` blob via the
  S3-compatible client (`Contract.IO.R2.get/2`) when deriving slices for
  `doc.get`, `doc.read`, and `doc.find`. Postgres
  `rhwp_snapshots.projection` stays as a hot cache that's used when R2 is
  unreachable.

  The snapshotted IR is the base the agent reads. Text edits committed
  after that snapshot are overlaid for the compact MCP view so an agent
  can re-fetch after a revision-pinned edit and keep using current field
  offsets until the browser publishes the next native rhwp snapshot.

  Before the first rhwp snapshot for typed templates, falls back to the
  template editable spec so agents can still discover writable text slots.

  Table paragraphs keep their nested cell paragraphs so agents can copy a
  `cell_path` from `doc.read` and feed it back into `doc.edit`.
  """

  import Ecto.Query
  require Logger

  alias Contract.Change
  alias Contract.Repo
  alias Contract.Runtime.State

  @paragraph_window_default 3
  @paragraph_window_max 3
  @text_window_default 400
  @text_window_max 1_000
  @table_row_default 2
  @table_col_default 2
  @table_axis_max 3
  @preview_chars 160

  @doc """
  Build the agent-IR map used by doc.get/doc.read/doc.find. Returns a plain
  map with stringified keys + the current revision baked in.

  When no real rhwp snapshot row exists, this returns the legacy IR
  projection without writing snapshot rows. `doc.get` only exposes
  metadata/read hints derived from this IR, so a missing R2 snapshot is not a
  reason to create a fake visual snapshot record.
  """
  @spec to_agent_ir(State.t()) :: map()
  def to_agent_ir(%State{} = state) do
    case latest_rhwp_snapshot(state) do
      %Contract.RhwpSnapshot.Record{} = snap ->
        snapshot_ir =
          case fetch_ir_from_r2(snap) do
            {:ok, ir} when is_map(ir) and map_size(ir) > 0 ->
              from_snapshot(ir, state)

            _ ->
              from_db_projection(snap, state)
          end

        overlay_post_snapshot_text(snapshot_ir, state.document_id, snap.revision)

      nil ->
        case from_template_editables(state) do
          nil -> empty_ir(state)
          ir -> overlay_post_snapshot_text(ir, state.document_id, 0)
        end
    end
  end

  @doc """
  Fail-closed guard for MCP text edits that rely on the rhwp projection as
  their coordinate basis.

  A latest snapshot marked incomplete/stale is not safe to edit against. A
  same-revision snapshot also has to prove it includes already committed text
  ops for that revision; otherwise the MCP view can be shorter than the native
  document and generate destructive ranges.
  """
  @spec validate_text_edit_basis(State.t()) :: :ok | {:error, {:invalid_params, binary()}}
  def validate_text_edit_basis(%State{} = state) do
    case latest_rhwp_snapshot(state) do
      %Contract.RhwpSnapshot.Record{} = snap ->
        with {:ok, raw_ir} <- snapshot_raw_ir(snap),
             :ok <- validate_projection_basis(raw_ir, "latest"),
             :ok <- validate_same_revision_text_basis(snap, state, raw_ir) do
          :ok
        end

      nil ->
        :ok
    end
  end

  @doc """
  Target-scoped sibling for `doc.edit`.

  A stale same-revision snapshot elsewhere in the document should not block a
  localized `doc.edit` whose target was not touched by the unmaterialized text
  ops.
  """
  @spec validate_text_edit_basis(State.t(), [map()]) ::
          :ok | {:error, {:invalid_params, binary()}}
  def validate_text_edit_basis(%State{} = state, pending_ops) when is_list(pending_ops) do
    case validate_text_edit_basis(state) do
      :ok ->
        :ok

      {:error, {:invalid_params, "same-revision projection basis" <> _} = reason} ->
        if pending_ops_disjoint_from_unmaterialized_text?(state, pending_ops) do
          :ok
        else
          {:error, reason}
        end

      other ->
        other
    end
  end

  def validate_text_edit_basis(%State{} = state, _pending_ops),
    do: validate_text_edit_basis(state)

  defp snapshot_raw_ir(%Contract.RhwpSnapshot.Record{} = snap) do
    case fetch_ir_from_r2(snap) do
      {:ok, ir} when is_map(ir) and map_size(ir) > 0 ->
        {:ok, ir}

      _ ->
        case snap.projection do
          %{} = projection when map_size(projection) > 0 -> {:ok, projection}
          _ -> {:ok, %{}}
        end
    end
  end

  defp validate_projection_basis(%{} = raw_ir, label) do
    case map_value(raw_ir, "basis") do
      %{} = basis ->
        status = map_value(basis, "status")
        complete? = map_value(basis, "complete")

        cond do
          status in ["incomplete", "stale"] ->
            {:error,
             {:invalid_params,
              "#{label} projection basis is #{status}; refusing doc.edit until the snapshot is complete"}}

          complete? == false ->
            {:error,
             {:invalid_params,
              "#{label} projection basis is incomplete; refusing doc.edit until the snapshot is complete"}}

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp validate_same_revision_text_basis(
         %Contract.RhwpSnapshot.Record{document_id: document_id, revision: revision} = snap,
         %State{} = state,
         raw_ir
       )
       when is_binary(document_id) and is_integer(revision) do
    case previous_rhwp_snapshot(snap) do
      %Contract.RhwpSnapshot.Record{} = previous ->
        ops = text_ops_between(document_id, previous.revision, revision)

        cond do
          ops == [] ->
            :ok

          true ->
            with {:ok, previous_raw_ir} <- snapshot_raw_ir(previous),
                 :ok <- validate_projection_basis(previous_raw_ir, "previous") do
              expected =
                previous_raw_ir
                |> from_snapshot(state)
                |> overlay_text_ops(ops)

              current = from_snapshot(raw_ir, state)

              if document_text_index(expected) == document_text_index(current) do
                :ok
              else
                {:error,
                 {:invalid_params,
                  "same-revision projection basis is stale or missing committed text ops; refusing doc.edit"}}
              end
            end
        end

      nil ->
        case text_ops_between(document_id, 0, revision) do
          [] ->
            :ok

          _ops ->
            {:error,
             {:invalid_params,
              "same-revision projection basis cannot be verified against committed text ops; refusing doc.edit"}}
        end
    end
  end

  defp validate_same_revision_text_basis(_snap, _state, _raw_ir), do: :ok

  defp pending_ops_disjoint_from_unmaterialized_text?(%State{} = state, pending_ops) do
    with %Contract.RhwpSnapshot.Record{} = snap <- latest_rhwp_snapshot(state),
         %Contract.RhwpSnapshot.Record{} = previous <- previous_rhwp_snapshot(snap) do
      changed_keys =
        snap.document_id
        |> text_ops_between(previous.revision, snap.revision)
        |> text_op_keys()

      pending_keys = text_op_keys(pending_ops)

      changed_keys != MapSet.new() and MapSet.disjoint?(changed_keys, pending_keys)
    else
      _ -> false
    end
  end

  defp previous_rhwp_snapshot(%Contract.RhwpSnapshot.Record{
         document_id: document_id,
         revision: revision,
         format: format
       })
       when is_binary(document_id) and is_integer(revision) do
    Repo.one(
      from s in Contract.RhwpSnapshot.Record,
        where: s.document_id == ^document_id and s.format == ^format and s.revision < ^revision,
        order_by: [desc: s.revision],
        limit: 1
    )
  end

  defp previous_rhwp_snapshot(_snap), do: nil

  defp empty_ir(%State{} = state) do
    %{
      "title" => Map.get(state.projection, :title),
      "revision" => state.revision,
      "contract_type" => Map.get(state.projection, :type_key),
      "sections" => [],
      "fields" => []
    }
  end

  defp from_template_editables(%State{} = state) do
    with type_key when is_binary(type_key) and type_key != "" <-
           map_value(state.projection, "type_key") || map_value(state.projection, "contract_type"),
         {:ok, spec} <- Contract.ContractTypes.get(type_key),
         template_path when is_binary(template_path) and template_path != "" <-
           template_path(spec),
         {:ok, editables} <- load_editables(template_path),
         fields = editables |> editable_body_fields() |> add_aggregate_editable_fields(),
         true <- fields != [] do
      sections = editable_body_sections(fields)

      %{
        "title" =>
          map_value(state.projection, "title") || Contract.ContractTypes.display_name(type_key),
        "revision" => state.revision,
        "contract_type" => type_key,
        "template_path" => template_path,
        "sections" => sections,
        "fields" => fields
      }
      |> refresh_field_values()
    else
      _ -> nil
    end
  end

  defp template_path(%{template_hwp_path: path}) when is_binary(path) and path != "", do: path
  defp template_path(%{template_hwpx_path: path}) when is_binary(path) and path != "", do: path
  defp template_path(_spec), do: nil

  defp load_editables(template_path) do
    template_path
    |> editable_spec_path()
    |> priv_static_path()
    |> File.read()
    |> case do
      {:ok, body} ->
        with {:ok, %{"editables" => editables}} when is_list(editables) <- Jason.decode(body) do
          {:ok, editables}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp editable_spec_path(template_path) do
    Regex.replace(~r/\.(hwp|hwpx)$/i, template_path, ".editables.json")
  end

  defp priv_static_path("/" <> path) do
    :contract
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("static")
    |> Path.join(path)
  end

  defp priv_static_path(path), do: path

  defp editable_body_fields(editables) do
    editables
    |> Enum.flat_map(fn editable ->
      case editable_body_field(editable) do
        nil -> []
        field -> [field]
      end
    end)
  end

  defp editable_body_field(%{} = editable) do
    with %{} = position <- map_value(editable, "position"),
         %{} = start_pos <- map_value(position, "start"),
         %{} = end_pos <- map_value(position, "end"),
         sec when is_integer(sec) <- map_value(start_pos, "sectionIndex"),
         para when is_integer(para) <- map_value(start_pos, "paragraphIndex"),
         off_start when is_integer(off_start) <- map_value(start_pos, "charOffset"),
         off_end when is_integer(off_end) <- map_value(end_pos, "charOffset"),
         id when is_binary(id) and id != "" <- map_value(editable, "id") do
      %{
        "id" => id,
        "label" => map_value(editable, "label") || id,
        "kind" => map_value(editable, "kind") || "text_field",
        "value" => "",
        "position" => %{
          "sec" => sec,
          "para" => para,
          "off_start" => off_start,
          "off_end" => max(off_end, off_start)
        }
      }
    else
      _ -> nil
    end
  end

  defp editable_body_field(_editable), do: nil

  defp add_aggregate_editable_fields(fields) do
    case contract_period_pair(fields) do
      {%{"position" => start_pos}, %{"position" => end_pos}} ->
        if start_pos["sec"] == end_pos["sec"] and start_pos["para"] == end_pos["para"] do
          aggregate = %{
            "id" => "contract_period",
            "label" => "계약기간",
            "kind" => "text_field",
            "value" => "",
            "position" => %{
              "sec" => start_pos["sec"],
              "para" => start_pos["para"],
              "off_start" => start_pos["off_start"],
              "off_end" => end_pos["off_end"] + String.length("까지")
            }
          }

          [aggregate | fields]
        else
          fields
        end

      _ ->
        fields
    end
  end

  defp editable_body_sections(fields) do
    fields
    |> Enum.group_by(&get_in(&1, ["position", "sec"]))
    |> Enum.map(fn {sec, section_fields} ->
      paragraphs =
        section_fields
        |> Enum.group_by(&get_in(&1, ["position", "para"]))
        |> Enum.map(fn {para, paragraph_fields} ->
          %{
            "idx" => para,
            "text" => editable_paragraph_text(paragraph_fields)
          }
        end)
        |> Enum.sort_by(& &1["idx"])

      %{"idx" => sec, "paragraphs" => paragraphs}
    end)
    |> Enum.sort_by(& &1["idx"])
  end

  defp editable_paragraph_text(fields) do
    text =
      fields
      |> Enum.map(&(get_in(&1, ["position", "off_end"]) || 0))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(8)
      |> blank_text()

    case contract_period_pair(fields) do
      {start_field, end_field} ->
        start_pos = start_field["position"]
        end_pos = end_field["position"]

        text
        |> put_text(0, " ◇ 계약기간  :")
        |> put_text(start_pos["off_end"], "부터")
        |> put_text(end_pos["off_end"], "까지")

      nil ->
        Enum.reduce(fields, text, fn field, acc ->
          off =
            max(
              (get_in(field, ["position", "off_start"]) || 0) - String.length(field["label"]),
              0
            )

          put_text(acc, off, field["label"])
        end)
    end
  end

  defp contract_period_pair(fields) do
    start_field =
      Enum.find(fields, fn field ->
        field["id"] == "service_contract_start_date" or field["label"] == "계약기간 시작일"
      end)

    end_field =
      Enum.find(fields, fn field ->
        field["id"] == "service_contract_end_date" or field["label"] == "계약기간 종료일"
      end)

    if start_field && end_field, do: {start_field, end_field}
  end

  defp blank_text(length) when length > 0 do
    1..length
    |> Enum.map(fn _ -> " " end)
    |> Enum.join()
  end

  defp blank_text(_length), do: ""

  defp put_text(text, off, value) when is_binary(text) and is_integer(off) and is_binary(value) do
    length = String.length(text)
    off = clamp(off, 0, length)
    value_length = String.length(value)

    String.slice(text, 0, off) <>
      value <> String.slice(text, min(off + value_length, length), length)
  end

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end

  defp latest_rhwp_snapshot(%State{} = state) do
    Contract.RhwpSnapshot.latest_for_document(state.document_id, snapshot_format_for_state(state))
  end

  defp snapshot_format_for_state(%State{projection: projection}) do
    with type_key when is_binary(type_key) and type_key != "" <-
           map_value(projection, "type_key") || map_value(projection, "contract_type"),
         {:ok, spec} <- Contract.ContractTypes.get(type_key) do
      template_format(spec)
    else
      _ -> nil
    end
  end

  defp template_format(%{template_hwp_path: path}) when is_binary(path) and path != "", do: "hwp"

  defp template_format(%{template_hwpx_path: path}) when is_binary(path) and path != "",
    do: "hwpx"

  defp template_format(_spec), do: nil

  defp fetch_ir_from_r2(%Contract.RhwpSnapshot.Record{ir_r2_key: ir_key})
       when is_binary(ir_key) do
    with {:ok, body} <- r2_driver().get(ir_key),
         {:ok, ir} <- Jason.decode(body) do
      {:ok, ir}
    else
      err ->
        Logger.debug("doc.get: R2 IR fetch failed for #{ir_key}: #{inspect(err)}")
        err
    end
  end

  defp fetch_ir_from_r2(_), do: {:error, :no_key}

  # When R2 fetch fails, fall back to the snapshot row's cached `projection`
  # column (a hot copy of the same IR). If even that's empty we return an
  # empty IR — no legacy node-graph reconstruction.
  defp from_db_projection(
         %Contract.RhwpSnapshot.Record{projection: %{} = snap},
         %State{} = state
       )
       when map_size(snap) > 0,
       do: from_snapshot(snap, state)

  defp from_db_projection(_snap, %State{} = state), do: empty_ir(state)

  defp from_snapshot(snap, %State{} = state) do
    %{
      "title" => Map.get(snap, "title") || Map.get(state.projection, :title),
      "revision" => state.revision,
      "contract_type" => Map.get(snap, "contract_type") || Map.get(state.projection, :type_key),
      "sections" => normalize_sections(Map.get(snap, "sections", [])),
      "fields" => Map.get(snap, "fields", []) |> List.wrap()
    }
  end

  # ---------------------------------------------------------------------------
  # Outline / find / read — slim agent-facing slices of the IR.
  # ---------------------------------------------------------------------------

  # Korean clause/section headings. Documents flatten everything to plain
  # paragraphs with kind=nil, so we identify headings heuristically:
  # short lines that begin with 제 N 조 / 장 / 절 / 항.
  @heading_re ~r/^\s*제\s*[0-9０-９]+\s*[조장절항]/u

  @doc """
  Returns a compact navigational outline — heading paragraphs plus the
  document title row — so an agent can pick a target without slurping
  every paragraph.

  Each row: `[sec, para, level, text]` where `level` is 1 for `장`/`절`,
  2 for `조`, 3 for `항`, 0 for the title row. The text is a heading label
  only; article body text stays behind `doc.read`.
  """
  @spec outline(map() | State.t()) :: [list()]
  def outline(%State{} = state), do: outline(to_agent_ir(state))

  def outline(%{"sections" => sections, "title" => title}) when is_list(sections) do
    head =
      case title do
        t when is_binary(t) and t != "" -> [[0, -1, 0, t]]
        _ -> []
      end

    body =
      for section <- sections,
          paragraph <- section["paragraphs"] || [],
          row = outline_row(section["idx"] || 0, paragraph),
          row != nil,
          do: row

    head ++ body
  end

  def outline(_), do: []

  defp outline_row(sec, %{"idx" => p, "text" => text}) when is_binary(text) do
    case heading_level(text) do
      nil -> nil
      level -> [sec, p, level, outline_heading_label(text, level)]
    end
  end

  defp outline_row(_, _), do: nil

  defp outline_heading_label(text, 2) do
    trimmed = String.trim(text)

    case Regex.run(~r/^(.+?[)）])(?=\s|$)/u, trimmed) do
      [_, label] -> String.trim(label)
      _ -> strip_outline_body_marker(trimmed)
    end
  end

  defp outline_heading_label(text, _level), do: strip_outline_body_marker(String.trim(text))

  defp strip_outline_body_marker(text) do
    text
    |> String.split(~r/\s+[①②③④⑤⑥⑦⑧⑨⑩]/u, parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp heading_level(text) do
    cond do
      not is_binary(text) -> nil
      String.length(text) > 80 -> nil
      Regex.match?(~r/^\s*제\s*[0-9０-９]+\s*[장절]/u, text) -> 1
      Regex.match?(~r/^\s*제\s*[0-9０-９]+\s*조/u, text) -> 2
      Regex.match?(~r/^\s*제\s*[0-9０-９]+\s*항/u, text) -> 3
      Regex.match?(@heading_re, text) -> 2
      true -> nil
    end
  end

  @doc """
  Find every occurrence of `needle` across the document. Returns at most
  `limit` hits with `context` characters of leading/trailing snippet for
  disambiguation. Each hit carries the positional triple
  `(sec, para, off)` and the literal `match` substring, so the caller can
  feed them straight back into `doc.edit`.

  Result: `%{total: integer(), hits: [hit]}` where
  `hit = [sec, para, off, len, before, match, after, kind]`.
  """
  @spec find(map() | State.t(), String.t(), keyword()) ::
          %{total: non_neg_integer(), hits: list()}
  def find(%State{} = state, needle, opts), do: find(to_agent_ir(state), needle, opts)

  def find(%{"sections" => sections}, needle, opts)
      when is_binary(needle) and needle != "" and is_list(sections) do
    limit = Keyword.get(opts, :limit, 20)
    context = Keyword.get(opts, :context, 30)
    len = String.length(needle)

    {hits, total} =
      Enum.reduce(sections, {[], 0}, fn section, {acc, total} ->
        sec = section["idx"] || 0

        Enum.reduce(section["paragraphs"] || [], {acc, total}, fn p, {acc2, total2} ->
          para = p["idx"] || 0
          entries = searchable_paragraph_entries(sec, para, p)

          Enum.reduce(entries, {acc2, total2}, fn entry, {acc3, total3} ->
            matches = grapheme_indices(entry.text, needle)
            new_total = total3 + length(matches)
            new_hits = append_find_hits(acc3, matches, entry, needle, len, context, limit)
            {new_hits, new_total}
          end)
        end)
      end)

    %{total: total, hits: Enum.reverse(hits)}
  end

  def find(_ir, _needle, _opts), do: %{total: 0, hits: []}

  @doc false
  @spec paragraph_text_at(map() | State.t(), non_neg_integer(), non_neg_integer()) ::
          String.t() | nil
  def paragraph_text_at(%State{} = state, sec, para),
    do: paragraph_text_at(to_agent_ir(state), sec, para)

  def paragraph_text_at(%{"sections" => sections}, sec, para),
    do: paragraph_text_from_sections(sections, sec, para)

  def paragraph_text_at(_ir, _sec, _para), do: nil

  @doc false
  @spec cell_text_at_path(map() | State.t(), non_neg_integer(), non_neg_integer(), list()) ::
          String.t() | nil
  def cell_text_at_path(%State{} = state, sec, para, cell_path),
    do: cell_text_at_path(to_agent_ir(state), sec, para, cell_path)

  def cell_text_at_path(%{"sections" => sections}, sec, para, cell_path)
      when is_list(cell_path) do
    paragraph = find_paragraph(sections, sec, para)

    case paragraph do
      %{} ->
        paragraph_table_cells(sec, para, paragraph)
        |> Enum.find(&(Map.get(&1, "cell_path") == cell_path))
        |> case do
          %{"text" => text} when is_binary(text) -> text
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def cell_text_at_path(_ir, _sec, _para, _cell_path), do: nil

  defp searchable_paragraph_entries(sec, para, paragraph) do
    paragraph_entry = %{
      sec: sec,
      para: para,
      text: paragraph["text"] || "",
      kind: paragraph["kind"] || "paragraph",
      meta: nil
    }

    cell_entries =
      for cell <- paragraph_table_cells(sec, para, paragraph) do
        %{
          sec: sec,
          para: para,
          text: cell["text"] || "",
          kind: "cell",
          meta:
            Map.take(cell, [
              "control_index",
              "row",
              "col",
              "cell_index",
              "cell_para_index",
              "cell_path",
              "target"
            ])
        }
      end

    [paragraph_entry | cell_entries]
  end

  defp append_find_hits(acc, matches, entry, needle, len, context, limit) do
    Enum.reduce(matches, acc, fn off, hits ->
      if length(hits) >= limit do
        hits
      else
        hit = [
          entry.sec,
          entry.para,
          off,
          len,
          context_before(entry.text, off, context),
          needle,
          context_after(entry.text, off + len, context),
          entry.kind
        ]

        hit = if entry.meta, do: hit ++ [entry.meta], else: hit
        [hit | hits]
      end
    end)
  end

  defp grapheme_indices(haystack, needle) do
    graphemes = String.graphemes(haystack)
    nlen = String.length(needle)
    max_start = length(graphemes) - nlen

    if max_start < 0 do
      []
    else
      Enum.reduce(0..max_start, [], fn i, acc ->
        slice = graphemes |> Enum.slice(i, nlen) |> Enum.join()
        if slice == needle, do: [i | acc], else: acc
      end)
      |> Enum.reverse()
    end
  end

  defp context_before(text, off, ctx) do
    start = max(0, off - ctx)
    String.slice(text, start, off - start)
  end

  defp context_after(text, off_end, ctx), do: String.slice(text, off_end, ctx)

  @doc """
  Return one small cursor window for `doc.read`.

  Broad paragraph ranges return paragraph previews only. Single paragraphs,
  fields, and cells return bounded text windows plus continuation cursors.
  Table paragraphs return row/column windows, never the full table by default.
  """
  @spec read(map() | State.t(), non_neg_integer(), keyword()) ::
          map()
  def read(%State{} = state, sec, opts), do: read(to_agent_ir(state), sec, opts)

  def read(%{"sections" => sections} = ir, sec, opts) when is_list(sections) do
    section = Enum.find(sections, %{}, fn s -> (s["idx"] || 0) == sec end)
    paragraphs = section["paragraphs"] || []
    fields = map_value(ir, "fields") || []
    single = Keyword.get(opts, :para)

    cond do
      field_id = Keyword.get(opts, :field_id) ->
        field_read(ir, field_id, opts)

      is_integer(single) ->
        case Enum.find(paragraphs, fn p -> (p["idx"] || 0) == single end) do
          nil ->
            %{"type" => "missing", "sec" => sec, "para" => single}

          %{"kind" => "table"} = p ->
            cond do
              is_integer(Keyword.get(opts, :row)) and is_integer(Keyword.get(opts, :col)) ->
                cell_read(sec, single, p, opts)

              true ->
                table_window(sec, single, p, opts)
            end

          p ->
            paragraph_text_read(sec, p, fields, opts)
        end

      true ->
        paragraph_window(sec, paragraphs, opts)
    end
  end

  def read(_ir, sec, _opts), do: %{"type" => "missing", "sec" => sec}

  defp paragraph_window(sec, paragraphs, opts) do
    from = Keyword.get(opts, :from, 0)
    to = Keyword.get(opts, :to)
    limit = bounded(Keyword.get(opts, :limit), @paragraph_window_default, @paragraph_window_max)

    candidates =
      for p <- paragraphs, idx = p["idx"] || 0, idx >= from, is_nil(to) or idx <= to, do: p

    {window, rest} = Enum.split(candidates, limit)
    next = if rest == [], do: nil, else: hd(rest)["idx"] || 0

    %{
      "type" => "paragraph_window",
      "sec" => sec,
      "from" => from,
      "limit" => limit,
      "items" => Enum.map(window, &paragraph_preview(sec, &1))
    }
    |> maybe_put("next_para", next)
  end

  defp paragraph_preview(sec, %{"idx" => para} = paragraph) do
    text = paragraph["text"] || ""
    kind = paragraph["kind"] || "paragraph"
    {preview, range} = text_window(text, 0, @preview_chars)

    %{
      "sec" => sec,
      "para" => para,
      "kind" => kind,
      "chars" => String.length(text),
      "preview" => preview,
      "read" => %{"sec" => sec, "para" => para, "off" => 0, "chars" => @text_window_default}
    }
    |> maybe_put("next_off", range["next_off"])
    |> maybe_put_table_hint(paragraph)
  end

  defp paragraph_text_read(sec, %{"idx" => para, "text" => text} = paragraph, fields, opts) do
    off = max(Keyword.get(opts, :off, 0), 0)
    chars = bounded(Keyword.get(opts, :chars), @text_window_default, @text_window_max)
    text = text || ""
    {snippet, range} = text_window(text, off, chars)

    %{
      "type" => "paragraph",
      "sec" => sec,
      "para" => para,
      "kind" => paragraph["kind"] || "paragraph",
      "text" => snippet,
      "range" => range,
      "target" => %{
        "type" => "paragraph",
        "sec" => sec,
        "para" => para,
        "off" => off,
        "match" => snippet
      }
    }
    |> maybe_put("fields", paragraph_field_hints(sec, para, fields))
  end

  defp paragraph_text_read(sec, paragraph, fields, opts) do
    paragraph_text_read(sec, Map.put(paragraph, "text", paragraph["text"] || ""), fields, opts)
  end

  defp paragraph_field_hints(sec, para, fields) do
    fields
    |> List.wrap()
    |> Enum.filter(&field_in_paragraph?(&1, sec, para))
    |> Enum.map(fn field ->
      pos = map_value(field, "position") || %{}

      compact(%{
        "id" => map_value(field, "id"),
        "label" => map_value(field, "label"),
        "kind" => map_value(field, "kind"),
        "read" => %{"field_id" => map_value(field, "id")},
        "position" =>
          compact(%{
            "sec" => sec,
            "para" => para,
            "off_start" => map_value(pos, "off_start"),
            "off_end" => map_value(pos, "off_end")
          })
      })
    end)
  end

  defp field_read(%{"sections" => sections, "fields" => fields}, field_id, opts) do
    case Enum.find(List.wrap(fields), &(map_value(&1, "id") == field_id)) do
      nil ->
        %{"type" => "missing_field", "field_id" => field_id}

      field ->
        pos = map_value(field, "position") || %{}
        sec = map_value(pos, "sec") || 0
        para = map_value(pos, "parent_para") || map_value(pos, "para") || 0
        paragraph = find_paragraph(sections, sec, para)
        paragraph_text = (paragraph && paragraph["text"]) || ""
        value = field_value_for_read(field, paragraph_text)
        off = max(Keyword.get(opts, :off, 0), 0)
        chars = bounded(Keyword.get(opts, :chars), @text_window_default, @text_window_max)
        {snippet, range} = text_window(value, off, chars)
        target_off = (map_value(pos, "off_start") || 0) + off

        %{
          "type" => "field",
          "field" => %{
            "id" => map_value(field, "id"),
            "label" => map_value(field, "label"),
            "kind" => map_value(field, "kind"),
            "value" => snippet,
            "range" => range,
            "target" =>
              compact(%{
                "type" => field_target_type(pos),
                "sec" => sec,
                "para" => para,
                "off" => target_off,
                "match" => snippet,
                "cell_path" => map_value(pos, "cell_path")
              })
          }
        }
    end
  end

  defp field_read(_ir, field_id, _opts), do: %{"type" => "missing_field", "field_id" => field_id}

  defp field_target_type(pos) do
    case map_value(pos, "cell_path") do
      [_ | _] -> "cell"
      _ -> "paragraph"
    end
  end

  defp table_window(sec, para, paragraph, opts) do
    row_from = max(Keyword.get(opts, :row_from, 0), 0)
    row_limit = bounded(Keyword.get(opts, :row_limit), @table_row_default, @table_axis_max)
    col_from = max(Keyword.get(opts, :col_from, 0), 0)
    col_limit = bounded(Keyword.get(opts, :col_limit), @table_col_default, @table_axis_max)
    control_filter = Keyword.get(opts, :control_index)

    tables =
      paragraph_tables(sec, para, paragraph)
      |> Enum.filter(fn table ->
        is_nil(control_filter) or table["control_index"] == control_filter
      end)
      |> Enum.map(fn table ->
        cells =
          table["cells"]
          |> Enum.filter(fn cell ->
            cell["row"] >= row_from and cell["row"] < row_from + row_limit and
              cell["col"] >= col_from and cell["col"] < col_from + col_limit
          end)
          |> Enum.map(&cell_preview/1)

        %{
          "control_index" => table["control_index"],
          "rows" => table["rows"],
          "cols" => table["cols"],
          "row_from" => row_from,
          "row_limit" => row_limit,
          "col_from" => col_from,
          "col_limit" => col_limit,
          "cells" => cells
        }
      end)

    %{
      "type" => "table_window",
      "sec" => sec,
      "para" => para,
      "tables" => tables
    }
  end

  defp cell_read(sec, para, paragraph, opts) do
    row = Keyword.get(opts, :row)
    col = Keyword.get(opts, :col)
    control_filter = Keyword.get(opts, :control_index)

    cells =
      paragraph_table_cells(sec, para, paragraph)
      |> Enum.filter(fn cell ->
        cell["row"] == row and cell["col"] == col and
          (is_nil(control_filter) or cell["control_index"] == control_filter)
      end)

    case cells do
      [cell | _] ->
        off = max(Keyword.get(opts, :off, 0), 0)
        chars = bounded(Keyword.get(opts, :chars), @text_window_default, @text_window_max)
        text = cell["text"] || ""
        {snippet, range} = text_window(text, off, chars)

        %{
          "type" => "cell",
          "cell" =>
            cell
            |> Map.take([
              "control_index",
              "row",
              "col",
              "cell_index",
              "cell_para_index",
              "cell_path"
            ])
            |> Map.merge(%{
              "text" => snippet,
              "range" => range,
              "target" => %{
                "type" => "cell",
                "sec" => sec,
                "para" => para,
                "off" => off,
                "match" => snippet,
                "cell_path" => cell["cell_path"]
              }
            })
        }

      [] ->
        %{"type" => "missing_cell", "sec" => sec, "para" => para, "row" => row, "col" => col}
    end
  end

  defp cell_preview(cell) do
    text = cell["text"] || ""
    {preview, range} = text_window(text, 0, @preview_chars)

    cell
    |> Map.take(["control_index", "row", "col", "cell_index", "cell_para_index", "cell_path"])
    |> Map.merge(%{
      "chars" => String.length(text),
      "preview" => preview,
      "read" => %{
        "sec" => cell["target"]["sec"],
        "para" => cell["target"]["para"],
        "row" => cell["row"],
        "col" => cell["col"],
        "off" => 0,
        "chars" => @text_window_default
      }
    })
    |> maybe_put("next_off", range["next_off"])
  end

  defp text_window(text, off, chars) do
    text = text || ""
    total = String.length(text)
    off = min(max(off || 0, 0), total)
    chars = bounded(chars, @text_window_default, @text_window_max)
    snippet = String.slice(text, off, chars) || ""
    next_off = off + String.length(snippet)
    next_off = if next_off < total, do: next_off, else: nil

    {snippet,
     compact(%{
       "off" => off,
       "chars" => String.length(snippet),
       "total" => total,
       "next_off" => next_off
     })}
  end

  defp bounded(value, default, max_value) do
    cond do
      not is_integer(value) -> default
      value < 1 -> default
      true -> min(value, max_value)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_table_hint(map, %{"kind" => "table"} = paragraph) do
    case paragraph["tables"] do
      [_ | _] ->
        Map.put(map, "table", %{
          "read" => %{
            "sec" => map["sec"],
            "para" => map["para"],
            "row_from" => 0,
            "row_limit" => @table_row_default,
            "col_from" => 0,
            "col_limit" => @table_col_default
          }
        })

      _ ->
        map
    end
  end

  defp maybe_put_table_hint(map, _paragraph), do: map

  defp find_paragraph(sections, sec, para) do
    sections
    |> List.wrap()
    |> Enum.find(%{}, fn section -> (section["idx"] || 0) == sec end)
    |> Map.get("paragraphs", [])
    |> Enum.find(fn paragraph -> (paragraph["idx"] || 0) == para end)
  end

  defp field_in_paragraph?(field, sec, para) when is_map(field) do
    pos = map_value(field, "position") || %{}
    field_para = map_value(pos, "parent_para") || map_value(pos, "para")

    map_value(pos, "cell_path") in [nil, []] and map_value(pos, "sec") == sec and
      field_para == para
  end

  defp field_in_paragraph?(_field, _sec, _para), do: false

  defp field_value_for_read(field, paragraph_text) do
    value = map_value(field, "value")

    cond do
      is_binary(value) ->
        value

      true ->
        pos = map_value(field, "position") || %{}
        start_off = map_value(pos, "off_start") || 0
        end_off = map_value(pos, "off_end") || start_off
        String.slice(paragraph_text, start_off, max(end_off - start_off, 0)) || ""
    end
  end

  @doc """
  Total paragraph count across all sections — used by `doc.get` to
  expose `counts.para` without shipping every paragraph.
  """
  @spec paragraph_count(map() | State.t()) :: non_neg_integer()
  def paragraph_count(%State{} = state), do: paragraph_count(to_agent_ir(state))

  def paragraph_count(%{"sections" => sections}) when is_list(sections) do
    Enum.reduce(sections, 0, fn s, acc -> acc + length(s["paragraphs"] || []) end)
  end

  def paragraph_count(_), do: 0

  defp normalize_sections(sections) when is_list(sections) do
    sections
    |> Enum.with_index()
    |> Enum.map(fn {sec, default_idx} ->
      %{
        "idx" => Map.get(sec, "idx", default_idx),
        "paragraphs" =>
          sec
          |> Map.get("paragraphs", [])
          |> Enum.with_index()
          |> Enum.map(fn {p, default_pidx} ->
            %{
              "idx" => Map.get(p, "idx", default_pidx),
              "text" => Map.get(p, "text", "")
            }
            |> maybe_put_kind(p)
            |> maybe_put_tables(p)
          end)
      }
    end)
  end

  defp normalize_sections(_), do: []

  defp maybe_put_kind(paragraph, %{"kind" => kind}) when is_binary(kind),
    do: Map.put(paragraph, "kind", kind)

  defp maybe_put_kind(paragraph, _), do: paragraph

  defp maybe_put_tables(paragraph, %{"tables" => tables}) when is_list(tables),
    do: Map.put(paragraph, "tables", normalize_tables(tables))

  defp maybe_put_tables(paragraph, _), do: paragraph

  defp normalize_tables(tables) do
    Enum.map(tables || [], fn table ->
      %{
        "control_idx" => map_value(table, "control_idx") || map_value(table, "controlIndex") || 0,
        "rows" => map_value(table, "rows") || 0,
        "cols" => map_value(table, "cols") || 0,
        "cells" => normalize_cells(map_value(table, "cells") || [])
      }
    end)
  end

  defp normalize_cells(cells) do
    Enum.map(cells || [], fn cell ->
      %{
        "row" => map_value(cell, "row") || 0,
        "col" => map_value(cell, "col") || 0,
        "cell_idx" => map_value(cell, "cell_idx") || map_value(cell, "cellIndex") || 0,
        "paragraphs" => normalize_cell_paragraphs(map_value(cell, "paragraphs") || [])
      }
    end)
  end

  defp normalize_cell_paragraphs(paragraphs) do
    paragraphs
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {paragraph, default_idx} ->
      %{
        "idx" => map_value(paragraph, "idx") || default_idx,
        "text" => map_value(paragraph, "text") || ""
      }
    end)
  end

  defp paragraph_tables(sec, para, %{"tables" => tables}) do
    Enum.map(tables || [], fn table ->
      control_index = map_value(table, "control_idx") || 0

      %{
        "control_index" => control_index,
        "rows" => map_value(table, "rows") || 0,
        "cols" => map_value(table, "cols") || 0,
        "cells" => paragraph_table_cells(sec, para, table)
      }
    end)
  end

  defp paragraph_tables(_sec, _para, _), do: []

  defp paragraph_table_cells(sec, para, %{"tables" => _tables} = paragraph) do
    paragraph_tables(sec, para, paragraph)
    |> Enum.flat_map(&Map.get(&1, "cells", []))
  end

  defp paragraph_table_cells(sec, para, table) do
    control_index = map_value(table, "control_idx") || 0

    for cell <- map_value(table, "cells") || [],
        cell_paragraph <- map_value(cell, "paragraphs") || [] do
      cell_index = map_value(cell, "cell_idx") || 0
      cell_para_index = map_value(cell_paragraph, "idx") || 0
      text = map_value(cell_paragraph, "text") || ""

      cell_path = [
        %{
          "controlIndex" => control_index,
          "cellIndex" => cell_index,
          "cellParaIndex" => cell_para_index
        }
      ]

      %{
        "control_index" => control_index,
        "row" => map_value(cell, "row") || 0,
        "col" => map_value(cell, "col") || 0,
        "cell_index" => cell_index,
        "cell_para_index" => cell_para_index,
        "text" => text,
        "cell_path" => cell_path,
        "target" => %{
          "type" => "cell",
          "sec" => sec,
          "para" => para,
          "off" => 0,
          "match" => text,
          "cell_path" => cell_path
        }
      }
    end
  end

  defp overlay_post_snapshot_text(ir, document_id, snapshot_revision) do
    document_id
    |> post_snapshot_text_ops(snapshot_revision || 0)
    |> then(&overlay_text_ops(ir, &1))
  end

  defp post_snapshot_text_ops(document_id, snapshot_revision) do
    text_ops_after(document_id, snapshot_revision || 0)
  end

  defp text_ops_after(document_id, snapshot_revision) do
    Repo.all(
      from c in Change,
        where:
          c.document_id == ^document_id and c.command_kind == "edit_text" and
            c.result_revision > ^snapshot_revision,
        order_by: [asc: c.result_revision, asc: c.inserted_at, asc: c.id]
    )
    |> changes_to_text_ops()
  end

  defp text_ops_between(document_id, after_revision, through_revision)
       when is_binary(document_id) and is_integer(after_revision) and is_integer(through_revision) do
    Repo.all(
      from c in Change,
        where:
          c.document_id == ^document_id and c.command_kind == "edit_text" and
            c.result_revision > ^after_revision and c.result_revision <= ^through_revision,
        order_by: [asc: c.result_revision, asc: c.inserted_at, asc: c.id]
    )
    |> changes_to_text_ops()
  end

  defp text_ops_between(_document_id, _after_revision, _through_revision), do: []

  defp text_op_keys(ops) when is_list(ops) do
    ops
    |> Enum.map(&text_op_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp text_op_keys(_ops), do: MapSet.new()

  defp text_op_key(op) when is_map(op) do
    sec = int_value(op, "sec")
    para = int_value(op, "para")

    case map_value(op, "cell_path") do
      [_ | _] = cell_path ->
        with %{} = step <- List.last(cell_path),
             control_index when is_integer(control_index) <-
               map_value(step, "controlIndex") || map_value(step, "control_index"),
             cell_index when is_integer(cell_index) <-
               map_value(step, "cellIndex") || map_value(step, "cell_index"),
             cell_para_index when is_integer(cell_para_index) <-
               map_value(step, "cellParaIndex") || map_value(step, "cell_para_index"),
             true <- is_integer(sec) and is_integer(para) do
          {:cell, sec, para, control_index, cell_index, cell_para_index}
        else
          _ -> nil
        end

      _ ->
        if is_integer(sec) and is_integer(para), do: {sec, para}, else: nil
    end
  end

  defp text_op_key(_op), do: nil

  defp changes_to_text_ops(changes) do
    changes
    |> Enum.flat_map(fn %Change{payload: payload} -> payload || [] end)
    |> Enum.flat_map(&normalize_text_op/1)
  end

  defp overlay_text_ops(ir, ops) do
    ops
    |> Enum.reduce(ir, fn op, acc -> apply_text_op(acc, op) end)
    |> refresh_field_values()
  end

  defp normalize_text_op(op) when is_map(op) do
    kind = map_value(op, "op") || map_value(op, "kind")
    args = map_value(op, "args") || op

    case kind do
      "insert_text" ->
        text = map_value(args, "text") || ""

        if is_binary(text) and text != "" do
          [
            %{
              kind: "insert_text",
              sec: int_value(args, "sec"),
              para: int_value(args, "para"),
              off: int_value(args, "off"),
              text: text,
              cell_path: map_value(args, "cell_path"),
              field_id: map_value(args, "field_id")
            }
          ]
        else
          []
        end

      "delete_text" ->
        count = int_value(args, "count") || int_value(args, "len") || 0

        if count > 0 do
          [
            %{
              kind: "delete_text",
              sec: int_value(args, "sec"),
              para: int_value(args, "para"),
              off: int_value(args, "off"),
              count: count,
              cell_path: map_value(args, "cell_path"),
              field_id: map_value(args, "field_id")
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp normalize_text_op(_), do: []

  defp apply_text_op(ir, %{sec: sec, para: para, off: off} = op)
       when is_integer(sec) and is_integer(para) and is_integer(off) do
    ir
    |> Map.update("sections", [], &apply_text_op_to_sections(&1, op))
    |> Map.update("fields", [], &apply_text_op_to_fields(&1, op))
  end

  defp apply_text_op(ir, _op), do: ir

  defp apply_text_op_to_sections(sections, op) do
    Enum.map(sections || [], fn section ->
      if map_value(section, "idx") == op.sec do
        Map.update(section, "paragraphs", [], fn paragraphs ->
          Enum.map(paragraphs || [], fn paragraph ->
            apply_text_op_to_paragraph(paragraph, op)
          end)
        end)
      else
        section
      end
    end)
  end

  defp apply_text_op_to_paragraph(paragraph, %{cell_path: [_ | _]} = op) do
    if map_value(paragraph, "idx") == op.para do
      Map.update(paragraph, "tables", [], &apply_text_op_to_tables(&1, op))
    else
      paragraph
    end
  end

  defp apply_text_op_to_paragraph(paragraph, op) do
    if map_value(paragraph, "idx") == op.para and is_binary(map_value(paragraph, "text")) do
      Map.put(paragraph, "text", apply_text_to_string(map_value(paragraph, "text"), op))
    else
      paragraph
    end
  end

  defp apply_text_op_to_tables(tables, op) do
    Enum.map(tables || [], fn table ->
      Map.update(table, "cells", [], &apply_text_op_to_cells(&1, table, op))
    end)
  end

  defp apply_text_op_to_cells(cells, table, op) do
    Enum.map(cells || [], fn cell ->
      Map.update(cell, "paragraphs", [], fn paragraphs ->
        Enum.map(paragraphs || [], fn cell_paragraph ->
          if cell_path_matches?(op.cell_path, table, cell, cell_paragraph) do
            Map.put(
              cell_paragraph,
              "text",
              apply_text_to_string(map_value(cell_paragraph, "text") || "", op)
            )
          else
            cell_paragraph
          end
        end)
      end)
    end)
  end

  defp cell_path_matches?(cell_path, table, cell, cell_paragraph) do
    with [_ | _] <- cell_path,
         %{} = step <- List.last(cell_path) do
      (map_value(step, "controlIndex") || map_value(step, "control_index")) ==
        (map_value(table, "control_idx") || 0) and
        (map_value(step, "cellIndex") || map_value(step, "cell_index")) ==
          (map_value(cell, "cell_idx") || 0) and
        (map_value(step, "cellParaIndex") || map_value(step, "cell_para_index")) ==
          (map_value(cell_paragraph, "idx") || 0)
    else
      _ -> false
    end
  end

  defp apply_text_to_string(text, %{kind: "insert_text", off: off, text: inserted}) do
    off = clamp(off, 0, String.length(text))
    String.slice(text, 0, off) <> inserted <> String.slice(text, off, String.length(text) - off)
  end

  defp apply_text_to_string(text, %{kind: "delete_text", off: off, count: count}) do
    length = String.length(text)
    off = clamp(off, 0, length)
    count = clamp(count, 0, length - off)
    String.slice(text, 0, off) <> String.slice(text, off + count, length - off - count)
  end

  defp apply_text_op_to_fields(fields, op) do
    Enum.map(fields || [], &apply_text_op_to_field(&1, op))
  end

  defp apply_text_op_to_field(field, %{cell_path: [_ | _]}), do: field

  defp apply_text_op_to_field(field, op) when is_map(field) do
    pos = map_value(field, "position") || %{}

    cond do
      not same_body_position?(pos, op) ->
        field

      map_value(field, "id") == op.field_id and op.kind == "insert_text" ->
        put_field_position(field, pos, op.off, op.off + String.length(op.text))

      map_value(field, "id") == op.field_id and op.kind == "delete_text" ->
        put_field_position(field, pos, op.off, op.off)

      op.kind == "insert_text" ->
        shift_field_position(field, pos, op.off, String.length(op.text))

      op.kind == "delete_text" ->
        delete_from_field_position(field, pos, op.off, op.count)

      true ->
        field
    end
  end

  defp apply_text_op_to_field(field, _op), do: field

  defp same_body_position?(pos, op) when is_map(pos) do
    map_value(pos, "cell_path") in [nil, []] and map_value(pos, "sec") == op.sec and
      map_value(pos, "para") == op.para
  end

  defp same_body_position?(_pos, _op), do: false

  defp shift_field_position(field, pos, insert_off, delta) do
    start_off = map_value(pos, "off_start") || 0
    end_off = map_value(pos, "off_end") || start_off

    put_field_position(
      field,
      pos,
      shift_insert_anchor(start_off, insert_off, delta),
      shift_insert_anchor(end_off, insert_off, delta)
    )
  end

  defp delete_from_field_position(field, pos, delete_off, count) do
    start_off = map_value(pos, "off_start") || 0
    end_off = map_value(pos, "off_end") || start_off

    put_field_position(
      field,
      pos,
      shift_delete_anchor(start_off, delete_off, count),
      shift_delete_anchor(end_off, delete_off, count)
    )
  end

  defp shift_insert_anchor(anchor, insert_off, delta) when anchor >= insert_off,
    do: anchor + delta

  defp shift_insert_anchor(anchor, _insert_off, _delta), do: anchor

  defp shift_delete_anchor(anchor, delete_off, count) do
    delete_end = delete_off + count

    cond do
      anchor <= delete_off -> anchor
      anchor >= delete_end -> anchor - count
      true -> delete_off
    end
  end

  defp put_field_position(field, pos, start_off, end_off) do
    pos =
      pos
      |> Map.put("off_start", max(start_off, 0))
      |> Map.put("off_end", max(end_off, 0))

    Map.put(field, "position", pos)
  end

  defp refresh_field_values(%{"fields" => fields, "sections" => sections} = ir) do
    fields =
      Enum.map(fields || [], fn field ->
        case field_text(sections, map_value(field, "position"), field) do
          nil -> field
          value -> Map.put(field, "value", value)
        end
      end)

    Map.put(ir, "fields", fields)
  end

  defp refresh_field_values(ir), do: ir

  defp body_text_index(%{"sections" => sections}) when is_list(sections) do
    Map.new(
      for section <- sections,
          paragraph <- map_value(section, "paragraphs") || [],
          sec = map_value(section, "idx"),
          para = map_value(paragraph, "idx"),
          is_integer(sec) and is_integer(para) do
        {{sec, para}, map_value(paragraph, "text") || ""}
      end
    )
  end

  defp body_text_index(_ir), do: %{}

  defp document_text_index(%{"sections" => sections}) when is_list(sections) do
    Map.merge(body_text_index(%{"sections" => sections}), cell_text_index(sections))
  end

  defp document_text_index(_ir), do: %{}

  defp cell_text_index(sections) do
    Map.new(
      for section <- sections || [],
          paragraph <- map_value(section, "paragraphs") || [],
          table <- map_value(paragraph, "tables") || [],
          cell <- map_value(table, "cells") || [],
          cell_paragraph <- map_value(cell, "paragraphs") || [],
          sec = map_value(section, "idx"),
          para = map_value(paragraph, "idx"),
          control_index = map_value(table, "control_idx") || 0,
          cell_index = map_value(cell, "cell_idx") || 0,
          cell_para_index = map_value(cell_paragraph, "idx") || 0,
          is_integer(sec) and is_integer(para) and is_integer(control_index) and
            is_integer(cell_index) and is_integer(cell_para_index) do
        {{:cell, sec, para, control_index, cell_index, cell_para_index},
         map_value(cell_paragraph, "text") || ""}
      end
    )
  end

  defp field_text(sections, pos, field) when is_map(pos) do
    with true <- map_value(pos, "cell_path") in [nil, []],
         sec when is_integer(sec) <- map_value(pos, "sec"),
         para when is_integer(para) <- map_value(pos, "para"),
         start_off when is_integer(start_off) <- map_value(pos, "off_start"),
         end_off when is_integer(end_off) <- map_value(pos, "off_end"),
         text when is_binary(text) <- paragraph_text_from_sections(sections, sec, para) do
      start_off = clamp(start_off, 0, String.length(text))
      end_off = clamp(end_off, start_off, String.length(text))
      ranged_value = String.slice(text, start_off, end_off - start_off)
      full_value_at_start(text, start_off, field) || ranged_value
    else
      _ -> nil
    end
  end

  defp field_text(_sections, _pos, _field), do: nil

  defp full_value_at_start(text, start_off, field) do
    value = map_value(field, "value")

    cond do
      not is_binary(value) or value == "" ->
        nil

      String.slice(text, start_off, String.length(value)) == value ->
        value

      true ->
        nil
    end
  end

  defp paragraph_text_from_sections(sections, sec, para) do
    Enum.find_value(sections || [], fn section ->
      if map_value(section, "idx") == sec do
        Enum.find_value(map_value(section, "paragraphs") || [], fn paragraph ->
          if map_value(paragraph, "idx") == para, do: map_value(paragraph, "text")
        end)
      end
    end)
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, existing_atom(key))
  end

  defp map_value(_map, _key), do: nil

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp int_value(map, key) do
    case map_value(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
