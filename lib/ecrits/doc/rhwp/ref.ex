defmodule Ecrits.Doc.Rhwp.Ref do
  @moduledoc """
  Opaque element references for the HWP/HWPX backend.

  Refs are encoded as strings so they survive a JSON round-trip through the MCP
  boundary. The agent treats them as opaque; only this module decodes them.

  Grammar (subset of the design's `hwp:s0/p7` form):

      hwp:/                  document root
      hwp:s<sec>             a section
      hwp:s<sec>/p<para>     a paragraph
      hwp:s<sec>/p<para>/c<off>+<len>   a character run inside a paragraph
      hwp:s<sec>/p<para>/tbl<ctrl>/cell<cell>/cp<cellpara>/c<off>+<len>
                             a character run inside a TABLE CELL — `p<para>` is
                             the parent paragraph holding the table control,
                             `tbl<ctrl>` the control index, `cell<cell>` the cell
                             index, `cp<cellpara>` the paragraph index within the
                             cell. doc.find emits this for matches inside cells so
                             a follow-up edit targets the cell, not the body.

  The decoded form is a plain map with a `:kind` discriminator, which the
  backend pattern-matches when routing `get`/`set`/`edit`.
  """

  @type t :: String.t()

  @type decoded ::
          %{kind: :document}
          | %{kind: :section, sec: non_neg_integer()}
          | %{kind: :paragraph, sec: non_neg_integer(), para: non_neg_integer()}
          | %{
              kind: :char,
              sec: non_neg_integer(),
              para: non_neg_integer(),
              off: non_neg_integer(),
              len: non_neg_integer()
            }

  @scheme "hwp:"

  @spec encode(decoded()) :: t()
  def encode(%{kind: :document}), do: @scheme <> "/"
  def encode(%{kind: :section, sec: sec}), do: "#{@scheme}s#{sec}"
  def encode(%{kind: :paragraph, sec: sec, para: para}), do: "#{@scheme}s#{sec}/p#{para}"

  def encode(%{kind: :char, sec: sec, para: para, off: off, len: len}),
    do: "#{@scheme}s#{sec}/p#{para}/c#{off}+#{len}"

  def encode(%{
        kind: :cell_char,
        sec: sec,
        para: para,
        control: control,
        cell: cell,
        cell_para: cell_para,
        off: off,
        len: len
      }),
      do: "#{@scheme}s#{sec}/p#{para}/tbl#{control}/cell#{cell}/cp#{cell_para}/c#{off}+#{len}"

  @spec decode(t()) :: {:ok, decoded()} | {:error, term()}
  def decode(@scheme <> rest) when is_binary(rest), do: decode_body(rest)

  # doc.find on a BROWSER-backed doc returns positional refs as JSON OBJECTS
  # (`{"section","paragraph","offset"[,"length"][,"cell":{parentParaIndex,
  # controlIndex,cellIndex,cellParaIndex}]}`), not the `hwp:` grammar. Accept that
  # form too so the server-side inspect/get/set tools consume a doc.find ref
  # directly instead of rejecting it as invalid — a nested `cell` decodes to a
  # `:cell_char` ref (the table cell), otherwise a `:char` ref.
  def decode("{" <> _ = json) when is_binary(json), do: decode_json(json)

  def decode(value) when is_binary(value), do: {:error, {:invalid_ref, value}}
  def decode(value), do: {:error, {:invalid_ref, value}}

  @doc "Like `decode/1` but raises on error. Useful inside backend pipelines."
  @spec decode!(t()) :: decoded()
  def decode!(ref) do
    case decode(ref) do
      {:ok, decoded} -> decoded
      {:error, reason} -> raise ArgumentError, "invalid hwp ref: #{inspect(reason)}"
    end
  end

  defp decode_body("/"), do: {:ok, %{kind: :document}}

  defp decode_body(body) do
    case String.split(body, "/") do
      ["s" <> sec] ->
        with {:ok, sec} <- int(sec), do: {:ok, %{kind: :section, sec: sec}}

      ["s" <> sec, "p" <> para] ->
        with {:ok, sec} <- int(sec),
             {:ok, para} <- int(para) do
          {:ok, %{kind: :paragraph, sec: sec, para: para}}
        end

      ["s" <> sec, "p" <> para, "c" <> run] ->
        with {:ok, sec} <- int(sec),
             {:ok, para} <- int(para),
             {:ok, off, len} <- run(run) do
          {:ok, %{kind: :char, sec: sec, para: para, off: off, len: len}}
        end

      ["s" <> sec, "p" <> para, "tbl" <> ctrl, "cell" <> cell, "cp" <> cpara, "c" <> run] ->
        with {:ok, sec} <- int(sec),
             {:ok, para} <- int(para),
             {:ok, ctrl} <- int(ctrl),
             {:ok, cell} <- int(cell),
             {:ok, cpara} <- int(cpara),
             {:ok, off, len} <- run(run) do
          {:ok,
           %{
             kind: :cell_char,
             sec: sec,
             para: para,
             control: ctrl,
             cell: cell,
             cell_para: cpara,
             off: off,
             len: len
           }}
        end

      _ ->
        {:error, {:invalid_ref, @scheme <> body}}
    end
  end

  # --- JSON object refs (doc.find on a browser-backed doc) --------------------

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> from_json_map(map)
      _ -> {:error, {:invalid_ref, json}}
    end
  end

  # A nested `cell` object -> a char run inside a table cell. `parentParaIndex`
  # is the body paragraph that holds the table control, so it maps to `para`.
  defp from_json_map(%{"cell" => %{} = cell} = map) do
    {:ok,
     %{
       kind: :cell_char,
       sec: json_int(map, "section"),
       para: json_int(cell, "parentParaIndex", json_int(map, "paragraph")),
       control: json_int(cell, "controlIndex"),
       cell: json_int(cell, "cellIndex"),
       cell_para: json_int(cell, "cellParaIndex"),
       off: json_int(map, "offset"),
       len: json_int(map, "length")
     }}
  end

  defp from_json_map(%{"paragraph" => _} = map) do
    {:ok,
     %{
       kind: :char,
       sec: json_int(map, "section"),
       para: json_int(map, "paragraph"),
       off: json_int(map, "offset"),
       len: json_int(map, "length")
     }}
  end

  defp from_json_map(map), do: {:error, {:invalid_ref, map}}

  defp json_int(map, key, default \\ 0) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      _ -> default
    end
  end

  defp run(str) do
    case String.split(str, "+") do
      [off, len] ->
        with {:ok, off} <- int(off), {:ok, len} <- int(len), do: {:ok, off, len}

      _ ->
        {:error, {:invalid_run, str}}
    end
  end

  defp int(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_int, str}}
    end
  end
end
