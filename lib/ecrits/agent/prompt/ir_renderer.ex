defmodule Ecrits.Agent.Prompt.IRRenderer do
  @moduledoc """
  Storage IR(`snapshots.projection` jsonb) → token-efficient compact JSON.

  `schema_prompt/0` is part of the live model prompt. `render/1` and
  `compact_map/1` are retained only for dev/debug IR inspection endpoints.

  Positional 정보 손실 없음:
    - p body : [sec, para, text]
    - p table: [sec, para, "T", control_idx, rows, cols, [[row, col, cell_idx, cell_para_idx, text], ...]]
    - f      : [id, label, kind, pos, value]
                pos is internal projection data; not part of agent tool args.

  `render/1` 은 dynamic 컨텐츠(JSON) 만 반환. schema(`schema_prompt/0`) 는 static —
  prompt cache 친화.
  """

  @schema_prompt """
  쪽 IR 인코딩 (doc.get / doc.read / doc.write):
    doc.get → {ok, revision, d (title), t (type_key), counts}
              aggregate metadata only. No outline/index/cursors/pages arrays,
              read contract, paragraph_refs, table_controls arrays, cell_refs, bbox,
              heading labels, body text, field values, or table cell text.
              content/navigation comes from doc.read only.

    doc.read(sec, at, size=5) → {revision, read}
              paragraph_window: read={type, sec, items, next_para?}; items are previews only.

    doc.write(sec, para, {base_revision, type, payload:{cmd,payload}}) → compact mutation
              type is substrate/family. payload.cmd is operation. payload.payload is command args.
              paragraph insert_after_match: payload.payload={match,text}
              paragraph insert_before_match: payload.payload={match,text}
              paragraph insert_at_offset: payload.payload={off,text}; off is zero-based in doc.read item text.
              paragraph insert_paragraph_after: payload.payload={text}
              text must be single-paragraph strings with no line breaks.

    doc.get never returns semantic field hints or values. Concrete text/values come from doc.read.
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
      "p" => compact_paragraphs(ir["sections"] || [])
    }
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
