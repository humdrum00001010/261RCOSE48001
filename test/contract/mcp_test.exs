defmodule Contract.MCPTest do
  use Contract.DataCase, async: false

  import Ecto.Query

  alias Contract.Agent.Document
  alias Contract.Change
  alias Contract.Command
  alias Contract.Context
  alias Contract.MCP
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Runtime
  alias Contract.RhwpSnapshot.Materializer

  describe "list_tools/2" do
    test "exposes compact doc access tools only" do
      assert %{"tools" => tools} = MCP.list_tools(%Context{}, nil)
      names = Enum.map(tools, & &1["name"])

      assert names == ~w(doc.get doc.read doc.write)
      refute "doc.edit" in names
      refute "doc.find" in names
      refute "doc.edit_text" in names
    end

    test "schemas keep old public coordinates out" do
      assert %{"tools" => tools} = MCP.list_tools(%Context{}, nil)

      get = Enum.find(tools, &(&1["name"] == "doc.get"))
      read = Enum.find(tools, &(&1["name"] == "doc.read"))
      write = Enum.find(tools, &(&1["name"] == "doc.write"))

      assert Map.keys(get["inputSchema"]["properties"]) == ["since_revision"]
      refute Map.has_key?(get["inputSchema"]["properties"], "type")
      assert Map.keys(read["inputSchema"]["properties"]) |> Enum.sort() == ~w(at sec size)
      assert read["inputSchema"]["required"] == ["sec", "at"]

      assert write["inputSchema"]["required"] == [
               "sec",
               "para",
               "type",
               "payload",
               "base_revision"
             ]

      public_text = inspect(tools)
      refute public_text =~ "paragraph_index"
      refute public_text =~ "leaf_index"
      refute public_text =~ "cell_path"
      refute public_text =~ "field_id"
      assert public_text =~ "insert_at_offset"
    end
  end

  describe "list_resources/2 and read_resource/3" do
    test "resources are pruned" do
      owner = scope()
      doc_id = create_doc(owner, title: "Owner MCP Resource")

      assert %{"resources" => []} = MCP.list_resources(owner, nil)
      assert {:error, :invalid_uri} = MCP.read_resource(owner, nil, "document://#{doc_id}/state")
    end
  end

  describe "call_tool/4" do
    setup do
      owner = scope()

      doc_id =
        doc_with_paragraphs(owner, [
          "Title",
          "Alpha Beta Gamma",
          "One",
          "Two",
          "Three",
          "Four",
          "Five"
        ])

      start_materializing_editor!(doc_id)

      {:ok, owner: owner, doc_id: doc_id, route_ref: doc_mcp_route_ref(owner, doc_id)}
    end

    test "legacy public doc tools are unknown", %{owner: owner, route_ref: route_ref} do
      for tool <- ~w(doc.edit doc.find doc.edit_text doc.insert_block doc.delete_block) do
        assert {:error, {:unknown_tool, ^tool}} = MCP.call_tool(owner, route_ref, tool, %{})
      end
    end

    test "doc.get is metadata-only and rejects type mode", %{owner: owner, route_ref: route_ref} do
      assert {:ok, payload} = MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert Map.keys(payload) |> Enum.sort() == ~w(counts d revision t)
      assert payload["counts"]["sections"] == 1
      assert payload["counts"]["paragraphs"] == 7
      assert payload["counts"]["logical_leaves"] == 7
      refute_forbidden_agent_keys(payload)

      concrete_payload = Map.drop(payload, ["counts"])

      for key <-
            ~w(read outline index cursors pages table_controls paragraph_refs cell_refs bbox text) do
        refute deep_key?(concrete_payload, key)
      end

      assert {:error, {:invalid_params, message}} =
               MCP.call_tool(owner, route_ref, "doc.get", %{"type" => "paragraph_index"})

      assert message =~ "metadata-only"
    end

    test "doc.read returns only action coordinates and content", %{
      owner: owner,
      route_ref: route_ref
    } do
      assert {:ok, read} = MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "at" => 0})

      assert Map.keys(read) |> Enum.sort() == ~w(at items next_at revision sec)
      assert read["revision"] == 1
      assert read["sec"] == 0
      assert read["at"] == 0
      assert length(read["items"]) == 5

      assert %{"kind" => "paragraph", "sec" => 0, "para" => 0, "text" => _, "chars" => _} =
               hd(read["items"])

      refute_forbidden_agent_keys(read)
      refute deep_key?(read, "target")
      refute deep_key?(read, "off")
      refute deep_key?(read, "size")
    end

    test "doc.write insert_after_match commits doc_write change with internal offset", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{
        "sec" => 0,
        "para" => 1,
        "type" => "paragraph",
        "base_revision" => 1,
        "payload" => %{
          "cmd" => "insert_after_match",
          "payload" => %{"match" => "Beta", "text" => " inserted"}
        }
      }

      stale_projection = Contract.RhwpSnapshot.latest_for_document(doc_id).projection
      insert_rhwp_snapshot!(doc_id, 2, stale_projection)

      assert {:ok, %{"revision" => 2} = write} =
               MCP.call_tool(owner, route_ref, "doc.write", args)

      assert Map.keys(write) == ["revision"]
      refute_forbidden_agent_keys(write)

      [change] = changes_for(doc_id, "doc_write")
      assert change.command_kind == "doc_write"
      assert [%{"op" => "insert_text", "args" => op_args}] = change.payload
      assert op_args["sec"] == 0
      assert op_args["para"] == 1
      assert op_args["off"] == 10
      assert op_args["text"] == " inserted"

      assert {:ok, read} = MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "at" => 0})

      assert Enum.any?(read["items"], fn item ->
               item["para"] == 1 and item["text"] == "Alpha Beta inserted Gamma"
             end)

      assert %{revision: 2, projection: projection} =
               Contract.RhwpSnapshot.latest_for_document(doc_id)

      assert inspect(projection) =~ "Alpha Beta inserted Gamma"
    end

    test "doc.write repairs stale same-revision snapshot before fresh write", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      stale_projection = Contract.RhwpSnapshot.latest_for_document(doc_id).projection

      command = %Command{
        kind: :doc_write,
        actor_type: :agent,
        actor_id: owner.user.id,
        document_id: doc_id,
        base_revision: 1,
        idempotency_key: "poisoned-doc-write-#{Ecto.UUID.generate()}",
        payload: %{
          "type" => "paragraph",
          "sec" => 0,
          "para" => 1,
          "payload" => %{
            "cmd" => "insert_after_match",
            "payload" => %{"match" => "Beta", "text" => " stale"}
          },
          "resolved" => %{"off" => 10}
        }
      }

      assert {:ok, %Change{result_revision: 2}} = Runtime.apply(owner, command)
      insert_rhwp_snapshot!(doc_id, 2, stale_projection)

      args = %{
        "sec" => 0,
        "para" => 1,
        "type" => "paragraph",
        "base_revision" => 2,
        "payload" => %{
          "cmd" => "insert_after_match",
          "payload" => %{"match" => "Gamma", "text" => " repaired"}
        }
      }

      assert {:ok, %{"revision" => 3}} = MCP.call_tool(owner, route_ref, "doc.write", args)

      assert_receive {:materialization_base_snapshot, 1}, 1_000

      assert %{revision: 3, projection: projection} =
               Contract.RhwpSnapshot.latest_for_document(doc_id)

      assert inspect(projection) =~ "Alpha Beta stale Gamma repaired"
    end

    test "doc.write duplicate retry uses doc.write canonical idempotency", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{
        "sec" => 0,
        "para" => 1,
        "type" => "paragraph",
        "base_revision" => 1,
        "payload" => %{
          "cmd" => "insert_before_match",
          "payload" => %{"match" => "Beta", "text" => "pre "}
        }
      }

      assert {:ok, %{"revision" => revision}} = MCP.call_tool(owner, route_ref, "doc.write", args)

      assert {:ok, %{"revision" => ^revision} = retry} =
               MCP.call_tool(owner, route_ref, "doc.write", args)

      assert Map.keys(retry) == ["revision"]
      refute_forbidden_agent_keys(retry)
      assert [_change] = changes_for(doc_id, "doc_write")
    end

    test "ambiguous or missing match fails closed without commit", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_paragraphs(owner, ["Alpha Alpha"])
      route_ref = %{route_ref | document_id: doc_id}

      before_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      ambiguous = %{
        "sec" => 0,
        "para" => 0,
        "type" => "paragraph",
        "base_revision" => 1,
        "payload" => %{
          "cmd" => "insert_after_match",
          "payload" => %{"match" => "Alpha", "text" => "!"}
        }
      }

      missing = put_in(ambiguous, ["payload", "payload", "match"], "Beta")

      Phoenix.PubSub.subscribe(Contract.PubSub, "agent:#{route_ref.agent_run_id}")

      assert {:error, {:invalid_params, "match is ambiguous in paragraph"}} =
               MCP.call_tool(owner, route_ref, "doc.write", ambiguous)

      assert_receive {:tool_call_failed, _, _, failed_operation}
      assert failed_operation["name"] == "doc.write"
      assert failed_operation["error"] =~ "match is ambiguous"

      encoded_failure = Jason.encode!(failed_operation)

      for forbidden <-
            ~w(raw_name server_label status title summary reason tool_name type details arguments) do
        refute encoded_failure =~ forbidden
      end

      assert {:error, {:invalid_params, "match not found in paragraph"}} =
               MCP.call_tool(owner, route_ref, "doc.write", missing)

      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_ids
    end

    test "doc.write insert_at_offset commits exact offset after ambiguous match", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_paragraphs(owner, ["Alpha Alpha"])
      start_materializing_editor!(doc_id)
      route_ref = %{route_ref | document_id: doc_id}

      ambiguous = %{
        "sec" => 0,
        "para" => 0,
        "type" => "paragraph",
        "base_revision" => 1,
        "payload" => %{
          "cmd" => "insert_after_match",
          "payload" => %{"match" => "Alpha", "text" => "!"}
        }
      }

      assert {:error, {:invalid_params, "match is ambiguous in paragraph"}} =
               MCP.call_tool(owner, route_ref, "doc.write", ambiguous)

      exact =
        put_in(ambiguous, ["payload"], %{
          "cmd" => "insert_at_offset",
          "payload" => %{"off" => 5, "text" => "!"}
        })

      assert {:ok, %{"revision" => 2}} = MCP.call_tool(owner, route_ref, "doc.write", exact)

      assert {:ok, read} = MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "at" => 0})

      assert Enum.any?(read["items"], fn item ->
               item["para"] == 0 and item["text"] == "Alpha! Alpha"
             end)
    end

    test "doc.write insert_at_offset fails closed outside paragraph bounds", %{
      owner: owner,
      route_ref: route_ref
    } do
      args = %{
        "sec" => 0,
        "para" => 1,
        "type" => "paragraph",
        "base_revision" => 1,
        "payload" => %{
          "cmd" => "insert_at_offset",
          "payload" => %{"off" => 999, "text" => "!"}
        }
      }

      assert {:error, {:invalid_params, "off is outside paragraph bounds"}} =
               MCP.call_tool(owner, route_ref, "doc.write", args)
    end

    test "doc.write cell/table family fails closed", %{owner: owner, route_ref: route_ref} do
      assert {:error, {:not_supported, message}} =
               MCP.call_tool(owner, route_ref, "doc.write", %{
                 "sec" => 0,
                 "para" => 0,
                 "type" => "cell",
                 "base_revision" => 1,
                 "payload" => %{"cmd" => "insert_after_match", "payload" => %{}}
               })

      assert message =~ "not supported"
    end

    test "agent_doc route_ref without active run is rejected", %{
      owner: owner,
      route_ref: route_ref
    } do
      route_ref = %{route_ref | agent_run_id: nil}

      assert {:error, {:forbidden, :run_not_active}} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})
    end
  end

  describe "initialize/1" do
    test "returns MCP capabilities for tools and resources" do
      assert %{"protocolVersion" => _, "serverInfo" => server, "capabilities" => caps} =
               MCP.initialize(%{})

      assert server["name"] == "contract-studio"
      assert is_map(caps["tools"])
      assert is_map(caps["resources"])
    end
  end

  defp create_doc(%Context{} = ctx, opts) do
    doc_id = Ecto.UUID.generate()
    title = Keyword.fetch!(opts, :title)

    command = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => title, "type_key" => "nda_v1"}
    }

    assert {:ok, %Change{}} = Runtime.apply(ctx, command)
    doc_id
  end

  defp scope do
    user_id = Ecto.UUID.generate()

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "mcp-#{user_id}@example.test"
      }
    }
  end

  defp doc_with_paragraphs(%Context{} = ctx, texts) do
    doc_id = create_doc(ctx, title: "Paragraph Doc")

    paragraphs =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {text, idx} -> %{"idx" => idx, "text" => text} end)

    insert_rhwp_snapshot!(doc_id, 1, %{
      "title" => "Paragraph Doc",
      "contract_type" => "nda_v1",
      "positional_index" => %{
        "paragraphs" =>
          paragraphs
          |> Enum.map(fn paragraph ->
            %{
              "sec" => 0,
              "page" => 0,
              "para" => paragraph["idx"],
              "off_start" => 0,
              "off_end" => String.length(paragraph["text"])
            }
          end),
        "tables" => []
      },
      "sections" => [%{"idx" => 0, "paragraphs" => paragraphs}],
      "fields" => []
    })

    doc_id
  end

  defp insert_rhwp_snapshot!(doc_id, revision, ir) do
    {:ok, snapshot} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: revision,
        r2_key: "documents/#{doc_id}/snapshots/#{revision}.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/#{revision}.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: ir
      })
      |> Repo.insert(
        on_conflict: {:replace, [:projection, :r2_key, :ir_r2_key, :format, :content_type]},
        conflict_target: [:document_id, :revision],
        returning: true
      )

    snapshot
  end

  defp doc_mcp_route_ref(%Context{} = ctx, doc_id) do
    %RouteRef{
      document_id: doc_id,
      user_id: ctx.user.id,
      agent_run_id: live_run_id(),
      purpose: "agent_doc_mcp",
      scopes: ["agent_doc"],
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
    }
  end

  defp live_run_id do
    run_id = Ecto.UUID.generate()
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         :ok = register_run_id(run_id)
         send(parent, {:registered_run_id, run_id})

         receive do
           :stop -> :ok
         end
       end}
    )

    assert_receive {:registered_run_id, ^run_id}, 1_000
    run_id
  end

  defp start_materializing_editor!(document_id) do
    parent = self()

    pid =
      start_supervised!(%{
        id: {:mcp_materializing_editor, make_ref()},
        start:
          {Task, :start_link,
           [
             fn ->
               :ok = Materializer.register_editor(document_id)
               send(parent, {:materializing_editor_registered, self()})
               materializing_editor_loop(document_id, parent)
             end
           ]},
        restart: :temporary
      })

    assert_receive {:materializing_editor_registered, ^pid}, 1_000
    pid
  end

  defp materializing_editor_loop(document_id, parent) do
    receive do
      {:rhwp_positional_index_request, request} ->
        request_id = request.request_id || request["request_id"]
        revision = request.min_revision || request["min_revision"]
        text_events = request.text_events || request["text_events"] || []
        base_snapshot = Map.get(request, :base_snapshot) || Map.get(request, "base_snapshot")

        projection =
          case base_snapshot && (base_snapshot.revision || base_snapshot["revision"]) do
            base_revision when is_integer(base_revision) ->
              send(parent, {:materialization_base_snapshot, base_revision})

              Contract.RhwpSnapshot.Record
              |> Repo.get_by(document_id: document_id, revision: base_revision)
              |> Map.fetch!(:projection)

            _ ->
              document_id
              |> Contract.RhwpSnapshot.latest_for_document()
              |> Map.fetch!(:projection)
          end
          |> apply_materialized_text_events(text_events)

        insert_rhwp_snapshot!(document_id, revision, projection)

        :ok =
          Materializer.ack(request_id, %{
            status: :committed,
            request_id: request_id,
            document_id: document_id,
            revision: revision,
            snapshot: %{test: true}
          })

        materializing_editor_loop(document_id, parent)
    end
  end

  defp apply_materialized_text_events(projection, text_events) do
    Enum.reduce(text_events, projection, fn
      %{"kind" => "insert_paragraph", "sec" => sec, "para" => para, "off" => off}, acc
      when is_integer(sec) and is_integer(para) and is_integer(off) ->
        update_in(acc, ["sections"], fn sections ->
          Enum.map(List.wrap(sections), fn
            %{"idx" => ^sec, "paragraphs" => paragraphs} = section ->
              paragraphs =
                Enum.flat_map(List.wrap(paragraphs), fn
                  %{"idx" => ^para, "text" => paragraph_text} = paragraph
                  when is_binary(paragraph_text) ->
                    {head, tail} = String.split_at(paragraph_text, off)

                    [
                      %{paragraph | "text" => head},
                      paragraph
                      |> Map.put("idx", para + 1)
                      |> Map.put("text", tail)
                      |> Map.drop(["tables"])
                    ]

                  %{"idx" => idx} = paragraph when is_integer(idx) and idx > para ->
                    [Map.put(paragraph, "idx", idx + 1)]

                  paragraph ->
                    [paragraph]
                end)

              %{section | "paragraphs" => paragraphs}

            section ->
              section
          end)
        end)

      %{"kind" => "insert_text", "sec" => sec, "para" => para, "off" => off, "text" => text}, acc
      when is_integer(sec) and is_integer(para) and is_integer(off) and is_binary(text) ->
        update_in(acc, ["sections"], fn sections ->
          Enum.map(List.wrap(sections), fn
            %{"idx" => ^sec, "paragraphs" => paragraphs} = section ->
              paragraphs =
                Enum.map(List.wrap(paragraphs), fn
                  %{"idx" => ^para, "text" => paragraph_text} = paragraph
                  when is_binary(paragraph_text) ->
                    {head, tail} = String.split_at(paragraph_text, off)
                    %{paragraph | "text" => head <> text <> tail}

                  paragraph ->
                    paragraph
                end)

              %{section | "paragraphs" => paragraphs}

            section ->
              section
          end)
        end)

      _event, acc ->
        acc
    end)
  end

  defp register_run_id(run_id) do
    case Registry.register(Document.RunRegistry, run_id, []) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp changes_for(doc_id) do
    Repo.all(
      from c in Change, where: c.document_id == ^doc_id, order_by: [asc: c.result_revision]
    )
  end

  defp changes_for(doc_id, command_kind) do
    changes_for(doc_id) |> Enum.filter(&(&1.command_kind == command_kind))
  end

  defp deep_key?(%{} = map, key) do
    Map.has_key?(map, key) or Enum.any?(Map.values(map), &deep_key?(&1, key))
  end

  defp deep_key?(list, key) when is_list(list), do: Enum.any?(list, &deep_key?(&1, key))
  defp deep_key?(_value, _key), do: false

  defp refute_forbidden_agent_keys(payload) do
    for key <-
          ~w(raw_name server_label status title summary reason tool_name type outline index cursors) do
      refute deep_key?(payload, key), "#{key} should not be present in MCP document output"
    end
  end
end
