defmodule Ecrits.Local.Agent.DocumentTools do
  @moduledoc """
  Local agent document tools backed by the native EHWP runtime.
  """

  alias Ecrits.Local.Document

  @find_default_size 10
  @find_max_size 50

  @doc "Read active local document text through the native runtime."
  def read(target, args) when is_map(args) do
    with {:ok, %Document{} = document} <- document(target),
         {:ok, result} <- with_runtime_document(document, &Ehwp.read(&1, [])) do
      {:ok,
       document_metadata(document)
       |> Map.put("text", normalize_text(result))
       |> Map.put("content", normalize_text(result))}
    end
  end

  def read(target, _args), do: read(target, %{})

  @doc "Find literal text in the active local document through the native runtime."
  def find(target, args) when is_map(args) do
    with {:ok, %Document{} = document} <- document(target),
         {:ok, pattern} <- required_string(args, "pattern"),
         {:ok, result} <-
           with_runtime_document(document, &Ehwp.find(&1, pattern, find_opts(args))) do
      matches =
        result
        |> decode_matches()
        |> window_matches(args)

      {:ok,
       document_metadata(document)
       |> Map.put("pattern", pattern)
       |> Map.put("matches", matches.items)
       |> Map.put("total", matches.total)
       |> Map.put("at", matches.at)
       |> Map.put("size", matches.size)
       |> maybe_put("next_at", matches.next_at)}
    end
  end

  def find(target, _args), do: find(target, %{})

  @doc """
  Native write entry point.

  EHWP can mutate an in-memory handle today, but it does not yet expose export
  back to canonical HWP/HWPX bytes through the package API. Returning success
  here would falsely claim the active workspace file changed.
  """
  def write(target, args) when is_map(args) do
    with {:ok, %Document{} = document} <- document(target),
         {:ok, query} <- required_string(args, "query"),
         {:ok, replacement} <- replacement_string(args),
         :ok <- verify_base_revision(document, args),
         {:ok, _result} <-
           with_runtime_document(document, fn handle ->
             Ehwp.write(handle, {:replace_one, query, replacement}, write_opts(args))
           end) do
      {:error,
       {:not_supported,
        "doc.write reached native EHWP but cannot persist changed bytes yet; add EHWP export/save before enabling writes"}}
    end
  end

  def write(_target, _args), do: {:error, :invalid_document_tool_args}

  defp document({:document_id, document_id}) when is_binary(document_id),
    do: Document.document(document_id)

  defp document(target), do: Document.document(target)

  defp with_runtime_document(%Document{} = document, fun) when is_function(fun, 1) do
    with {:ok, handle, _metadata} <- Ehwp.open(document.path) do
      try do
        fun.(handle)
      after
        Ehwp.close(handle)
      end
    end
  end

  defp document_metadata(%Document{} = document) do
    %{
      "document_id" => document.id,
      "relative_path" => document.relative_path,
      "format" => document.format,
      "revision" => document.revision
    }
  end

  defp normalize_text(text) when is_binary(text), do: text

  defp normalize_text(%{} = result) do
    cond do
      is_binary(result["text"]) -> result["text"]
      is_binary(result[:text]) -> result[:text]
      is_binary(result["content"]) -> result["content"]
      is_binary(result[:content]) -> result[:content]
      true -> inspect(result)
    end
  end

  defp normalize_text(result), do: inspect(result)

  defp decode_matches(matches) when is_list(matches), do: matches

  defp decode_matches(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, matches} when is_list(matches) -> matches
      {:ok, %{"matches" => matches}} when is_list(matches) -> matches
      _ -> []
    end
  end

  defp decode_matches(%{"matches" => matches}) when is_list(matches), do: matches
  defp decode_matches(%{matches: matches}) when is_list(matches), do: matches
  defp decode_matches(_matches), do: []

  defp window_matches(matches, args) do
    at = int_arg(args, "at", 0)
    size = args |> int_arg("size", @find_default_size) |> bounded_limit(@find_max_size)
    total = length(matches)
    {items, rest} = matches |> Enum.drop(at) |> Enum.split(size)
    next_at = if rest == [], do: nil, else: at + length(items)

    %{
      items: Enum.map(items, &normalize_match/1),
      total: total,
      at: at,
      size: size,
      next_at: next_at
    }
  end

  defp normalize_match(%{} = match) do
    match
    |> stringify_keys()
    |> rename_key("charOffset", "off")
    |> rename_key("length", "count")
  end

  defp normalize_match(other), do: %{"value" => other}

  defp rename_key(map, old_key, new_key) do
    case Map.pop(map, old_key) do
      {nil, map} -> map
      {value, map} -> Map.put_new(map, new_key, value)
    end
  end

  defp find_opts(args) do
    [case_sensitive: bool_arg(args, "case_sensitive", false)]
  end

  defp write_opts(args) do
    [case_sensitive: bool_arg(args, "case_sensitive", false)]
  end

  defp verify_base_revision(%Document{revision: revision}, %{"base_revision" => base_revision})
       when is_integer(base_revision) and base_revision <= revision,
       do: :ok

  defp verify_base_revision(%Document{revision: revision}, %{"base_revision" => base_revision})
       when is_integer(base_revision),
       do: {:error, {:stale_revision, expected: revision, got: base_revision}}

  defp verify_base_revision(_document, _args), do: :ok

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (non-empty string) is required"}}
    end
  end

  defp replacement_string(args) do
    case Map.fetch(args, "replacement") do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_params, "replacement (string) is required"}}
    end
  end

  defp int_arg(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp bool_arg(args, key, default) do
    case Map.get(args, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp bounded_limit(value, max_value) when is_integer(value), do: max(1, min(value, max_value))
  defp bounded_limit(_value, _max_value), do: @find_default_size

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
