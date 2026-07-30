defmodule Ecrits.Doc.Office.Ref do
  @moduledoc """
  Opaque element references for the Office (docx/pptx) backend.

  Unlike the HWP backend (whose refs are an `hwp:` positional grammar this app
  encodes/decodes), the LibreOffice UNO arm issues its OWN native ref strings in
  `uno_elements` and accepts them back verbatim in `uno_get`/`uno_set`/
  `uno_apply`. So a ref here is just the opaque UNO string — we pass it through
  untouched. This module only *classifies* a ref into an element type so the
  backend can route property reads/writes and surface the right reflective
  vocabulary, mirroring `Ecrits.Doc.Rhwp.Ref` without re-encoding anything.

  UNO ref grammar (emitted by the bridge's object-model walker):

      p<idx>                       a body paragraph (Writer)
      p<idx>/r<ridx>               a text run inside a paragraph
      tbl[<TableName>]             a table
      tbl[<TableName>]/cell[<B2>]  a table cell (UNO cell name, e.g. B2)
      page[<SlideName>]            a slide (Impress)
      page[<SlideName>]/shape[<N>] a shape / text frame on a slide
      page[<SlideName>]/shape[<N>]/p<idx>[/r<ridx>]  text inside a shape
  """

  @type t :: String.t()

  @typedoc "Classified element kind for a UNO ref."
  @type kind :: :document | :paragraph | :run | :table | :cell | :slide | :shape | :unknown

  @doc """
  Classify a UNO ref string into an element kind. `nil` is the whole document.
  Order matters: the more specific suffixes (`/cell[…]`, `/shape[…]`, `/r…`) are
  tested before the container prefixes.
  """
  @spec classify(t() | nil) :: kind()
  def classify(nil), do: :document
  def classify(""), do: :document

  def classify(ref) when is_binary(ref) do
    cond do
      String.contains?(ref, "/cell[") -> :cell
      String.contains?(ref, "/shape[") -> :shape
      Regex.match?(~r{/r\d+$}, ref) -> :run
      String.starts_with?(ref, "tbl[") -> :table
      String.starts_with?(ref, "page[") -> :slide
      Regex.match?(~r{(^|/)p\d+$}, ref) -> :paragraph
      true -> :unknown
    end
  end

  def classify(_ref), do: :unknown

  @doc "Map a classified kind to the public `doc.*` element type string."
  @spec type(kind()) :: String.t()
  def type(:document), do: "document"
  def type(:paragraph), do: "paragraph"
  def type(:run), do: "char_run"
  def type(:table), do: "table"
  def type(:cell), do: "cell"
  def type(:slide), do: "slide"
  def type(:shape), do: "shape"
  def type(:unknown), do: "element"
end
