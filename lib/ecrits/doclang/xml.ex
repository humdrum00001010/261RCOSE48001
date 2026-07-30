defmodule Doclang.Xml do
  @moduledoc """
  A minimal, dependency-free XML reader/writer for the DocLang v0.6 subset.

  DocLang has no importer upstream (`~/Desktop/rhwp_core/src/doclang/` is
  EXPORT ONLY — `eqedit/parser.rs` parses LaTeX, not DocLang), so the write-back
  half of the seam needs one here. This module is deliberately NOT a general XML
  processor: it handles exactly what the rhwp_core writer emits plus the
  whitespace a human or an agent adds when editing the mounted buffer.

  Supported: elements, attributes (`"` or `'` quoted), self-closing tags,
  character data, CDATA sections, comments, the `<?xml ?>` declaration and
  `<!DOCTYPE>`. Namespaces are not resolved — a prefixed name is kept verbatim,
  which is what DocLang's `hwp_prop` convention expects.

  Entity handling mirrors `src/doclang/writer/escape.rs`: the five predefined
  entities plus numeric character references. Anything else is left literal
  rather than failing, because a document body legitimately contains `&` runs
  that a careless edit may have left unescaped.

  ## Generic tree shape

      {:element, name :: String.t(), attrs :: %{String.t() => String.t()},
       children :: [tree_node()]}
      {:text, String.t()}

  Adjacent character data is merged into a single `{:text, _}` node so the tree
  is canonical: `a&amp;b` and `a` + `&amp;` + `b` parse identically.
  """

  @type attrs :: %{optional(String.t()) => String.t()}
  @type tree_node :: {:element, String.t(), attrs(), [tree_node()]} | {:text, String.t()}

  @doc """
  Parse an XML document into its root element.

  Returns `{:ok, {:element, name, attrs, children}}` or `{:error, reason}`.
  Never raises on malformed input.
  """
  @spec parse(binary()) :: {:ok, tree_node()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    with {:ok, rest} <- skip_prolog(xml),
         {:ok, element, rest} <- parse_element(rest),
         {:ok, ""} <- {:ok, strip_trailing(rest)} do
      {:ok, element}
    else
      {:ok, trailing} when is_binary(trailing) -> {:error, {:trailing_content, snippet(trailing)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_xml), do: {:error, :not_a_binary}

  @doc """
  Serialize a generic tree back to XML, using the same escaping rules as the
  rhwp_core writer (`escape_text` for character data, `escape_attr` for
  attribute values). Attributes are emitted in the order given, so callers that
  care about byte-identical output must supply an ordered list.
  """
  @spec encode(tree_node() | [tree_node()]) :: iodata()
  def encode({:text, text}), do: escape_text(text)

  def encode({:element, name, attrs, children}) do
    attr_io = Enum.map(attrs, fn {k, v} -> [" ", k, ~s(="), escape_attr(v), ~s(")] end)

    case children do
      [] -> ["<", name, attr_io, "/>"]
      _ -> ["<", name, attr_io, ">", Enum.map(children, &encode/1), "</", name, ">"]
    end
  end

  def encode(nodes) when is_list(nodes), do: Enum.map(nodes, &encode/1)

  @doc "Escape character data (`&`, `<`, `>`) — the twin of `escape::escape_text`."
  @spec escape_text(String.t()) :: String.t()
  def escape_text(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "Escape an attribute value — the twin of `escape::escape_attr`."
  @spec escape_attr(String.t()) :: String.t()
  def escape_attr(value) when is_binary(value) do
    value
    |> escape_text()
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # ── prolog ────────────────────────────────────────────────────────────────

  defp skip_prolog(xml) do
    rest = strip_leading(xml)

    cond do
      String.starts_with?(rest, "<?") -> skip_until(rest, "?>") |> continue_prolog()
      String.starts_with?(rest, "<!--") -> skip_until(rest, "-->") |> continue_prolog()
      String.starts_with?(rest, "<!") -> skip_doctype(rest) |> continue_prolog()
      String.starts_with?(rest, "<") -> {:ok, rest}
      rest == "" -> {:error, :empty_document}
      true -> {:error, {:unexpected_content, snippet(rest)}}
    end
  end

  defp continue_prolog({:ok, rest}), do: skip_prolog(rest)
  defp continue_prolog({:error, _} = error), do: error

  # `<!DOCTYPE ...>` may contain a bracketed internal subset; skip it as a unit.
  defp skip_doctype(rest) do
    case skip_balanced_doctype(rest, 0) do
      {:ok, _} = ok -> ok
      :error -> {:error, :unterminated_doctype}
    end
  end

  defp skip_balanced_doctype(<<>>, _depth), do: :error

  defp skip_balanced_doctype(<<"[", rest::binary>>, depth),
    do: skip_balanced_doctype(rest, depth + 1)

  defp skip_balanced_doctype(<<"]", rest::binary>>, depth),
    do: skip_balanced_doctype(rest, max(depth - 1, 0))

  defp skip_balanced_doctype(<<">", rest::binary>>, 0), do: {:ok, rest}

  defp skip_balanced_doctype(<<_::binary-size(1), rest::binary>>, depth),
    do: skip_balanced_doctype(rest, depth)

  # ── elements ──────────────────────────────────────────────────────────────

  defp parse_element(<<"<", rest::binary>>) do
    with {:ok, name, rest} <- parse_name(rest),
         {:ok, attrs, rest, self_closing?} <- parse_attrs(rest, []) do
      if self_closing? do
        {:ok, {:element, name, attrs, []}, rest}
      else
        with {:ok, children, rest} <- parse_content(rest, []),
             {:ok, rest} <- expect_close(rest, name) do
          {:ok, {:element, name, attrs, children}, rest}
        end
      end
    end
  end

  defp parse_element(other), do: {:error, {:expected_element, snippet(other)}}

  @name_terminators [?\s, ?\t, ?\n, ?\r, ?/, ?>]

  defp parse_name(binary), do: take_name(binary, [])

  defp take_name(<<c::utf8, _::binary>> = rest, acc) when c in @name_terminators,
    do: finish_name(acc, rest)

  defp take_name(<<>>, _acc), do: {:error, :unterminated_name}

  defp take_name(<<c::utf8, rest::binary>>, acc), do: take_name(rest, [<<c::utf8>> | acc])

  defp take_name(<<byte::binary-size(1), rest::binary>>, acc), do: take_name(rest, [byte | acc])

  defp finish_name(acc, rest) do
    case acc |> Enum.reverse() |> IO.iodata_to_binary() do
      "" -> {:error, :empty_element_name}
      name -> {:ok, name, rest}
    end
  end

  defp parse_attrs(binary, acc) do
    rest = strip_leading(binary)

    case rest do
      <<"/>", rest::binary>> ->
        {:ok, Map.new(Enum.reverse(acc)), rest, true}

      <<">", rest::binary>> ->
        {:ok, Map.new(Enum.reverse(acc)), rest, false}

      "" ->
        {:error, :unterminated_tag}

      _ ->
        with {:ok, name, rest} <- take_attr_name(rest, []),
             {:ok, value, rest} <- take_attr_value(rest) do
          parse_attrs(rest, [{name, value} | acc])
        end
    end
  end

  @attr_name_terminators [?= | @name_terminators]

  defp take_attr_name(<<c::utf8, _::binary>> = rest, acc) when c in @attr_name_terminators do
    case acc |> Enum.reverse() |> IO.iodata_to_binary() do
      "" -> {:error, {:invalid_attribute, snippet(rest)}}
      name -> {:ok, name, rest}
    end
  end

  defp take_attr_name(<<>>, _acc), do: {:error, :unterminated_attribute}

  defp take_attr_name(<<c::utf8, rest::binary>>, acc),
    do: take_attr_name(rest, [<<c::utf8>> | acc])

  defp take_attr_name(<<byte::binary-size(1), rest::binary>>, acc),
    do: take_attr_name(rest, [byte | acc])

  defp take_attr_value(binary) do
    case strip_leading(binary) do
      <<"=", rest::binary>> ->
        case strip_leading(rest) do
          <<?", rest::binary>> -> take_quoted(rest, ?")
          <<?', rest::binary>> -> take_quoted(rest, ?')
          other -> {:error, {:unquoted_attribute, snippet(other)}}
        end

      other ->
        {:error, {:attribute_without_value, snippet(other)}}
    end
  end

  defp take_quoted(binary, quote_char) do
    case :binary.match(binary, <<quote_char>>) do
      {pos, 1} ->
        raw = binary_part(binary, 0, pos)
        rest = binary_part(binary, pos + 1, byte_size(binary) - pos - 1)
        {:ok, decode_entities(raw), rest}

      :nomatch ->
        {:error, :unterminated_attribute_value}
    end
  end

  defp expect_close(binary, name) do
    expected = "</" <> name
    size = byte_size(expected)

    if binary_part_safe(binary, size) == expected do
      rest = binary_part(binary, size, byte_size(binary) - size)

      case strip_leading(rest) do
        <<">", rest::binary>> -> {:ok, rest}
        other -> {:error, {:malformed_close_tag, name, snippet(other)}}
      end
    else
      {:error, {:mismatched_close_tag, name, snippet(binary)}}
    end
  end

  defp binary_part_safe(binary, size) when byte_size(binary) >= size,
    do: binary_part(binary, 0, size)

  defp binary_part_safe(_binary, _size), do: nil

  # ── content ───────────────────────────────────────────────────────────────

  defp parse_content(binary, acc) do
    case binary do
      "" ->
        {:ok, Enum.reverse(acc), ""}

      <<"</", _::binary>> ->
        {:ok, Enum.reverse(acc), binary}

      <<"<!--", _::binary>> ->
        with {:ok, rest} <- skip_until(binary, "-->"), do: parse_content(rest, acc)

      <<"<![CDATA[", rest::binary>> ->
        case :binary.match(rest, "]]>") do
          {pos, 3} ->
            text = binary_part(rest, 0, pos)
            rest = binary_part(rest, pos + 3, byte_size(rest) - pos - 3)
            parse_content(rest, push_text(acc, text))

          :nomatch ->
            {:error, :unterminated_cdata}
        end

      <<"<?", _::binary>> ->
        with {:ok, rest} <- skip_until(binary, "?>"), do: parse_content(rest, acc)

      <<"<!", _::binary>> ->
        with {:ok, rest} <- skip_doctype(binary), do: parse_content(rest, acc)

      <<"<", _::binary>> ->
        with {:ok, element, rest} <- parse_element(binary) do
          parse_content(rest, [element | acc])
        end

      _ ->
        {raw, rest} = take_text(binary)
        parse_content(rest, push_text(acc, decode_entities(raw)))
    end
  end

  defp push_text(acc, ""), do: acc
  defp push_text([{:text, prev} | acc], text), do: [{:text, prev <> text} | acc]
  defp push_text(acc, text), do: [{:text, text} | acc]

  defp take_text(binary) do
    case :binary.match(binary, "<") do
      {pos, 1} -> {binary_part(binary, 0, pos), binary_part(binary, pos, byte_size(binary) - pos)}
      :nomatch -> {binary, ""}
    end
  end

  # ── entities ──────────────────────────────────────────────────────────────

  defp decode_entities(binary) do
    if :binary.match(binary, "&") == :nomatch do
      binary
    else
      decode_entities(binary, [])
    end
  end

  defp decode_entities(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_entities(<<"&", rest::binary>> = binary, acc) do
    case :binary.match(rest, ";") do
      {pos, 1} when pos <= 12 ->
        name = binary_part(rest, 0, pos)
        tail = binary_part(rest, pos + 1, byte_size(rest) - pos - 1)

        case entity(name) do
          nil -> decode_entities(rest, ["&" | acc])
          replacement -> decode_entities(tail, [replacement | acc])
        end

      _ ->
        <<_::binary-size(1), tail::binary>> = binary
        decode_entities(tail, ["&" | acc])
    end
  end

  defp decode_entities(<<c::utf8, rest::binary>>, acc),
    do: decode_entities(rest, [<<c::utf8>> | acc])

  defp decode_entities(<<byte::binary-size(1), rest::binary>>, acc),
    do: decode_entities(rest, [byte | acc])

  defp entity("amp"), do: "&"
  defp entity("lt"), do: "<"
  defp entity("gt"), do: ">"
  defp entity("quot"), do: "\""
  defp entity("apos"), do: "'"

  defp entity(<<"#x", hex::binary>>), do: codepoint(hex, 16)
  defp entity(<<"#X", hex::binary>>), do: codepoint(hex, 16)
  defp entity(<<"#", dec::binary>>), do: codepoint(dec, 10)
  defp entity(_other), do: nil

  defp codepoint(digits, base) do
    case Integer.parse(digits, base) do
      {value, ""} when value >= 0 and value <= 0x10FFFF -> <<value::utf8>>
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # ── shared scanning helpers ───────────────────────────────────────────────

  defp skip_until(binary, terminator) do
    case :binary.match(binary, terminator) do
      {pos, len} ->
        {:ok, binary_part(binary, pos + len, byte_size(binary) - pos - len)}

      :nomatch ->
        {:error, {:unterminated, terminator}}
    end
  end

  defp strip_leading(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: strip_leading(rest)
  defp strip_leading(binary), do: binary

  defp strip_trailing(binary) do
    trimmed = String.trim(binary)

    cond do
      trimmed == "" -> ""
      String.starts_with?(trimmed, "<!--") -> strip_trailing_comment(trimmed)
      true -> trimmed
    end
  end

  defp strip_trailing_comment(binary) do
    case skip_until(binary, "-->") do
      {:ok, rest} -> strip_trailing(rest)
      {:error, _} -> binary
    end
  end

  defp snippet(binary) when is_binary(binary), do: String.slice(binary, 0, 40)
  defp snippet(other), do: other
end
