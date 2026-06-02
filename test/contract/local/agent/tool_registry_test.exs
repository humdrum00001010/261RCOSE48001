defmodule Contract.Local.Agent.ToolRegistryTest do
  use ExUnit.Case, async: false

  alias Contract.Local.Agent.LocalDocSessionStub
  alias Contract.Local.Agent.ToolRegistry
  alias Contract.Local.Document
  alias Contract.RhwpSnapshot.Materializer

  test "lists namespaced positional index read, find and write tools" do
    tools = ToolRegistry.tools()
    names = ToolRegistry.tool_names()

    assert names == ["positionalindex.read", "positionalindex.find", "positionalindex.write"]

    assert Enum.map(tools, &{&1["namespace"], &1["name"]}) == [
             {"positionalindex", "read"},
             {"positionalindex", "find"},
             {"positionalindex", "write"}
           ]

    refute Enum.any?(tools, &String.contains?(&1["name"], "."))

    find_tool = Enum.find(tools, &(&1["name"] == "find"))
    assert get_in(find_tool, ["inputSchema", "required"]) == ["pattern"]
    assert get_in(find_tool, ["inputSchema", "properties", "pattern", "minLength"]) == 1
    assert get_in(find_tool, ["inputSchema", "properties", "case_sensitive", "default"]) == false
    assert get_in(find_tool, ["annotations", "readOnlyHint"]) == true

    write_tool = Enum.find(tools, &(&1["name"] == "write"))
    assert write_tool["description"] =~ "No start/end"

    write_payload_props =
      get_in(write_tool, [
        "inputSchema",
        "properties",
        "payload",
        "properties",
        "payload",
        "properties"
      ])

    assert Map.has_key?(write_payload_props, "off")
    assert Map.has_key?(write_payload_props, "count")
    assert Map.has_key?(write_payload_props, "text")
    refute Map.has_key?(write_payload_props, "start")
    refute Map.has_key?(write_payload_props, "end")
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

    assert {:ok, %{"text" => "Alpha"}} =
             ToolRegistry.call(session, "positionalindex.read", %{"at" => 0})

    assert {:ok, %{"revision" => 8}} =
             ToolRegistry.call(session, "positionalindex.write", %{"text" => "!"})

    assert [
             {:read, %{"at" => 0}},
             {:write, %{"text" => "!"}}
           ] = LocalDocSessionStub.calls(pid)
  end

  test "approval policy treats writes as gated and reads as safe" do
    refute ToolRegistry.requires_approval?(:on_write, "positionalindex.read")
    refute ToolRegistry.requires_approval?(:on_write, "positionalindex.find")
    assert ToolRegistry.requires_approval?(:on_write, "positionalindex.write")
    refute ToolRegistry.requires_approval?(:never, "positionalindex.write")
    assert ToolRegistry.requires_approval?(:always, "positionalindex.read")
  end

  test "positionalindex read returns a real local document slice with position refs" do
    {document, _bytes} =
      open_document_with_ir!([
        "Alpha first paragraph",
        "Beta second paragraph"
      ])

    session = %{document_id: document.id}

    assert {:ok, read} =
             ToolRegistry.call(session, "positionalindex.read", %{
               "sec" => 0,
               "at" => 0,
               "size" => 1
             })

    assert read["document_id"] == document.id
    assert read["revision"] == document.revision
    assert read["counts"]["paragraphs"] == 2
    assert read["counts"]["paragraph_refs"] == 2
    assert read["next_at"] == 1

    assert [
             %{
               "kind" => "paragraph",
               "sec" => 0,
               "para" => 0,
               "text" => "Alpha first paragraph",
               "chars" => 21,
               "page" => 0,
               "off_start" => 0,
               "off_end" => 21
             }
           ] = read["items"]
  end

  test "positionalindex find returns Korean regex offsets usable by replace_range" do
    paragraph = "계약기간은 2026년 6월 1일부터 2027년 5월 31일까지이다"
    {document, bytes} = open_document_with_ir!([paragraph])

    session = %{document_id: document.id, access_control: "full-workspace"}
    pattern = "\\d{4}년 \\d+월 \\d+일"
    match_text = "2026년 6월 1일"
    replacement = "2026년 7월 1일"
    off = String.length("계약기간은 ")
    count = String.length(match_text)

    assert {:ok, find} =
             ToolRegistry.call(session, "positionalindex.find", %{
               "pattern" => pattern,
               "size" => 1
             })

    assert find["revision"] == document.revision
    assert find["total"] == 2
    assert find["next_at"] == 1

    assert [
             %{
               "sec" => 0,
               "para" => 0,
               "off" => ^off,
               "count" => ^count,
               "text" => ^match_text,
               "paragraph" => ^paragraph,
               "page" => 0,
               "off_start" => 0
             } = match
           ] = find["matches"]

    assert match["off_end"] == String.length(paragraph)

    :ok = Materializer.register_editor(document.id)
    on_exit(fn -> Materializer.unregister_editor(document.id) end)

    args = %{
      "sec" => match["sec"],
      "para" => match["para"],
      "type" => "paragraph",
      "base_revision" => find["revision"],
      "payload" => %{
        "cmd" => "replace_range",
        "payload" => %{
          "off" => match["off"],
          "count" => match["count"],
          "text" => replacement
        }
      }
    }

    task_supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ToolRegistry.call(session, "positionalindex.write", args)
      end)

    assert_receive {:rhwp_positional_index_request,
                    %{request_id: request_id, document_id: document_id, text_events: events}},
                   1_000

    assert document_id == document.id

    assert [
             %{
               "kind" => "delete_text",
               "sec" => 0,
               "para" => 0,
               "off" => ^off,
               "count" => ^count
             },
             %{
               "kind" => "insert_text",
               "sec" => 0,
               "para" => 0,
               "off" => ^off,
               "text" => ^replacement
             }
           ] = events

    updated = String.replace(paragraph, match_text, replacement, global: false)
    updated_ir = ir_for([updated])
    assert {:ok, saved, _snapshot} = Document.save(document.id, bytes, %{ir: updated_ir})

    :ok =
      Materializer.ack(request_id, %{
        status: :committed,
        document_id: document.id,
        revision: saved.revision,
        snapshot: %{}
      })

    assert {:ok, %{"document_id" => document_id, "revision" => 2, "events" => 2}} =
             Task.await(task)

    assert document_id == document.id
  end

  test "positionalindex find reports invalid regex as invalid params" do
    {document, _bytes} = open_document_with_ir!(["Alpha"])
    session = %{document_id: document.id}

    assert {:error, {:invalid_params, message}} =
             ToolRegistry.call(session, "positionalindex.find", %{"pattern" => "["})

    assert message =~ "pattern is invalid regex"
  end

  test "positionalindex write mutates active local document through materializer request" do
    {document, bytes} = open_document_with_ir!(["Alpha Beta"])
    :ok = Materializer.register_editor(document.id)
    on_exit(fn -> Materializer.unregister_editor(document.id) end)

    session = %{document_id: document.id, access_control: "full-workspace"}

    args = %{
      "sec" => 0,
      "para" => 0,
      "type" => "paragraph",
      "base_revision" => document.revision,
      "payload" => %{
        "cmd" => "insert_after_match",
        "payload" => %{"match" => "Beta", "text" => " inserted"}
      }
    }

    task_supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ToolRegistry.call(session, "positionalindex.write", args)
      end)

    assert_receive {:rhwp_positional_index_request,
                    %{request_id: request_id, document_id: document_id, text_events: events}},
                   1_000

    assert document_id == document.id

    assert [
             %{
               "kind" => "insert_text",
               "sec" => 0,
               "para" => 0,
               "off" => 10,
               "text" => " inserted"
             }
           ] = events

    updated_ir = ir_for(["Alpha Beta inserted"])
    assert {:ok, saved, _snapshot} = Document.save(document.id, bytes, %{ir: updated_ir})

    :ok =
      Materializer.ack(request_id, %{
        status: :committed,
        document_id: document.id,
        revision: saved.revision,
        snapshot: %{}
      })

    assert {:ok, %{"document_id" => document_id, "revision" => 2, "events" => 1}} =
             Task.await(task)

    assert document_id == document.id

    assert {:ok, read} =
             ToolRegistry.call(session, "positionalindex.read", %{
               "sec" => 0,
               "at" => 0,
               "size" => 1
             })

    assert [%{"text" => "Alpha Beta inserted"}] = read["items"]
  end

  test "positionalindex write can replace a full paragraph through delete and insert events" do
    {document, bytes} = open_document_with_ir!(["Alpha placeholder"])
    :ok = Materializer.register_editor(document.id)
    on_exit(fn -> Materializer.unregister_editor(document.id) end)

    session = %{document_id: document.id, access_control: "full-workspace"}

    args = %{
      "sec" => 0,
      "para" => 0,
      "type" => "paragraph",
      "base_revision" => document.revision,
      "payload" => %{
        "cmd" => "replace_paragraph",
        "payload" => %{"text" => "Final line"}
      }
    }

    task_supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ToolRegistry.call(session, "positionalindex.write", args)
      end)

    assert_receive {:rhwp_positional_index_request,
                    %{request_id: request_id, document_id: document_id, text_events: events}},
                   1_000

    assert document_id == document.id

    assert [
             %{
               "kind" => "delete_text",
               "sec" => 0,
               "para" => 0,
               "off" => 0,
               "count" => 17
             },
             %{
               "kind" => "insert_text",
               "sec" => 0,
               "para" => 0,
               "off" => 0,
               "text" => "Final line"
             }
           ] = events

    updated_ir = ir_for(["Final line"])
    assert {:ok, saved, _snapshot} = Document.save(document.id, bytes, %{ir: updated_ir})

    :ok =
      Materializer.ack(request_id, %{
        status: :committed,
        document_id: document.id,
        revision: saved.revision,
        snapshot: %{}
      })

    assert {:ok, %{"document_id" => document_id, "revision" => 2, "events" => 2}} =
             Task.await(task)

    assert document_id == document.id
  end

  test "positionalindex write is denied for read-only access" do
    {document, _bytes} = open_document_with_ir!(["Alpha Beta"])

    session = %{document_id: document.id, access_control: "read-only"}

    args = %{
      "sec" => 0,
      "para" => 0,
      "type" => "paragraph",
      "base_revision" => document.revision,
      "payload" => %{
        "cmd" => "insert_at_offset",
        "payload" => %{"off" => 0, "text" => "X"}
      }
    }

    assert {:error, {:write_denied, message}} =
             ToolRegistry.call(session, "positionalindex.write", args)

    assert message =~ "read-only"
  end

  defp open_document_with_ir!(paragraphs) do
    root =
      Path.join(
        System.tmp_dir!(),
        "contract-local-agent-tool-registry-#{System.unique_integer([:positive])}"
      )

    bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    path = Path.join([root, "docs", "current.hwpx"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    assert {:ok, document} = Document.open(root, "docs/current.hwpx")

    assert {:ok, document, _snapshot} =
             Document.checkpoint(document, bytes, %{ir: ir_for(paragraphs)})

    on_exit(fn ->
      _ = Document.close(document.id)
      File.rm_rf(root)
    end)

    {document, bytes}
  end

  defp ir_for(paragraphs) do
    %{
      "version" => 1,
      "title" => "current.hwpx",
      "contract_type" => "local_hwpx",
      "sections" => [
        %{
          "idx" => 0,
          "paragraphs" =>
            paragraphs
            |> Enum.with_index()
            |> Enum.map(fn {text, index} -> %{"idx" => index, "text" => text} end)
        }
      ],
      "positional_index" => %{
        "version" => 1,
        "paragraphs" =>
          paragraphs
          |> Enum.with_index()
          |> Enum.map(fn {text, index} ->
            %{
              "sec" => 0,
              "para" => index,
              "page" => index,
              "off_start" => 0,
              "off_end" => String.length(text)
            }
          end),
        "tables" => []
      }
    }
  end
end
