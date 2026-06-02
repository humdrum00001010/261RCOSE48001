defmodule Ecrits.Export.LawyerPacket do
  @moduledoc """
  Deterministic Markdown lawyer packet.

  The packet intentionally stays text-based for v0.5 so it can be stored and
  downloaded through the same export path as Markdown while carrying the
  rendered contract plus evidence/source/change summaries.
  """

  alias Ecrits.Export.Markdown
  alias Ecrits.Runtime.State

  @spec render(State.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(%State{} = state, opts \\ []) do
    with {:ok, rendered} <- Markdown.render(state, opts) do
      projection = state.projection || %{}
      title = projection |> Map.get(:title) |> to_text() |> blank_to("Untitled")

      packet =
        [
          "# Lawyer Packet: #{title}",
          packet_summary(state, projection),
          "## Rendered Contract\n\n" <> String.trim(rendered),
          evidence_summary(projection),
          change_summary(state, projection)
        ]
        |> Enum.join("\n\n")
        |> then(&(&1 <> "\n"))

      {:ok, packet}
    end
  end

  defp packet_summary(%State{} = state, projection) do
    type_key = projection |> Map.get(:type_key) |> to_text() |> blank_to("untyped")

    "## Packet Summary\n\n" <>
      "- Document ID: #{to_text(state.document_id)}\n" <>
      "- Revision: #{state.revision}\n" <>
      "- Contract type: #{type_key}"
  end

  defp evidence_summary(projection) do
    marks = projection |> Map.get(:marks, %{}) |> Map.values()
    refs = projection |> Map.get(:refs, %{}) |> Map.values()
    fields = projection |> Map.get(:fields, %{}) |> Map.values()

    lines =
      evidence_mark_lines(marks) ++
        ref_lines(refs) ++
        field_lines(fields)

    body =
      case lines do
        [] -> "- No evidence, source, or field annotations are embedded in this projection."
        _ -> Enum.join(lines, "\n")
      end

    "## Evidence and Source Summary\n\n" <> body
  end

  defp evidence_mark_lines(marks) do
    marks
    |> Enum.sort_by(&to_text(Map.get(&1, :id)))
    |> Enum.map(fn mark ->
      intent = mark |> Map.get(:intent) |> to_text() |> blank_to("mark")
      source = mark |> Map.get(:source) |> to_text() |> blank_to("unknown_source")
      target = mark |> Map.get(:target_id) |> to_text() |> blank_to("document")
      text = mark |> Map.get(:text) |> to_text() |> blank_to("No summary text")
      "- #{intent} from #{source} on #{target}: #{text}"
    end)
  end

  defp ref_lines(refs) do
    refs
    |> Enum.sort_by(&to_text(Map.get(&1, :id)))
    |> Enum.map(fn ref ->
      source = ref |> Map.get(:source_node_id) |> to_text() |> blank_to("unknown_node")
      target = ref |> Map.get(:target_id) |> to_text() |> blank_to("unknown_target")
      "- Reference from #{source} to #{target}"
    end)
  end

  defp field_lines(fields) do
    fields
    |> Enum.sort_by(&to_text(Map.get(&1, :id)))
    |> Enum.map(fn field ->
      key = field |> Map.get(:key) |> to_text() |> blank_to(to_text(Map.get(field, :id)))
      value = field |> Map.get(:value) |> to_text()
      "- Field #{key}: #{value}"
    end)
  end

  defp change_summary(%State{} = state, projection) do
    metadata = Map.get(projection, :metadata, %{})

    metadata_lines =
      metadata
      |> Enum.sort_by(fn {key, _value} -> to_text(key) end)
      |> Enum.map(fn {key, value} -> "- #{key}: #{inspect(value)}" end)

    body =
      case metadata_lines do
        [] -> "- Projection materialized at revision #{state.revision}."
        _ -> Enum.join(metadata_lines, "\n")
      end

    "## Change Summary\n\n" <> body
  end

  defp blank_to("", fallback), do: fallback
  defp blank_to(text, _fallback), do: text

  defp to_text(nil), do: ""
  defp to_text(s) when is_binary(s), do: s
  defp to_text(other), do: to_string(other)
end
