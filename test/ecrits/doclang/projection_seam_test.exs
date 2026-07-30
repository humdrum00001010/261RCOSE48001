defmodule Doclang.ProjectionSeamTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Proves the exfuse VFS mount actually SERVES DocLang: `Ecrits.Doc.Projection`
  produces DocLang XML bytes, names the mounted file `.doclang.xml`, and routes
  write-back through `Doclang` rather than through a JSONL encoder/parser or the
  deleted `Ehwp.Ir` / `Libreofficex.LokBackend.Ir` modules. The projection's own
  end-to-end suite cannot run right now (no engine until Layer 4), so this
  covers the seam.
  """

  alias Ecrits.Doc.Projection

  test "the mounted name is the DocLang projection, round-tripping to the source" do
    assert Projection.projected_suffix() == ".doclang.xml"
    assert Projection.projected_name("report.hwp") == "report.hwp.doclang.xml"
    assert Projection.source_basename("report.hwp.doclang.xml") == "report.hwp"
    # The retired format must no longer resolve to a source document.
    assert Projection.source_basename("report.hwp.jsonl") == nil
  end

  test "project/2 emits a DocLang document for both arms" do
    hwp =
      Doclang.project(
        [%{"type" => "paragraph", "text" => "안녕", "ref" => %{"section" => 0, "paragraph" => 0}}],
        :hwpx
      )

    assert String.starts_with?(hwp, ~s(<doclang version="#{Doclang.version()}">))
    assert String.ends_with?(hwp, "</doclang>")
    assert hwp =~ "<text>안녕</text>"

    office = Doclang.project([%{"type" => "paragraph", "text" => "hello", "ref" => "p0"}], :docx)
    assert String.starts_with?(office, ~s(<doclang version="))
    assert office =~ "<text>hello</text>"
  end

  test "a DocLang edit of the projected bytes diffs back to a routable change" do
    nodes = [
      %{"type" => "paragraph", "text" => "old", "ref" => %{"section" => 0, "paragraph" => 0}}
    ]

    edited = nodes |> Doclang.project(:hwpx) |> String.replace("<text>old</text>", "<text>new</text>")

    assert [{:text, op, "new"}] = Doclang.changes(nodes, edited, :hwpx)
    assert op["op"] == "replace_text"
    assert op["ref"] == %{"section" => 0, "paragraph" => 0}
  end

  test "an untouched projection round-trips to zero changes (determinism)" do
    nodes = [
      %{"type" => "paragraph", "text" => "가", "ref" => %{"section" => 0, "paragraph" => 0}},
      %{"type" => "paragraph", "text" => "", "ref" => %{"section" => 0, "paragraph" => 1}},
      %{"type" => "paragraph", "text" => "나", "ref" => %{"section" => 0, "paragraph" => 2}}
    ]

    bytes = Doclang.project(nodes, :hwpx)
    assert Doclang.changes(nodes, bytes, :hwpx) == []
    # ...and re-projecting the same IR is byte-identical (the fingerprint basis).
    assert Doclang.project(nodes, :hwpx) == bytes
  end

  test "a partially written buffer never parses as a shorter document" do
    nodes = [
      %{"type" => "paragraph", "text" => "가", "ref" => %{"section" => 0, "paragraph" => 0}},
      %{"type" => "paragraph", "text" => "나", "ref" => %{"section" => 0, "paragraph" => 1}}
    ]

    bytes = Doclang.project(nodes, :hwpx)

    # EVERY proper prefix must fail to parse: that is what makes the mount's
    # "commit as soon as the buffer is valid" rule safe under chunked writes.
    for take <- 1..(byte_size(bytes) - 1) do
      assert {:error, _reason} = Doclang.parse(binary_part(bytes, 0, take))
    end

    # An out-of-order chunk leaves a NUL gap (DocFs `splice/3`) — also rejected.
    assert {:error, _} = Doclang.parse(<<0, 0, 0>> <> bytes)
  end

  test "the compiled projection calls Doclang and nothing from the deleted deps" do
    called = called_modules(Projection)

    assert Doclang in called

    refute Jason in called,
           "the mount must not encode or decode JSON: the projected bytes are DocLang XML"

    stale =
      Enum.filter(called, fn module ->
        String.starts_with?(Atom.to_string(module), ["Elixir.Ehwp", "Elixir.Libreofficex"])
      end)

    assert stale == []
  end

  # Every remote call the module makes, read straight out of its BEAM import
  # table. The plan's own note applies here: the compiler will NOT catch a stale
  # engine call — a remote call into a missing module is only a warning that
  # survives compilation and fails at runtime — so the seam has to be asserted,
  # not assumed.
  defp called_modules(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end
end
