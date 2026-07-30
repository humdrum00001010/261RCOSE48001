defmodule DoclangTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The XML fixtures below are the exact strings rhwp_core's own writer tests
  assert on (`~/Desktop/rhwp_core/src/doclang/writer/{mod,inline,otsl}.rs`), so
  a round-trip here is a round-trip against the real exporter, not against a
  shape invented on this side.
  """

  defp doc(body), do: ~s(<doclang version="0.6">) <> body <> "</doclang>"

  defp blocks!(body) do
    assert {:ok, blocks} = Doclang.parse_blocks(doc(body))
    blocks
  end

  defp assert_round_trips(body) do
    xml = doc(body)
    assert {:ok, parsed} = Doclang.parse(xml)
    assert Doclang.to_xml(parsed) == xml
    assert Doclang.parse(Doclang.to_xml(parsed)) == {:ok, parsed}
    parsed
  end

  describe "parse/1 — document envelope" do
    test "reads the version and an empty body" do
      assert {:ok, %{"version" => "0.6", "blocks" => []}} = Doclang.parse(doc(""))
    end

    test "round-trips the empty document byte-identically" do
      assert Doclang.to_xml(%{"version" => "0.6", "blocks" => []}) ==
               ~s(<doclang version="0.6"></doclang>)
    end

    test "rejects a non-doclang root" do
      assert {:error, {:unexpected_root, "html"}} = Doclang.parse("<html/>")
    end

    test "rejects malformed XML rather than raising" do
      assert {:error, {:malformed_xml, _}} = Doclang.parse("<doclang><text>oops</doclang>")
    end
  end

  describe "parse/1 — paragraphs and inlines" do
    test "a plain paragraph is described entirely by its text" do
      assert [%{"type" => "text", "text" => "hello"}] = blocks!("<text>hello</text>")
    end

    test "an empty paragraph keeps its open/close form" do
      assert [%{"type" => "text", "text" => ""}] = blocks!("<text></text>")
      assert_round_trips("<text></text>")
    end

    test "mixed styled runs keep markup in :inlines and plain text in :text" do
      [block] = blocks!("<text>plain <bold>bold</bold> end</text>")

      assert block == %{
               "type" => "text",
               "text" => "plain bold end",
               "inlines" => [
                 "plain ",
                 %{"style" => "bold", "content" => ["bold"]},
                 " end"
               ]
             }

      assert_round_trips("<text>plain <bold>bold</bold> end</text>")
    end

    test "nested styles preserve the writer's canonical nesting order" do
      assert_round_trips("<text><bold><italic><underline>x</underline></italic></bold></text>")

      [%{"inlines" => [inline], "text" => "x"}] =
        blocks!("<text><bold><italic><underline>x</underline></italic></bold></text>")

      assert %{"style" => "bold", "content" => [%{"style" => "italic"}]} = inline
    end

    test "hyperlinks keep their uri and anchor" do
      [block] = blocks!(~s(<text><href uri="http://x.com?a=1&amp;b=2">link</href></text>))

      assert block["inlines"] == [
               %{"href" => "http://x.com?a=1&b=2", "content" => ["link"]}
             ]

      assert block["text"] == "link"
      assert_round_trips(~s(<text><href uri="http://x.com?a=1&amp;b=2">link</href></text>))
    end

    test "escaped markup characters round-trip" do
      assert [%{"text" => "a & b < c > d"}] = blocks!("<text>a &amp; b &lt; c &gt; d</text>")
      assert_round_trips("<text>a &amp; b &lt; c &gt; d</text>")
    end

    test "Korean content survives unchanged" do
      assert [%{"text" => "제1조 (목적) 이 규정은…"}] = blocks!("<text>제1조 (목적) 이 규정은…</text>")
      assert_round_trips("<text>제1조 (목적) 이 규정은…</text>")
    end

    test "headings carry a clamped level" do
      assert [%{"type" => "heading", "level" => 1, "text" => "a"}] =
               blocks!(~s(<heading level="0">a</heading>))

      assert [%{"level" => 6}] = blocks!(~s(<heading level="9">b</heading>))
      assert [%{"level" => 3}] = blocks!(~s(<heading level="3">c</heading>))
    end
  end

  describe "parse/1 — structural blocks" do
    test "lists split on the ldiv delimiter" do
      [block] = blocks!(~s(<list class="ordered"><ldiv/><text>one</text></list>))

      assert block == %{
               "type" => "list",
               "class" => "ordered",
               "items" => [%{"blocks" => [%{"type" => "text", "text" => "one"}]}]
             }

      assert_round_trips(~s(<list class="ordered"><ldiv/><text>one</text></list>))
      assert_round_trips(~s(<list class="unordered"><ldiv/><text>two</text></list>))
    end

    test "a page break is a bare void element" do
      assert [%{"type" => "page_break"}] = blocks!("<page_break/>")
      assert_round_trips("<page_break/>")
    end

    test "footnotes, headers and footers carry nested blocks" do
      assert [%{"type" => "footnote", "blocks" => [%{"text" => "note"}]}] =
               blocks!("<footnote><text>note</text></footnote>")

      assert_round_trips("<footnote><text>note</text></footnote>")
      assert_round_trips("<page_header><text>hdr</text></page_header>")
      assert_round_trips("<page_footer><text>ftr</text></page_footer>")
    end

    test "a picture carries its src uri" do
      body = ~s(<picture><src uri="data:image/png;base64,iVBORw0="/></picture>)
      assert [%{"type" => "picture", "src" => "data:image/png;base64,iVBORw0="}] = blocks!(body)
      assert_round_trips(body)
    end

    test "a formula carries its latex verbatim" do
      assert [%{"type" => "formula", "text" => "\\frac{1}{2}"}] =
               blocks!("<formula>\\frac{1}{2}</formula>")

      assert [%{"type" => "formula", "text" => "a < b"}] = blocks!("<formula>a &lt; b</formula>")
      assert_round_trips("<formula>a &lt; b</formula>")
    end

    test "a thread boundary is a group carrying a thread id" do
      assert [%{"type" => "group", "thread_id" => 1}] =
               blocks!(~s(<group><thread thread_id="1"/></group>))

      assert_round_trips(~s(<group><thread thread_id="1"/></group>))
    end
  end

  describe "parse/1 — Preserve-mode custom properties" do
    @custom ~s(<group><custom><hwp_prop name="ns" value="hwp:geometry"/>) <>
              ~s(<hwp_prop name="shape" value="box"/>) <>
              ~s(<hwp_prop name="width" value="51024"/></custom></group>)

    test "hwp_prop children become an ordered pair list, not a map" do
      assert [block] = blocks!(@custom)

      assert block["custom"] == [
               ["ns", "hwp:geometry"],
               ["shape", "box"],
               ["width", "51024"]
             ]

      assert_round_trips(@custom)
    end

    test "repeated names are preserved (extras may legitimately repeat)" do
      body =
        ~s(<text><custom><hwp_prop name="ns" value="hwp:style"/>) <>
          ~s(<hwp_prop name="extra" value="a=1"/>) <>
          ~s(<hwp_prop name="extra" value="b=2"/></custom>x</text>)

      assert [block] = blocks!(body)
      assert Doclang.custom_props(block, "extra") == ["a=1", "b=2"]
      assert Doclang.custom_prop(block, "ns") == "hwp:style"
      assert_round_trips(body)
    end

    test "a v2 <location> head is read as derived geometry" do
      body =
        ~s(<text><location value="10" resolution="512"/>) <>
          ~s(<location value="20" resolution="512"/>hi</text>)

      assert [%{"location" => [%{"value" => 10}, %{"value" => 20}]}] = blocks!(body)
      assert_round_trips(body)
    end
  end

  describe "parse/1 — OTSL tables" do
    test "a 1x1 table reconstructs its anchor cell and content" do
      body = "<table><fcel/><text>hi</text><nl/></table>"

      assert [block] = blocks!(body)

      assert block == %{
               "type" => "table",
               "rows" => 1,
               "cols" => 1,
               "cells" => [
                 %{
                   "row" => 0,
                   "col" => 0,
                   "row_span" => 1,
                   "col_span" => 1,
                   "header" => false,
                   "blocks" => [%{"type" => "text", "text" => "hi"}]
                 }
               ]
             }

      assert_round_trips(body)
    end

    test "header cells and empty cells keep their tokens" do
      body =
        "<table><ched/><text>H</text><ecel/><nl/><fcel/><text>a</text><fcel/><text>b</text><nl/></table>"

      assert [%{"rows" => 2, "cols" => 2, "cells" => cells}] = blocks!(body)
      assert [%{"header" => true}, %{"header" => false}, _, _] = cells
      assert_round_trips(body)
    end

    test "horizontal, vertical and cross merges reconstruct spans" do
      body = "<table><fcel/><text>x</text><lcel/><nl/><ucel/><xcel/><nl/></table>"

      assert [%{"rows" => 2, "cols" => 2, "cells" => [cell]}] = blocks!(body)
      assert cell["row_span"] == 2
      assert cell["col_span"] == 2
      assert_round_trips(body)
    end

    test "a nested table inside a cell round-trips" do
      body = "<table><fcel/><table><fcel/><text>in</text><nl/></table><nl/></table>"

      assert [%{"cells" => [%{"blocks" => [%{"type" => "table"}]}]}] = blocks!(body)
      assert_round_trips(body)
    end

    test "a caption precedes the OTSL stream" do
      body = "<table><caption>표 1</caption><fcel/><text>hi</text><nl/></table>"
      assert [%{"caption" => "표 1"}] = blocks!(body)
      assert_round_trips(body)
    end
  end

  describe "parse/1 — determinism" do
    @realistic ~s(<text>서문</text>) <>
                 ~s(<heading level="2">제1장</heading>) <>
                 ~s(<table><ched/><text>항목</text><ched/><text>금액</text><nl/>) <>
                 ~s(<fcel/><text>인건비</text><fcel/><text>1,200,000</text><nl/></table>) <>
                 ~s(<text></text>) <>
                 ~s(<list class="unordered"><ldiv/><text>가</text><ldiv/><text>나</text></list>) <>
                 ~s(<page_break/>)

    test "a pretty-printed buffer parses identically to the single-line one" do
      compact = doc(@realistic)

      pretty =
        compact
        |> String.replace("><", ">\n  <")
        |> then(&(&1 <> "\n"))

      assert Doclang.parse(compact) == Doclang.parse(pretty)
    end

    test "parsing is idempotent through a serialize round-trip" do
      assert_round_trips(@realistic)
    end

    test "an untouched buffer yields no changes" do
      nodes = [
        %{"type" => "paragraph", "text" => "서문", "ref" => %{"section" => 0, "paragraph" => 0}},
        %{"type" => "paragraph", "text" => "본문", "ref" => %{"section" => 0, "paragraph" => 1}}
      ]

      xml = Doclang.project(nodes, :hwp)
      assert Doclang.changes(nodes, xml, :hwp) == []
    end
  end

  describe "project/2" do
    test "emits DocLang XML from live rhwp IR nodes" do
      nodes = [
        %{"type" => "paragraph", "text" => "가", "ref" => %{"section" => 0, "paragraph" => 0}},
        %{"type" => "paragraph", "text" => "나", "ref" => %{"section" => 0, "paragraph" => 1}}
      ]

      assert Doclang.project(nodes, :hwp) ==
               ~s(<doclang version="0.6"><text>가</text><text>나</text></doclang>)
    end

    test "drops office run nodes (their text duplicates the paragraph)" do
      nodes = [
        %{"type" => "paragraph", "text" => "body", "ref" => "p0"},
        %{"type" => "run", "text" => "body", "ref" => "p0/r0"}
      ]

      assert Doclang.project(nodes, :docx) ==
               ~s(<doclang version="0.6"><text>body</text></doclang>)
    end

    test "folds office table cells back into a <table>" do
      nodes = [
        %{"type" => "table", "ref" => "tbl[Table1]"},
        %{
          "type" => "cell",
          "ref" => "tbl[Table1]/cell[A1]",
          "text" => "a",
          "row" => 1,
          "col" => 1
        },
        %{
          "type" => "cell",
          "ref" => "tbl[Table1]/cell[B1]",
          "text" => "b",
          "row" => 1,
          "col" => 2
        }
      ]

      assert Doclang.project(nodes, :docx) ==
               ~s(<doclang version="0.6"><table><fcel/><text>a</text><fcel/><text>b</text><nl/></table></doclang>)
    end
  end

  describe "changes/3 — the recursive positional scan" do
    defp hwp_nodes do
      [
        %{"type" => "paragraph", "text" => "old", "ref" => %{"section" => 0, "paragraph" => 0}},
        %{"type" => "paragraph", "text" => "keep", "ref" => %{"section" => 0, "paragraph" => 1}}
      ]
    end

    test "a text edit becomes replace_text against the LIVE ref" do
      edited = ~s(<doclang version="0.6"><text>new</text><text>keep</text></doclang>)

      assert [{:text, op, "new"}] = Doclang.changes(hwp_nodes(), edited, :hwp)

      assert op == %{
               "op" => "replace_text",
               "ref" => %{"section" => 0, "paragraph" => 0},
               "query" => "old",
               "replacement" => "new"
             }
    end

    test "filling an empty paragraph becomes insert_text" do
      nodes = [
        %{"type" => "paragraph", "text" => "", "ref" => %{"section" => 0, "paragraph" => 3}}
      ]

      edited = ~s(<doclang version="0.6"><text>filled</text></doclang>)

      assert [{:text, %{"op" => "insert_text", "text" => "filled"}, "filled"}] =
               Doclang.changes(nodes, edited, :hwp)
    end

    test "a cell edit inside a table recurses and routes through set_cell" do
      cell_ref = %{
        "section" => 0,
        "paragraph" => 4,
        "offset" => 0,
        "cell" => %{
          "parentParaIndex" => 4,
          "controlIndex" => 0,
          "cellIndex" => 0,
          "cellParaIndex" => 0
        }
      }

      nodes = [
        %{
          "type" => "table",
          "ref" => %{"section" => 0, "paragraph" => 4, "control" => 0},
          "rows" => 1,
          "cols" => 1
        },
        %{"type" => "cell", "ref" => cell_ref, "text" => "before"}
      ]

      edited =
        ~s(<doclang version="0.6"><table><fcel/><text>after</text><nl/></table></doclang>)

      assert [{:text, op, "after"}] = Doclang.changes(nodes, edited, :hwp)
      assert op == %{"op" => "set_cell", "ref" => cell_ref, "text" => "after"}
    end

    test "changing a node's type is a structural change" do
      edited = ~s(<doclang version="0.6"><page_break/><text>keep</text></doclang>)
      assert {:error, :structural_change} = Doclang.changes(hwp_nodes(), edited, :hwp)
    end

    test "an unroutable node (no live ref) fails closed" do
      nodes = [%{"type" => "paragraph", "text" => "x"}]
      edited = ~s(<doclang version="0.6"><text>y</text></doclang>)
      assert {:error, :unroutable} = Doclang.changes(nodes, edited, :hwp)
    end

    test "an inline-only formatting edit is refused rather than silently dropped" do
      nodes = [
        %{"type" => "paragraph", "text" => "ab", "ref" => %{"section" => 0, "paragraph" => 0}}
      ]

      edited = ~s(<doclang version="0.6"><text>a<bold>b</bold></text></doclang>)

      assert {:error, {:unsupported_edit, :inline_formatting}} =
               Doclang.changes(nodes, edited, :hwp)
    end

    test "a new picture becomes insert_picture anchored to the previous paragraph" do
      edited =
        ~s(<doclang version="0.6"><text>old</text>) <>
          ~s(<picture><src uri="/tmp/a.png"/></picture><text>keep</text></doclang>)

      assert [{:insert_picture, op, "/tmp/a.png", _props}] =
               Doclang.changes(hwp_nodes(), edited, :hwp)

      assert op["op"] == "insert_picture"
      assert op["src"] == "/tmp/a.png"
      assert op["ref"] == %{"section" => 0, "paragraph" => 0, "offset" => 3}
    end

    test "removing a picture becomes delete_node with the live ref" do
      picture_ref = %{"section" => 0, "paragraph" => 1, "control" => 0, "type" => "picture"}

      nodes = [
        %{"type" => "paragraph", "text" => "a", "ref" => %{"section" => 0, "paragraph" => 0}},
        %{"type" => "picture", "src" => "/tmp/a.png", "ref" => picture_ref},
        %{"type" => "paragraph", "text" => "b", "ref" => %{"section" => 0, "paragraph" => 2}}
      ]

      edited = ~s(<doclang version="0.6"><text>a</text><text>b</text></doclang>)

      assert [{:delete_node, %{"op" => "delete_node", "ref" => ^picture_ref}, "/tmp/a.png"}] =
               Doclang.changes(nodes, edited, :hwp)
    end

    test "a new table becomes insert_table with its cell text" do
      edited =
        ~s(<doclang version="0.6"><text>old</text>) <>
          ~s(<table><fcel/><text>a</text><fcel/><text>b</text><nl/></table>) <>
          ~s(<text>keep</text></doclang>)

      assert [{:insert_table, op, "a"}] = Doclang.changes(hwp_nodes(), edited, :hwp)
      assert op["rows"] == 1
      assert op["cols"] == 2
      assert op["cells"] == [["a", "b"]]
    end

    test "a malformed buffer reports the XML error instead of guessing" do
      assert {:error, {:malformed_xml, _}} =
               Doclang.changes(hwp_nodes(), "<doclang><text>", :hwp)
    end

    test "office text edits recover the opaque UNO ref" do
      nodes = [
        %{"type" => "paragraph", "text" => "old", "ref" => "p0"},
        %{"type" => "paragraph", "text" => "keep", "ref" => "p1"}
      ]

      edited = ~s(<doclang version="0.6"><text>new</text><text>keep</text></doclang>)

      assert [{:text, %{"op" => "replace_text", "ref" => "p0"}, "new"}] =
               Doclang.changes(nodes, edited, :docx)
    end
  end

  describe "shallow/1 and child_blocks/1" do
    test "shallow strips child content but keeps cell geometry" do
      [table] = blocks!("<table><fcel/><text>hi</text><nl/></table>")

      assert Doclang.shallow(table) == %{
               "type" => "table",
               "rows" => 1,
               "cols" => 1,
               "cells" => [
                 %{"row" => 0, "col" => 0, "row_span" => 1, "col_span" => 1, "header" => false}
               ]
             }
    end

    test "child_blocks flattens across the container key" do
      [table] = blocks!("<table><fcel/><text>a</text><fcel/><text>b</text><nl/></table>")

      assert Doclang.child_blocks(table) == [
               %{"type" => "text", "text" => "a"},
               %{"type" => "text", "text" => "b"}
             ]

      [list] = blocks!(~s(<list class="ordered"><ldiv/><text>x</text></list>))
      assert Doclang.child_blocks(list) == [%{"type" => "text", "text" => "x"}]
    end
  end
end
