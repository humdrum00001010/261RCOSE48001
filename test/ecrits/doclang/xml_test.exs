defmodule Doclang.XmlTest do
  use ExUnit.Case, async: true

  alias Doclang.Xml

  describe "parse/1" do
    test "reads elements, attributes and nested children" do
      assert {:ok, {:element, "doclang", %{"version" => "0.6"}, children}} =
               Xml.parse(~s(<doclang version="0.6"><text>hi</text></doclang>))

      assert [{:element, "text", %{}, [{:text, "hi"}]}] = children
    end

    test "reads self-closing elements" do
      assert {:ok, {:element, "doclang", _, [{:element, "page_break", %{}, []}]}} =
               Xml.parse(~s(<doclang version="0.6"><page_break/></doclang>))
    end

    test "accepts single-quoted attribute values" do
      assert {:ok, {:element, "a", %{"b" => "c"}, []}} = Xml.parse("<a b='c'/>")
    end

    test "decodes the five predefined entities" do
      assert {:ok, {:element, "t", _, [{:text, "a & b < c > d \" e ' f"}]}} =
               Xml.parse("<t>a &amp; b &lt; c &gt; d &quot; e &apos; f</t>")
    end

    test "decodes numeric character references" do
      assert {:ok, {:element, "t", _, [{:text, "AZ한"}]}} =
               Xml.parse("<t>&#65;&#x5A;&#xD55C;</t>")
    end

    test "leaves an unknown entity literal rather than failing" do
      assert {:ok, {:element, "t", _, [{:text, "a &nope; b"}]}} = Xml.parse("<t>a &nope; b</t>")
    end

    test "merges adjacent character data into one node" do
      assert {:ok, {:element, "t", _, [{:text, "a&b"}]}} = Xml.parse("<t>a&amp;b</t>")
    end

    test "skips the xml declaration, comments and doctype" do
      xml =
        ~s(<?xml version="1.0"?><!-- lead --><!DOCTYPE doclang><d><!--in--><t/></d><!-- tail -->)

      assert {:ok, {:element, "d", _, [{:element, "t", %{}, []}]}} = Xml.parse(xml)
    end

    test "reads CDATA verbatim" do
      assert {:ok, {:element, "t", _, [{:text, "a < b & c"}]}} =
               Xml.parse("<t><![CDATA[a < b & c]]></t>")
    end

    test "handles UTF-8 element content and attribute values" do
      assert {:ok, {:element, "t", %{"n" => "나눔고딕"}, [{:text, "한글 문서"}]}} =
               Xml.parse(~s(<t n="나눔고딕">한글 문서</t>))
    end

    test "rejects a mismatched close tag" do
      assert {:error, {:mismatched_close_tag, "b", _}} = Xml.parse("<a><b></a></b>")
    end

    test "rejects trailing content after the root" do
      assert {:error, {:trailing_content, _}} = Xml.parse("<a/><b/>")
    end

    test "rejects an unterminated attribute value" do
      assert {:error, :unterminated_attribute_value} = Xml.parse(~s(<a b="c/>))
    end

    test "rejects a non-binary input" do
      assert {:error, :not_a_binary} = Xml.parse(:nope)
    end
  end

  describe "encode/1" do
    test "round-trips a parsed tree" do
      xml = ~s(<doclang version="0.6"><text>a &amp; b</text><page_break/></doclang>)
      assert {:ok, tree} = Xml.parse(xml)
      assert IO.iodata_to_binary(Xml.encode(tree)) == xml
    end

    test "escapes text and attributes with the writer's rules" do
      assert Xml.escape_text(~s(a & b < c > d "e" 'f')) ==
               ~s(a &amp; b &lt; c &gt; d "e" 'f')

      assert Xml.escape_attr(~s(a&b<c>"d"'e')) == "a&amp;b&lt;c&gt;&quot;d&quot;&apos;e&apos;"
    end
  end
end
