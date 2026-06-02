defmodule Ecrits.Local.Agent.ToolRegistryTest do
  use ExUnit.Case, async: false

  alias Ecrits.Local.Agent.LocalDocSessionStub
  alias Ecrits.Local.Agent.ToolRegistry
  alias Ecrits.Local.Document

  test "lists namespaced doc read, find and write tools" do
    tools = ToolRegistry.tools()
    names = ToolRegistry.tool_names()

    assert names == ["doc.read", "doc.find", "doc.write"]

    assert Enum.map(tools, &{&1["namespace"], &1["name"]}) == [
             {"doc", "read"},
             {"doc", "find"},
             {"doc", "write"}
           ]

    refute Enum.any?(tools, &String.contains?(&1["name"], "."))
    refute tools |> inspect() |> String.contains?("positionalindex")

    find_tool = Enum.find(tools, &(&1["name"] == "find"))
    assert get_in(find_tool, ["inputSchema", "required"]) == ["pattern"]
    assert get_in(find_tool, ["inputSchema", "properties", "pattern", "minLength"]) == 1
    assert get_in(find_tool, ["inputSchema", "properties", "case_sensitive", "default"]) == false
    assert get_in(find_tool, ["annotations", "readOnlyHint"]) == true

    write_tool = Enum.find(tools, &(&1["name"] == "write"))
    assert write_tool["description"] =~ "Native write persistence"
    assert get_in(write_tool, ["inputSchema", "required"]) == ["query", "replacement"]
    assert get_in(write_tool, ["inputSchema", "properties", "query", "minLength"]) == 1
    assert get_in(write_tool, ["inputSchema", "properties", "replacement", "type"]) == "string"
  end

  test "calls read and write through active document session module" do
    pid =
      start_supervised!(
        {LocalDocSessionStub,
         [
           read: {:ok, %{"revision" => 7, "text" => "Alpha"}},
           write: {:ok, %{"revision" => 8}}
         ]}
      )

    session = %{
      document_session: pid,
      document_session_module: LocalDocSessionStub,
      access_control: "full-workspace"
    }

    assert {:ok, %{"text" => "Alpha"}} = ToolRegistry.call(session, "doc.read", %{"at" => 0})
    assert {:ok, %{"revision" => 8}} = ToolRegistry.call(session, "doc.write", %{"text" => "!"})

    assert [
             {:read, %{"at" => 0}},
             {:write, %{"text" => "!"}}
           ] = LocalDocSessionStub.calls(pid)
  end

  test "approval policy treats writes as gated and reads as safe" do
    refute ToolRegistry.requires_approval?(:on_write, "doc.read")
    refute ToolRegistry.requires_approval?(:on_write, "doc.find")
    assert ToolRegistry.requires_approval?(:on_write, "doc.write")
    refute ToolRegistry.requires_approval?(:never, "doc.write")
    assert ToolRegistry.requires_approval?(:always, "doc.read")
  end

  test "doc.read returns native text for the active local document" do
    {document, _bytes} = open_document!()
    session = %{document_id: document.id}

    assert {:ok, read} = ToolRegistry.call(session, "doc.read", %{})

    assert read["document_id"] == document.id
    assert read["relative_path"] == "docs/current.hwpx"
    assert read["format"] == "hwpx"
    assert read["revision"] == document.revision
    assert read["text"] =~ "전력기술관리법"
    assert read["content"] == read["text"]
  end

  test "doc.find returns native matches with windowing" do
    {document, _bytes} = open_document!()
    session = %{document_id: document.id}

    assert {:ok, find} =
             ToolRegistry.call(session, "doc.find", %{
               "pattern" => "전력기술",
               "at" => 0,
               "size" => 2
             })

    assert find["document_id"] == document.id
    assert find["pattern"] == "전력기술"
    assert find["total"] > 2
    assert find["next_at"] == 2

    assert [
             %{"sec" => 0, "para" => para, "off" => off, "count" => 4},
             %{"sec" => 0, "para" => _, "off" => _, "count" => 4}
           ] = find["matches"]

    assert is_integer(para)
    assert is_integer(off)
  end

  test "doc.write reaches native runtime but refuses false persistence" do
    {document, _bytes} = open_document!()
    session = %{document_id: document.id, access_control: "full-workspace"}

    assert {:error, {:not_supported, message}} =
             ToolRegistry.call(session, "doc.write", %{
               "query" => "전력기술관리법",
               "replacement" => "전력기술관리법",
               "base_revision" => document.revision
             })

    assert message =~ "cannot persist changed bytes"
  end

  test "doc.write is denied for read-only access" do
    {document, _bytes} = open_document!()
    session = %{document_id: document.id, access_control: "read-only"}

    assert {:error, {:write_denied, message}} =
             ToolRegistry.call(session, "doc.write", %{
               "query" => "전력기술",
               "replacement" => "전력기술"
             })

    assert message =~ "read-only"
  end

  defp open_document! do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-local-agent-tool-registry-#{System.unique_integer([:positive])}"
      )

    bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    path = Path.join([root, "docs", "current.hwpx"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    assert {:ok, document} = Document.open(root, "docs/current.hwpx")

    on_exit(fn ->
      _ = Document.close(document.id)
      File.rm_rf(root)
    end)

    {document, bytes}
  end
end
