defmodule Contract.Agent.Prompt.IRRenderer do
  @moduledoc """
  Storage IR(`snapshots.projection` jsonb) → token-efficient compact JSON.

  `schema_prompt/0` is part of the live model prompt. `render/1` and
  `compact_map/1` are retained only for dev/debug IR inspection endpoints.

  Positional 정보 손실 없음:
    - p body : [sec, para, text]
    - p table: [sec, para, "T", control_idx, rows, cols, [[row, col, cell_idx, cell_para_idx, text], ...]]
    - f      : [id, label, kind, pos, value]
                pos = [sec, para, parent_para, cell_path, off_start, off_end]
                cell_path = [[controlIndex, cellIndex, cellParaIndex], ...] or null

  `render/1` 은 dynamic 컨텐츠(JSON) 만 반환. schema(`schema_prompt/0`) 는 static —
  prompt cache 친화.
  """

  @schema_prompt """
  쪽 IR 인코딩 (doc.find / doc.read / doc.get / doc.edit):
    doc.get → {revision, d (title), t (type_key), counts, outline, f, cursors, read}
              outline/f are bounded pages; use cursors.outline.from / cursors.fields.from if present.
              outline: [[sec, para, level, heading_label], ...]  (heading label 만)
              level: 0=title row (para=-1), 1=장/절, 2=조, 3=항
              f entries do not include field values.

    doc.find → {revision, total, hits}
              paragraph hits: [[sec, para, off, len, before, match, after, "paragraph"], ...]
              cell hits: [[sec, para, off, len, before, match, after, "cell", {cell_path, target}], ...]
              cell hit target can be passed directly to doc.edit.

    doc.read → {revision, read}
              paragraph_window: read={type, sec, from, limit, items, next_para?}; items are previews only.
              paragraph: read={type, sec, para, kind, text, range, target, fields?}; text is bounded by off/chars.
              field: read={type, field:{id,label,kind,value,range,target}}; value is bounded by off/chars.
              table_window: read={type, sec, para, tables}; table cells are row/col-window previews only.
              cell: read={type, cell:{row,col,text,range,cell_path,target}}; text is bounded by off/chars.

    doc.edit → {op, target, text?, block?, base_revision?}
              replace_text paragraph target: {type: "paragraph", sec, para, off, match? | len?}
              replace_text cell target: {type: "cell", sec, para, cell_path, off, match? | len?}
              insert_block target: {type: "block", sec, para}, block: {kind: "paragraph" | "heading" | "list_item", text?, level?}
              delete_block target: {type: "block", sec, para}
              text/block.text must be single-paragraph strings with no line breaks.
              table creation and row/column structure edits are not supported.

    f (field read hints):
      [id, label, kind, {sec, para, off_start?, off_end?, cell_path?}]
  """

  @spec schema_prompt() :: String.t()
  def schema_prompt, do: @schema_prompt

  @doc "Dev/debug renderer for inspecting client-extracted IR; not used in the model path."
  @spec render(map()) :: String.t()
  def render(ir) when is_map(ir), do: ir |> compact_map() |> Jason.encode!()

  @doc "Dev/debug variant of `render/1` that returns the compact map before JSON encoding."
  @spec compact_map(map()) :: map()
  def compact_map(ir) when is_map(ir) do
    %{
      "d" => ir["title"],
      "r" => ir["revision"],
      "t" => ir["contract_type"],
      "f" => Enum.map(ir["fields"] || [], &compact_field/1),
      "p" => compact_paragraphs(ir["sections"] || [])
    }
  end

  defp compact_field(f) do
    [f["id"], f["label"], f["kind"], compact_position(f["position"] || %{}), f["value"] || ""]
  end

  defp compact_position(pos) do
    cell_path =
      case pos["cell_path"] do
        [_ | _] = path ->
          Enum.map(path, fn step ->
            [step["controlIndex"], step["cellIndex"], step["cellParaIndex"]]
          end)

        _ ->
          nil
      end

    [pos["sec"], pos["para"], pos["parent_para"], cell_path, pos["off_start"], pos["off_end"]]
  end

  defp compact_paragraphs(sections) do
    for section <- sections,
        paragraph <- section["paragraphs"] || [] do
      compact_paragraph(section["idx"], paragraph)
    end
  end

  defp compact_paragraph(s, %{"idx" => p, "kind" => "table", "tables" => [t | _]}) do
    cells =
      for cell <- t["cells"] || [], cp <- cell["paragraphs"] || [] do
        [cell["row"], cell["col"], cell["cell_idx"], cp["idx"], cp["text"] || ""]
      end

    [s, p, "T", t["control_idx"], t["rows"], t["cols"], cells]
  end

  defp compact_paragraph(s, %{"idx" => p} = paragraph) do
    [s, p, paragraph["text"] || ""]
  end
end
