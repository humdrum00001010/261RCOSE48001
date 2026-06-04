defmodule Ecrits.Local.Agent.DocumentTools do
  @moduledoc """
  Local agent document tools for HWP/HWPX text (doc.read / doc.find / doc.write).

  ## Migration status (rhwp_core browser-WASM)

  These tools used to read/search the document text through the server-side
  `ehwp` NIF. That NIF has been removed: HWP/HWPX rendering + hit-testing now run
  entirely in the browser via rhwp_core compiled to WASM, and ecrits no longer
  links a server-side HWP text engine.

  rhwp_core does not (yet) expose a thin native (non-WASM) Elixir binding ecrits
  could call here, and routing `doc.read`/`doc.find` through the connected
  browser's WASM document is a later-phase change (it needs an agent→client
  request/response channel and a connected workspace tab — neither exists on the
  server-only MCP path today). Rather than fabricate text, these tools return a
  clear, explicit "unavailable during migration" error so the agent surfaces the
  real state instead of silently succeeding with wrong data.

  The tool *contract* (target resolution, argument validation, metadata shape) is
  preserved so re-enabling them in the next phase — by routing to the browser
  WASM document or a future native rhwp_core text binding — is a localized change
  to the `text_for/2` and `search/3` seams below.
  """

  alias Ecrits.Local.Document

  @find_default_size 10
  @find_max_size 50

  # doc.read returns a CHUNK (characters), never the whole document, so it can't
  # blow the agent's token budget; the agent pages with at/size + next_at.
  @read_default_size 4000
  @read_max_size 20000

  @migration_error {:not_supported,
                    "HWP/HWPX text tools are unavailable during the rhwp_core browser-WASM migration: " <>
                      "the server-side ehwp text engine was removed and the browser-WASM document " <>
                      "reader is not yet wired to the agent. Re-enable in the next phase."}

  @doc "Read a CHUNK (at/size paging) of the active local document text."
  def read(target, args) when is_map(args) do
    with {:ok, %Document{} = document} <- document(target),
         {:ok, full} <- text_for(document, args) do
      total = String.length(full)
      at = args |> int_arg("at", 0) |> min(total)
      size = args |> int_arg("size", @read_default_size) |> bounded_limit(@read_max_size)
      chunk = String.slice(full, at, size)
      next_at = if at + size < total, do: at + size, else: nil

      {:ok,
       document_metadata(document)
       |> Map.put("text", chunk)
       |> Map.put("content", chunk)
       |> Map.put("at", at)
       |> Map.put("size", size)
       |> Map.put("total", total)
       |> maybe_put("next_at", next_at)}
    end
  end

  def read(target, _args), do: read(target, %{})

  @doc "Find literal text in the active local document."
  def find(target, args) when is_map(args) do
    with {:ok, %Document{} = document} <- document(target),
         {:ok, pattern} <- required_string(args, "pattern"),
         {:ok, raw_matches} <- search(document, pattern, args) do
      matches =
        raw_matches
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
  Write entry point.

  Text mutation + persistence move to the browser-WASM editing phase (rhwp_core
  `insertText`/`deleteText` in the canvas, op-stream to the server, then save).
  Until that lands there is no server-side path to mutate canonical HWP/HWPX
  bytes, so this fails explicitly rather than claiming the file changed.
  """
  def write(target, args) when is_map(args) do
    with {:ok, %Document{} = _document} <- document(target),
         {:ok, _query} <- required_string(args, "query"),
         {:ok, _replacement} <- replacement_string(args) do
      {:error, @migration_error}
    end
  end

  def write(_target, _args), do: {:error, :invalid_document_tool_args}

  # --- engine seam -------------------------------------------------------
  #
  # These two functions are the ONLY place the document text engine is reached.
  # Re-enabling read/find in the browser-WASM phase means implementing these to
  # ask the connected client's WASM document (or a future native rhwp_core text
  # binding) — the rest of this module is engine-agnostic.

  defp text_for(%Document{}, _args), do: {:error, @migration_error}

  defp search(%Document{}, _pattern, _args), do: {:error, @migration_error}

  defp document({:document_id, document_id}) when is_binary(document_id),
    do: Document.document(document_id)

  defp document(target), do: Document.document(target)

  defp document_metadata(%Document{} = document) do
    %{
      "document_id" => document.id,
      "relative_path" => document.relative_path,
      "format" => document.format,
      "revision" => document.revision
    }
  end

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
