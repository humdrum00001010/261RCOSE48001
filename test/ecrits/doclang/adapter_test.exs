defmodule Doclang.AdapterTest do
  use ExUnit.Case, async: true

  alias Doclang.Adapter.Hwp
  alias Doclang.Adapter.Office

  describe "Hwp — nested JSONL projection policy (ported from Ehwp.Ir)" do
    test "compacts a purely positional paragraph ref out of the payload" do
      nodes = [
        %{"type" => "paragraph", "text" => "a", "ref" => %{"section" => 0, "paragraph" => 0}},
        %{"type" => "paragraph", "text" => "b", "ref" => %{"section" => 0, "paragraph" => 1}}
      ]

      assert [[[%{"type" => "paragraph", "text" => "a"}], [%{"text" => "b"}]]] =
               Hwp.nested_payloads(nodes)

      refute nodes
             |> Hwp.nested_payloads()
             |> List.flatten()
             |> Enum.any?(&Map.has_key?(&1, "ref"))
    end

    test "groups payloads under their section and paragraph position" do
      nodes = [
        %{"type" => "paragraph", "text" => "s0p0", "ref" => %{"section" => 0, "paragraph" => 0}},
        %{"type" => "paragraph", "text" => "s1p0", "ref" => %{"section" => 1, "paragraph" => 0}}
      ]

      assert [[[%{"text" => "s0p0"}]], [[%{"text" => "s1p0"}]]] = Hwp.nested_payloads(nodes)
    end

    test "keeps a rich/non-positional ref verbatim" do
      nodes = [%{"type" => "note", "ref" => %{"section" => 0, "note" => 3}}]
      assert [[[%{"ref" => %{"note" => 3}}]]] = Hwp.nested_payloads(nodes)
    end

    test "expand_node is the inverse of the compaction" do
      assert Hwp.expand_node(%{"type" => "paragraph", "ref" => [0, 7, 2]}) ==
               %{
                 "type" => "paragraph",
                 "ref" => %{"section" => 0, "paragraph" => 7, "offset" => 2}
               }

      assert Hwp.expand_node(%{"type" => "cell", "ref" => [0, 4, 0, 1, 0, 0]})["ref"] ==
               %{
                 "section" => 0,
                 "paragraph" => 4,
                 "offset" => 0,
                 "cell" => %{
                   "parentParaIndex" => 4,
                   "controlIndex" => 0,
                   "cellIndex" => 1,
                   "cellParaIndex" => 0
                 }
               }
    end

    test "expand_node is a no-op on an office (string-ref) payload" do
      node = %{"type" => "paragraph", "text" => "x", "ref" => "p0"}
      assert Hwp.expand_node(node) == node
    end
  end

  describe "Hwp.changes/2 — the flat positional diff (ported from Ehwp.Ir)" do
    test "a changed paragraph text becomes replace_text on the live ref" do
      old = [
        %{"type" => "paragraph", "text" => "old", "ref" => %{"section" => 0, "paragraph" => 0}}
      ]

      new = [%{"type" => "paragraph", "text" => "new"}]

      assert [{:text, op, "new"}] = Hwp.changes(old, new)
      assert op["op"] == "replace_text"
      assert op["ref"] == %{"section" => 0, "paragraph" => 0}
    end

    test "an untouched payload list yields no changes" do
      old = [
        %{"type" => "paragraph", "text" => "same", "ref" => %{"section" => 0, "paragraph" => 0}}
      ]

      assert Hwp.changes(old, [%{"type" => "paragraph", "text" => "same"}]) == []
    end

    test "a type change is a structural change" do
      old = [
        %{"type" => "paragraph", "text" => "a", "ref" => %{"section" => 0, "paragraph" => 0}}
      ]

      assert {:error, :structural_change} = Hwp.changes(old, [%{"type" => "table"}])
    end

    test "an inserted picture payload is anchored and keeps its description" do
      old = [
        %{"type" => "paragraph", "text" => "abc", "ref" => %{"section" => 0, "paragraph" => 0}}
      ]

      new = [
        %{"type" => "paragraph", "text" => "abc"},
        %{"type" => "picture", "src" => "/tmp/bird.jpg", "description" => "DBG_BIRD_INSERT"}
      ]

      assert [{:insert_picture, op, "DBG_BIRD_INSERT", %{}}] = Hwp.changes(old, new)
      assert op["ref"] == %{"section" => 0, "paragraph" => 0, "offset" => 3}
    end

    test "a removed picture payload becomes delete_node" do
      ref = %{"section" => 0, "paragraph" => 1, "control" => 0, "type" => "picture"}

      old = [
        %{"type" => "picture", "description" => "RED", "ref" => ref},
        %{"type" => "paragraph", "text" => "tail", "ref" => %{"section" => 0, "paragraph" => 2}}
      ]

      new = [%{"type" => "paragraph", "text" => "tail"}]

      assert [{:delete_node, %{"op" => "delete_node", "ref" => ^ref}, "RED"}] =
               Hwp.changes(old, new)
    end

    test "changed non-text fields become a set change" do
      ref = %{"section" => 0, "paragraph" => 0, "control" => 0, "type" => "picture"}
      old = [%{"type" => "picture", "ref" => ref, "width" => 100, "description" => "x"}]
      new = [%{"type" => "picture", "width" => 200, "description" => "x"}]

      assert [{:set, ^ref, "picture", %{"width" => 200}}] = Hwp.changes(old, new)
    end
  end

  describe "Hwp — DocLang lowering" do
    test "paragraphs lower to <text> and keep document order" do
      nodes = [
        %{"type" => "paragraph", "text" => "가", "ref" => %{"section" => 0, "paragraph" => 0}},
        %{"type" => "paragraph", "text" => "나", "ref" => %{"section" => 1, "paragraph" => 0}}
      ]

      assert Hwp.to_blocks(nodes) == [
               %{"type" => "text", "text" => "가"},
               %{"type" => "text", "text" => "나"}
             ]
    end

    test "bindings are ordered exactly like to_blocks and carry the live ref" do
      nodes = [
        %{"type" => "paragraph", "text" => "가", "ref" => %{"section" => 0, "paragraph" => 0}},
        %{"type" => "paragraph", "text" => "나", "ref" => %{"section" => 0, "paragraph" => 1}}
      ]

      bindings = Hwp.bindings(nodes)
      assert Enum.map(bindings, & &1.block) == Hwp.to_blocks(nodes)
      assert Enum.map(bindings, & &1.ref) == Enum.map(nodes, & &1["ref"])
    end

    test "a node type DocLang has no element for becomes <group><custom>" do
      nodes = [%{"type" => "section_def", "ref" => %{"section" => 0}, "landscape" => true}]

      assert [block] = Hwp.to_blocks(nodes)
      assert block["type"] == "group"
      assert Doclang.custom_prop(block, "ns") == "hwp:section_def"
      assert Doclang.custom_prop(block, "landscape") == "true"
    end

    test "table cells fold into a <table> and their bindings hang off it" do
      nodes = [
        %{
          "type" => "table",
          "ref" => %{"section" => 0, "paragraph" => 4, "control" => 0},
          "rows" => 1,
          "cols" => 2
        },
        %{"type" => "cell", "text" => "a", "row" => 0, "col" => 0, "ref" => "cell-a"},
        %{"type" => "cell", "text" => "b", "row" => 0, "col" => 1, "ref" => "cell-b"}
      ]

      assert [%{"type" => "table", "rows" => 1, "cols" => 2, "cells" => cells}] =
               Hwp.to_blocks(nodes)

      assert length(cells) == 2

      assert [table_binding] = Hwp.bindings(nodes)
      assert Enum.map(table_binding.children, & &1.ref) == ["cell-a", "cell-b"]
      assert Enum.all?(table_binding.children, & &1.cell?)
    end

    test "ref_for recovers a ref from the baseline nodes" do
      nodes = [
        %{"type" => "paragraph", "text" => "x", "ref" => %{"section" => 0, "paragraph" => 9}}
      ]

      assert Hwp.ref_for(%{"type" => "text", "text" => "x"}, nodes) ==
               %{"section" => 0, "paragraph" => 9}
    end
  end

  describe "Office — ref classification (ported from Libreofficex.LokBackend.Ir)" do
    test "classifies the ref grammar" do
      assert Office.classify(nil) == :document
      assert Office.classify("document/settings") == :document_settings
      assert Office.classify("p0") == :paragraph
      assert Office.classify("p0/r0") == :run
      assert Office.classify("page[Slide1]/shape[Title]/p0/r0") == :run
      assert Office.classify("tbl[Table1]") == :table
      assert Office.classify("tbl[Table1]/cell[B2]") == :cell
      assert Office.classify("page[Slide1]") == :slide
      assert Office.classify("page[Slide1]/shape[Title]") == :shape
      assert Office.classify("page[Slide1]/notes") == :notes_page
      assert Office.classify("master[M1]/theme") == :theme
      assert Office.classify("page_style[Standard]/header") == :header
      assert Office.classify("style[ParagraphStyles:Heading 1]") == :paragraph_style
      assert Office.classify("sheet[Sheet1]") == :sheet
      assert Office.classify("nonsense") == :unknown
    end

    test "positional? separates edit-fragile refs from name-stable ones" do
      assert Office.positional?("p3")
      assert Office.positional?("tbl[T]/cell[B2]")
      assert Office.positional?("fn[2]")
      refute Office.positional?("tbl[T]")
      refute Office.positional?("page[Slide1]/shape[Title]")
    end

    test "run nodes are dropped from the projection" do
      assert Office.run?(%{"type" => "run", "ref" => "p0/r0"})
      refute Office.run?(%{"type" => "paragraph", "ref" => "p0"})
    end

    test "canonicalize strips the ref and derived fields" do
      node = %{
        "ref" => "p0",
        "type" => "paragraph",
        "text" => "x",
        "context" => "c",
        "row" => 1,
        "col" => 2
      }

      assert Office.canonicalize(node) == %{"type" => "paragraph", "text" => "x"}
    end

    test "canonicalize keeps the Calc cell edit surface" do
      node = %{
        "ref" => "sheet[Sheet1]/cell[B2]",
        "type" => "cell",
        "context" => "c",
        "row" => 2,
        "col" => 2,
        "value" => 5,
        "formula" => "=A1"
      }

      canon = Office.canonicalize(node)
      assert canon["value"] == 5
      assert canon["formula"] == "=A1"
      assert canon["row"] == 2
      refute Map.has_key?(canon, "context")
    end

    test "shape_old keeps the live ref beside the canonical shape" do
      nodes = [
        %{"ref" => "p0", "type" => "paragraph", "text" => "a"},
        %{"ref" => "p0/r0", "type" => "run", "text" => "a"}
      ]

      assert [%{canon: %{"type" => "paragraph"}, ref: "p0", type: "paragraph", text: "a"}] =
               Office.shape_old(nodes)
    end

    test "nested_payloads emits one section of one-node paragraphs, ref-less" do
      nodes = [
        %{"ref" => "p0", "type" => "paragraph", "text" => "a"},
        %{"ref" => "p0/r0", "type" => "run", "text" => "a"}
      ]

      assert Office.nested_payloads(nodes) == [[[%{"type" => "paragraph", "text" => "a"}]]]
    end
  end

  describe "Office.validate_property_changes/2" do
    test "accepts a change advertised by the reflected surface with a matching type" do
      old = %{"props" => %{"CharWeight" => 100.0}, "prop_types" => %{"CharWeight" => "float"}}
      new = %{"props" => %{"CharWeight" => 150.0}}
      assert :ok = Office.validate_property_changes(old, new)
    end

    test "rejects a property the live object does not advertise" do
      old = %{"props" => %{}, "prop_types" => %{}}
      new = %{"props" => %{"Invented" => 1}}

      assert {:error, {:invalid_property, "Invented"}} =
               Office.validate_property_changes(old, new)
    end

    test "rejects a value whose type does not match the reflected UNO type" do
      old = %{"props" => %{"CharWeight" => 100.0}, "prop_types" => %{"CharWeight" => "float"}}
      new = %{"props" => %{"CharWeight" => "bold"}}

      assert {:error, {:invalid_property_type, "CharWeight", "float"}} =
               Office.validate_property_changes(old, new)
    end

    test "rejects a malformed property map" do
      assert {:error, :invalid_property_map} = Office.validate_property_changes(:nope, %{})
    end
  end

  describe "Office — DocLang lowering" do
    test "a shape lowers to <text> tagged with its UNO provenance" do
      nodes = [%{"type" => "shape", "ref" => "page[Slide1]/shape[Title]", "text" => "제목"}]

      assert [block] = Office.to_blocks(nodes)
      assert block["type"] == "text"
      assert block["text"] == "제목"
      assert Doclang.custom_prop(block, "ns") == "uno:shape"
    end

    test "reflected props ride <custom> in a deterministic order" do
      nodes = [
        %{
          "type" => "paragraph",
          "ref" => "p0",
          "text" => "x",
          "props" => %{"ParaAdjust" => 3, "CharHeight" => 12.0}
        }
      ]

      assert [%{"custom" => pairs}] = Office.to_blocks(nodes)
      assert pairs == [["ns", "uno:paragraph"], ["CharHeight", "12.0"], ["ParaAdjust", "3"]]
    end

    test "insertion_anchor picks the nearest preceding paragraph ref" do
      bindings =
        Office.bindings([
          %{"type" => "paragraph", "ref" => "p0", "text" => "a"},
          %{"type" => "paragraph", "ref" => "p1", "text" => "b"}
        ])

      assert Office.insertion_anchor(bindings, 1) == "p0"
      assert Office.insertion_anchor(bindings, 0) == "p0"
      assert Office.insertion_anchor([], 0) == "end"
    end
  end

  describe "Office — table cell coordinates (UNO 1-based -> DocLang 0-based)" do
    # The office client treats row 1 as the header row and gates cell validity on
    # `row > 0 && col > 0` (office_wasm.ex), so the engine's mirror is 1-based.
    # DocLang's grid is 0-based (Doclang.resolve_spans/4 anchors at row 0).
    defp table_nodes(cells) do
      [%{"type" => "table", "ref" => "tbl[T1]"} | cells]
    end

    defp cell(ref, row, col, text) do
      base = %{"type" => "cell", "ref" => ref, "text" => text}

      case {row, col} do
        {nil, nil} -> base
        _ -> Map.merge(base, %{"row" => row, "col" => col})
      end
    end

    test "shifts 1-based coordinates down to the 0-based grid" do
      nodes =
        table_nodes([
          cell("tbl[T1]/cell[A1]", 1, 1, "a1"),
          cell("tbl[T1]/cell[B2]", 2, 2, "b2")
        ])

      assert [%{"type" => "table", "rows" => 2, "cols" => 2, "cells" => cells}] =
               Office.to_blocks(nodes)

      assert Enum.map(cells, &{&1["row"], &1["col"]}) == [{0, 0}, {1, 1}]
    end

    test "falls back to the authoritative A1 ref instead of collapsing a stray 0" do
      # A 0 here is out of contract. Clamping it (max(row - 1, 0)) would put it on
      # top of the real row 1 cell and silently merge two grid slots.
      nodes =
        table_nodes([
          cell("tbl[T1]/cell[A1]", 1, 1, "a1"),
          cell("tbl[T1]/cell[B2]", 0, 0, "b2")
        ])

      assert [%{"cells" => cells}] = Office.to_blocks(nodes)
      positions = Enum.map(cells, &{&1["row"], &1["col"]})

      assert positions == [{0, 0}, {1, 1}]
      assert Enum.uniq(positions) == positions
    end

    test "uses the A1 ref when the coordinate mirror is absent" do
      nodes =
        table_nodes([
          cell("tbl[T1]/cell[A1]", nil, nil, "a1"),
          cell("tbl[T1]/cell[C3]", nil, nil, "c3")
        ])

      assert [%{"rows" => 3, "cols" => 3, "cells" => cells}] = Office.to_blocks(nodes)
      assert Enum.map(cells, &{&1["row"], &1["col"]}) == [{0, 0}, {2, 2}]
    end
  end

  # Verbatim `enumerateElements` output from rhwp_core running against the real
  # Korean sample 21868765_별표2_보건소_분장사무.hwp (447 elements, 147x3 = 441
  # cells). The enumerator emits NO `row`/`col` on cells — the grid is recovered
  # from the table node's rows/cols plus `ref.cell.cellIndex` — so this pins the
  # contract between the two repos.
  describe "Hwp — rhwp_core doc-elements-v1 enumerator output" do
    setup do
      table = %{
        "type" => "table",
        "rows" => 147,
        "cols" => 3,
        "ref" => %{"section" => 0, "paragraph" => 4, "control" => 0, "type" => "table"}
      }

      cell = fn index, text, header ->
        %{
          "type" => "cell",
          "text" => text,
          "rowSpan" => 1,
          "colSpan" => 1,
          "header" => header,
          "ref" => %{
            "section" => 0,
            "paragraph" => 4,
            "offset" => 0,
            "type" => "cell",
            "cell" => %{
              "parentParaIndex" => 4,
              "controlIndex" => 0,
              "cellIndex" => index,
              "cellParaIndex" => 0
            }
          }
        }
      end

      {:ok, table: table, cell: cell}
    end

    test "recovers the grid from cellIndex and the table's declared cols",
         %{table: table, cell: cell} do
      nodes = [
        Map.put(table, "rows", 2),
        cell.(0, "부 서 명", true),
        cell.(1, "", true),
        cell.(3, "보건행정과", false)
      ]

      assert [%{"type" => "table", "rows" => 2, "cols" => 3, "cells" => cells}] =
               Hwp.to_blocks(nodes)

      # The grid is materialized in full (2x3): a position with no cell renders
      # as <ecel/> and parses back as an empty anchor, so it must exist as a
      # block here too or the document fails its own no-op diff.
      assert Enum.map(cells, &{&1["row"], &1["col"]}) ==
               [{0, 0}, {0, 1}, {0, 2}, {1, 0}, {1, 1}, {1, 2}]

      # cellIndex 0 -> {0,0}, 1 -> {0,1}, 3 -> {1,0} (row-major over cols=3).
      text = fn c -> c["blocks"] |> Enum.map(& &1["text"]) end
      assert text.(Enum.at(cells, 0)) == ["부 서 명"]
      assert text.(Enum.at(cells, 1)) == [""]
      assert text.(Enum.at(cells, 3)) == ["보건행정과"]

      # Holes carry no blocks and are not headers.
      assert text.(Enum.at(cells, 2)) == []
      assert Enum.at(cells, 2)["header"] == false
      assert Enum.map(cells, & &1["header"]) == [true, true, false, false, false, false]
    end

    test "several nodes sharing a cellIndex become paragraphs of ONE cell",
         %{table: table, cell: cell} do
      # One enumerator node is one paragraph INSIDE a cell (cellParaIndex), so a
      # two-paragraph cell arrives as two nodes at the same grid slot. Collapsing
      # them to one would drop the second paragraph's text.
      nodes = [
        table |> Map.put("rows", 1) |> Map.put("cols", 1),
        cell.(0, "first", false),
        cell.(0, "second", false)
      ]

      assert [%{"cells" => [only]}] = Hwp.to_blocks(nodes)
      assert {only["row"], only["col"]} == {0, 0}
      assert Enum.map(only["blocks"], & &1["text"]) == ["first", "second"]
    end

    test "keeps the live cell ref on every binding so a write-back can lower it",
         %{table: table, cell: cell} do
      nodes = [table, cell.(0, "부 서 명", true)]

      assert [table_binding] = Hwp.bindings(nodes)
      assert [child] = table_binding.children

      assert child.ref["cell"]["cellIndex"] == 0
      assert child.ref["cell"]["controlIndex"] == 0
      assert child.ref["section"] == 0
    end
  end

  # F6: the UNO walker does not promise row-major order. Blocks and bindings are
  # paired BY INDEX against a row-major OTSL render, so emitting cells in walk
  # order paired each cell's text with another cell's ref — a pure no-op read/
  # write silently rotated the table.
  describe "Office — table cells are emitted row-major, not in walk order" do
    test "out-of-order walk still yields row-major cells and matching refs" do
      cell = fn ref, row, col, text ->
        %{"type" => "cell", "ref" => ref, "row" => row, "col" => col, "text" => text}
      end

      # Walker emits B2, A1, B1, A2 — deliberately scrambled.
      nodes = [
        %{"type" => "table", "ref" => "tbl[T]"},
        cell.("tbl[T]/cell[B2]", 2, 2, "d"),
        cell.("tbl[T]/cell[A1]", 1, 1, "a"),
        cell.("tbl[T]/cell[B1]", 1, 2, "b"),
        cell.("tbl[T]/cell[A2]", 2, 1, "c")
      ]

      assert [%{"type" => "table", "cells" => cells}] = Office.to_blocks(nodes)

      assert Enum.map(cells, &{&1["row"], &1["col"]}) == [{0, 0}, {0, 1}, {1, 0}, {1, 1}]

      text = fn c -> c["blocks"] |> Enum.map(& &1["text"]) end
      assert Enum.map(cells, text) == [["a"], ["b"], ["c"], ["d"]]

      # Bindings must line up with the SAME order, or child_blocks/1 pairs a
      # cell's text with a different cell's ref.
      assert [table_binding] = Office.bindings(nodes)

      assert Enum.map(table_binding.children, & &1.ref) == [
               "tbl[T]/cell[A1]",
               "tbl[T]/cell[B1]",
               "tbl[T]/cell[A2]",
               "tbl[T]/cell[B2]"
             ]
    end

    test "a scrambled walk still round-trips clean (no phantom changes)" do
      cell = fn ref, row, col, text ->
        %{"type" => "cell", "ref" => ref, "row" => row, "col" => col, "text" => text}
      end

      nodes = [
        %{"type" => "table", "ref" => "tbl[T]"},
        cell.("tbl[T]/cell[B2]", 2, 2, "d"),
        cell.("tbl[T]/cell[A1]", 1, 1, "a"),
        cell.("tbl[T]/cell[B1]", 1, 2, "b"),
        cell.("tbl[T]/cell[A2]", 2, 1, "c")
      ]

      assert Doclang.changes(nodes, Doclang.project(nodes, :docx), :docx) == []
    end
  end

  # F7: Writer names split sub-cells A1.1/A1.2 and the engine's cell_rc() stops at
  # the ".", so both report the same row/col. One block per cell meant the second
  # was dropped by claim_cell/5 — its text never reached the agent, and the block
  # count no longer matched the parse, so every later edit was rejected.
  describe "Office — cells colliding on one grid position" do
    setup do
      nodes = [
        %{"type" => "table", "ref" => "tbl[T]"},
        %{"type" => "cell", "ref" => "tbl[T]/cell[A1.1]", "row" => 1, "col" => 1, "text" => "left half"},
        %{"type" => "cell", "ref" => "tbl[T]/cell[A1.2]", "row" => 1, "col" => 1, "text" => "right half"},
        %{"type" => "cell", "ref" => "tbl[T]/cell[B1]", "row" => 1, "col" => 2, "text" => "B1 text"}
      ]

      {:ok, nodes: nodes}
    end

    test "keeps every colliding cell's text instead of dropping it", %{nodes: nodes} do
      assert [%{"cells" => cells}] = Office.to_blocks(nodes)

      texts = Enum.flat_map(cells, fn c -> Enum.map(c["blocks"], & &1["text"]) end)
      assert "left half" in texts
      assert "right half" in texts
      assert "B1 text" in texts
    end

    test "the projected buffer carries all of it", %{nodes: nodes} do
      xml = Doclang.project(nodes, :docx)
      assert xml =~ "left half"
      assert xml =~ "right half"
      assert xml =~ "B1 text"
    end

    test "and the document stays writable (no permanent structural_change)",
         %{nodes: nodes} do
      assert Doclang.changes(nodes, Doclang.project(nodes, :docx), :docx) == []
    end
  end
end
