defmodule Contract.MCPTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.Agent.Document
  alias Contract.Agent.Run
  alias Contract.Change
  alias Contract.Command
  alias Contract.Context
  alias Contract.MCP
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Runtime

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "list_tools/2" do
    test "includes only live doc tools" do
      assert %{"tools" => tools} = MCP.list_tools(%Context{}, nil)
      names = Enum.map(tools, & &1["name"])

      assert names == ~w(doc.get doc.find doc.read doc.edit)
    end

    test "document edit tool descriptions expose doc.edit as the agent abstraction" do
      assert %{"tools" => tools} = MCP.list_tools(%Context{}, nil)

      edit = Enum.find(tools, &(&1["name"] == "doc.edit"))
      get = Enum.find(tools, &(&1["name"] == "doc.get"))
      find = Enum.find(tools, &(&1["name"] == "doc.find"))

      assert edit
      refute Enum.any?(tools, &(&1["name"] == "doc.edit_text"))
      refute Enum.any?(tools, &(&1["name"] == "doc.insert_block"))
      refute Enum.any?(tools, &(&1["name"] == "doc.delete_block"))
      refute Enum.any?(tools, &(&1["name"] == "doc.edit_table"))
      refute Enum.any?(tools, &(&1["name"] == "doc.set_field_value"))
      assert edit["description"] =~ "target.type"
      assert edit["description"] =~ "paragraph"
      assert edit["description"] =~ "cell"
      assert edit["description"] =~ "insert_block"
      assert edit["description"] =~ "delete_block"
      refute edit["description"] =~ "create table"
      refute edit["description"] =~ "rows?, cols?"
      assert edit["description"] =~ "table structure edits are not currently supported"
      assert edit["description"] =~ "line breaks are rejected"
      assert edit["description"] =~ "call `insert_block` once per paragraph"
      assert edit["description"] =~ "replace the full exact existing value or paragraph"
      assert edit["description"] =~ "not only a label prefix"
      assert edit["description"] =~ "cell_path"
      assert find["description"] =~ "table cells"
      assert find["description"] =~ "cell_path"
      refute edit["description"] =~ "doc.edit_text"
      refute edit["description"] =~ "doc.set_field_value"
      assert get["description"] =~ "bounded metadata/navigation page"
      assert get["description"] =~ "not field values"
      assert find["description"] =~ "when you already know target text"
    end
  end

  describe "list_resources/2 and read_resource/3" do
    test "resources are pruned" do
      owner = scope()
      doc_id = create_doc(owner, title: "Owner MCP Resource")

      assert %{"resources" => []} = MCP.list_resources(owner, nil)
      assert {:error, :invalid_uri} = MCP.read_resource(owner, nil, "document://#{doc_id}/state")
      assert {:error, :invalid_uri} = MCP.read_resource(owner, nil, "source_document://legacy")
      assert {:error, :invalid_uri} = MCP.read_resource(owner, nil, "evidence://legacy")
    end
  end

  describe "call_tool/4" do
    test "legacy MCP tools are unknown" do
      for tool <- [
            "document.open",
            "document.read",
            "document.search",
            "document.submit_command",
            "document.revoke_change",
            "source_document.read",
            "source_document.search_regions",
            "source_document.propose_claims",
            "source_document.confirm_claim",
            "source_document.correct_claim",
            "source_document.reject_claim",
            "source_document.link_claim_to_document",
            "law.search",
            "law.get_text",
            "law.search_precedents",
            "law.verify_citation",
            "evidence.attach_mark",
            "collab.ask_user",
            "collab.fetch_slack_context"
          ] do
        assert {:error, {:unknown_tool, ^tool}} = MCP.call_tool(%Context{}, nil, tool, %{})
      end
    end
  end

  describe "call_tool/4 — agent doc.* mutation tools" do
    setup do
      owner = scope()
      doc_id = create_doc(owner, title: "Agent Doc Tools")
      route_ref = doc_mcp_route_ref(owner, doc_id)
      {:ok, owner: owner, doc_id: doc_id, route_ref: route_ref}
    end

    test "agent_doc route_ref without an active document attempt is rejected", %{
      owner: owner,
      route_ref: route_ref
    } do
      route_ref = %{route_ref | agent_run_id: nil}

      assert {:error, {:forbidden, :run_not_active}} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})
    end

    test "stale deterministic nil-bearer route_ref is not rebound to the next active attempt",
         %{
           owner: owner,
           doc_id: doc_id,
           route_ref: route_ref
         } do
      route_ref = %{route_ref | agent_run_id: nil}

      %Run{} = old_run = start_agent_attempt(owner, doc_id)
      assert {:ok, cancelled} = Document.suspend(owner, doc_id)
      assert cancelled.id == old_run.id

      %Run{} = next_run = start_agent_attempt(owner, doc_id)

      assert {:error, {:forbidden, :run_not_active}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "op" => "insert_block",
                 "target" => %{"type" => "block", "sec" => 0, "para" => 0},
                 "block" => %{
                   "kind" => "paragraph",
                   "text" => "Late stale bearer write"
                 }
               })

      refute Enum.any?(changes_for(doc_id), &(&1.agent_run_id == next_run.id))
    end

    test "hosted doc tool bearer from the current attempt authorizes without agent_run_id args",
         %{
           owner: owner,
           doc_id: doc_id
         } do
      {run, route_ref} = start_agent_attempt_with_hosted_route_ref(owner, doc_id)

      assert {:ok, %{"ok" => true, "applied" => "edit"}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "op" => "insert_block",
                 "target" => %{"type" => "block", "sec" => 0, "para" => 0},
                 "block" => %{
                   "kind" => "paragraph",
                   "text" => "Current hosted run attribution"
                 }
               })

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
      assert change.actor_type == :agent
      assert change.agent_run_id == run.id
    end

    test "client supplied agent_run_id for another document cannot authorize a doc tool",
         %{
           owner: owner,
           doc_id: doc_id,
           route_ref: route_ref
         } do
      route_ref = %{route_ref | agent_run_id: nil}
      other_doc_id = create_doc(owner, title: "Other active document")
      %Run{} = other_run = start_agent_attempt(owner, other_doc_id)

      assert {:error, {:forbidden, :run_not_active}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "agent_run_id" => other_run.id,
                 "op" => "insert_block",
                 "target" => %{"type" => "block", "sec" => 0, "para" => 0},
                 "block" => %{
                   "kind" => "paragraph",
                   "text" => "Cross-scope run stamp"
                 }
               })

      refute Enum.any?(changes_for(doc_id), &(&1.agent_run_id == other_run.id))
    end

    test "client supplied same-scope agent_run_id does not authorize a doc tool",
         %{
           owner: owner,
           doc_id: doc_id,
           route_ref: route_ref
         } do
      route_ref = %{route_ref | agent_run_id: nil}
      %Run{} = run = start_agent_attempt(owner, doc_id)

      assert {:error, {:forbidden, :run_not_active}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "agent_run_id" => run.id,
                 "op" => "insert_block",
                 "target" => %{"type" => "block", "sec" => 0, "para" => 0},
                 "block" => %{
                   "kind" => "paragraph",
                   "text" => "Active run attribution"
                 }
               })

      refute Enum.any?(changes_for(doc_id), &(&1.agent_run_id == run.id))
    end

    test "stale route_ref run id is not attributed to a later document attempt", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      %Run{} = next_run = start_agent_attempt(owner, doc_id)
      refute route_ref.agent_run_id == next_run.id

      assert {:error, {:forbidden, :run_not_active}} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})
    end

    test "doc.edit insert_block lowers paragraph into insert_paragraph + insert_text", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{
        "op" => "insert_block",
        "target" => %{"type" => "block", "sec" => 0, "para" => 0},
        "block" => %{"kind" => "paragraph", "text" => "Hello from MCP"}
      }

      assert {:ok, %{"ok" => true, "applied" => "edit", "revision" => rev}} =
               MCP.call_tool(owner, route_ref, "doc.edit", args)

      assert is_integer(rev) and rev >= 2

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
      kinds = change.payload |> Enum.map(&Map.get(&1, "op"))
      assert "insert_paragraph" in kinds
      assert "insert_text" in kinds
    end

    test "doc.edit insert_block rejects multiline block text without committing", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      assert {:error, {:invalid_params, message}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "op" => "insert_block",
                 "target" => %{"type" => "block", "sec" => 0, "para" => 0},
                 "block" => %{
                   "kind" => "paragraph",
                   "text" => "제1조(목적)\n본문"
                 }
               })

      assert message =~ "single paragraph"
      assert message =~ "insert_block once per paragraph"
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit insert_block rejects kind=table (no rhwp create-table op yet)", %{
      owner: owner,
      route_ref: route_ref
    } do
      args = %{
        "op" => "insert_block",
        "target" => %{"type" => "block", "sec" => 0, "para" => 0},
        "block" => %{"kind" => "table", "rows" => 2, "cols" => 2}
      }

      assert {:error, {:not_supported, _}} =
               MCP.call_tool(owner, route_ref, "doc.edit", args)
    end

    test "doc.edit delete_block lowers to merge_paragraph", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{"op" => "delete_block", "target" => %{"type" => "block", "sec" => 0, "para" => 3}}

      assert {:ok, %{"ok" => true, "applied" => "edit", "revision" => rev}} =
               MCP.call_tool(owner, route_ref, "doc.edit", args)

      assert is_integer(rev)

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
      assert [%{"op" => "merge_paragraph"}] = change.payload
    end

    test "doc.edit delete_block refuses para=0 (no predecessor to merge into)", %{
      owner: owner,
      route_ref: route_ref
    } do
      assert {:error, {:invalid_params, _}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "op" => "delete_block",
                 "target" => %{"type" => "block", "sec" => 0, "para" => 0}
               })
    end

    test "doc.edit rejects table structure ops outside the current op set", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{
        "op" => "edit_table",
        "target" => %{"type" => "table", "sec" => 0, "para" => 2, "control_index" => 0},
        "table_op" => "row_insert",
        "at_row" => 1
      }

      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      assert {:error, {:invalid_params, message}} =
               MCP.call_tool(owner, route_ref, "doc.edit", args)

      assert message =~ "replace_text, insert_block, or delete_block"
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit clears a matched paragraph range with delete_text only", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_text(owner, "abc")
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"ok" => true, "applied" => "edit", "revision" => _rev}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => %{
                   "type" => "paragraph",
                   "sec" => 0,
                   "para" => 0,
                   "off" => 0,
                   "match" => "abc"
                 },
                 "text" => "",
                 "base_revision" => 1
               })

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))

      assert [
               %{
                 "op" => "delete_text",
                 "args" => %{"sec" => 0, "para" => 0, "off" => 0, "len" => 3}
               }
             ] = change.payload
    end

    test "doc.edit rejects full-document multiline replacement of one paragraph without committing",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      original = "전문서비스 계약서"
      doc_id = doc_with_text(owner, original)
      route_ref = %{route_ref | document_id: doc_id}
      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      result =
        MCP.call_tool(
          owner,
          route_ref,
          "doc.edit",
          paragraph_replace_text_args(%{
            "sec" => 0,
            "para" => 0,
            "off" => 0,
            "match" => original,
            "text" => "전문서비스 계약서\n\n본 계약은 다음과 같이 체결된다.\n\n제1조(목적)",
            "base_revision" => 1
          })
        )

      assert {:error, {:invalid_params, message}} = result
      assert message =~ "single paragraph"
      assert message =~ "insert_block once per paragraph"
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit duplicate retry returns the existing successful change after the match was deleted",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      doc_id = doc_with_text(owner, "abc")
      route_ref = %{route_ref | document_id: doc_id}

      args = %{
        "sec" => 0,
        "para" => 0,
        "off" => 0,
        "match" => "abc",
        "text" => "",
        "base_revision" => 1
      }

      args = paragraph_replace_text_args(args)

      assert {:ok, %{"revision" => rev, "change_id" => change_id, "applied" => "edit"}} =
               MCP.call_tool(owner, route_ref, "doc.edit", args)

      assert {:ok, %{"revision" => ^rev, "change_id" => ^change_id, "applied" => "edit"}} =
               MCP.call_tool(owner, route_ref, "doc.edit", args)

      assert [_change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
    end

    test "doc.edit rejects a match that is not present at the coordinates without committing",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      doc_id = doc_with_text(owner, "abc")
      route_ref = %{route_ref | document_id: doc_id}
      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      result =
        MCP.call_tool(
          owner,
          route_ref,
          "doc.edit",
          paragraph_replace_text_args(%{
            "sec" => 0,
            "para" => 0,
            "off" => 0,
            "match" => "검토본",
            "text" => "",
            "base_revision" => 1
          })
        )

      assert {:error, {:invalid_params, _}} = result
      refute match?({:ok, %{"revision" => _, "change_id" => _}}, result)
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit rejects when the target projection basis is marked incomplete",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      doc_id = doc_with_text(owner, "abc")
      route_ref = %{route_ref | document_id: doc_id}

      snap = Repo.get_by!(Contract.RhwpSnapshot.Record, document_id: doc_id, revision: 1)

      snap
      |> Ecto.Changeset.change(
        projection: Map.put(snap.projection, "basis", %{"status" => "incomplete"})
      )
      |> Repo.update!()

      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      result =
        MCP.call_tool(
          owner,
          route_ref,
          "doc.edit",
          paragraph_replace_text_args(%{
            "sec" => 0,
            "para" => 0,
            "off" => 0,
            "match" => "abc",
            "text" => "updated",
            "base_revision" => 1
          })
        )

      assert {:error, {:invalid_params, message}} = result
      assert message =~ "projection basis"
      refute match?({:ok, %{"revision" => _, "change_id" => _}}, result)
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit rejects a same-revision snapshot that is missing committed text ops",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      original = " ◇ 계약기간  :  old suffix"
      replacement = "2026.01.01부터 2026.12.31까지"
      doc_id = doc_with_text(owner, original)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"revision" => 2}} =
               MCP.call_tool(
                 owner,
                 route_ref,
                 "doc.edit",
                 paragraph_replace_text_args(%{
                   "sec" => 0,
                   "para" => 0,
                   "off" => String.length(" ◇ 계약기간  :  "),
                   "match" => "old suffix",
                   "text" => replacement,
                   "base_revision" => 1
                 })
               )

      {:ok, _stale_snapshot} =
        %Contract.RhwpSnapshot.Record{}
        |> Contract.RhwpSnapshot.Record.changeset(%{
          document_id: doc_id,
          revision: 2,
          r2_key: "documents/#{doc_id}/snapshots/2.hwp",
          ir_r2_key: "documents/#{doc_id}/snapshots/2.ir.json",
          format: "hwp",
          content_type: "application/x-hwp",
          projection: %{
            "title" => "Text Doc",
            "contract_type" => "nda_v1",
            "sections" => [
              %{
                "idx" => 0,
                "paragraphs" => [
                  %{"idx" => 0, "text" => original}
                ]
              }
            ],
            "fields" => []
          }
        })
        |> Repo.insert()

      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      result =
        MCP.call_tool(
          owner,
          route_ref,
          "doc.edit",
          paragraph_replace_text_args(%{
            "sec" => 0,
            "para" => 0,
            "off" => String.length(" ◇ 계약기간  :  "),
            "match" => "old suffix",
            "text" => "new suffix",
            "base_revision" => 2
          })
        )

      assert {:error, {:invalid_params, message}} = result
      assert message =~ "same-revision"
      refute match?({:ok, %{"revision" => _, "change_id" => _}}, result)
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit allows a paragraph edit when stale snapshot text ops touch another target",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      doc_id = doc_with_paragraphs(owner, ["target original", "other old"])
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"revision" => 2}} =
               MCP.call_tool(
                 owner,
                 route_ref,
                 "doc.edit",
                 paragraph_replace_text_args(%{
                   "sec" => 0,
                   "para" => 1,
                   "off" => 0,
                   "match" => "other old",
                   "text" => "other new",
                   "base_revision" => 1
                 })
               )

      {:ok, _stale_snapshot} =
        %Contract.RhwpSnapshot.Record{}
        |> Contract.RhwpSnapshot.Record.changeset(%{
          document_id: doc_id,
          revision: 2,
          r2_key: "documents/#{doc_id}/snapshots/2.hwp",
          ir_r2_key: "documents/#{doc_id}/snapshots/2.ir.json",
          format: "hwp",
          content_type: "application/x-hwp",
          projection: %{
            "title" => "Paragraphs Doc",
            "contract_type" => "nda_v1",
            "sections" => [
              %{
                "idx" => 0,
                "paragraphs" => [
                  %{"idx" => 0, "text" => "target original"},
                  %{"idx" => 1, "text" => "other old"}
                ]
              }
            ],
            "fields" => []
          }
        })
        |> Repo.insert()

      assert {:ok, %{"revision" => 3, "applied" => "edit"}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => %{
                   "type" => "paragraph",
                   "sec" => 0,
                   "para" => 0,
                   "off" => 0,
                   "match" => "target original"
                 },
                 "text" => "target updated",
                 "base_revision" => 2
               })

      assert List.last(changes_for(doc_id)).agent_run_id == route_ref.agent_run_id
    end

    test "doc.edit rejects slot label prefix replacement that would leave old period text",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      old_period = "2025년 3월 12일부터 2026년 4월 30일까지 LONG-OLD"
      label = " ◇ 계약기간  :  "
      doc_id = doc_with_text(owner, label <> old_period)
      route_ref = %{route_ref | document_id: doc_id}
      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      result =
        MCP.call_tool(
          owner,
          route_ref,
          "doc.edit",
          paragraph_replace_text_args(%{
            "sec" => 0,
            "para" => 0,
            "off" => 0,
            "match" => label,
            "text" => label <> "2026년 1월 1일부터 2027년 12월 31일까지 LONG-FIELD",
            "base_revision" => 1
          })
        )

      assert {:error, {:invalid_params, message}} = result
      assert message =~ "slot label prefix"
      refute match?({:ok, %{"revision" => _, "change_id" => _}}, result)
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit rejects negative paragraph coordinates without committing", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      result =
        MCP.call_tool(
          owner,
          route_ref,
          "doc.edit",
          paragraph_replace_text_args(%{
            "sec" => 0,
            "para" => -1,
            "off" => 0,
            "match" => "service_agreement_v1.hwp",
            "text" => "",
            "base_revision" => 1
          })
        )

      assert {:error, {:invalid_params, _}} = result
      refute match?({:ok, %{"revision" => _, "change_id" => _}}, result)
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit rejects empty replacements without stamping a revision", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      result =
        MCP.call_tool(
          owner,
          route_ref,
          "doc.edit",
          paragraph_replace_text_args(%{
            "sec" => 0,
            "para" => 0,
            "off" => 0,
            "len" => 0,
            "text" => "",
            "base_revision" => 1
          })
        )

      assert {:error, {:invalid_params, _}} = result
      refute match?({:ok, %{"revision" => _, "change_id" => _}}, result)
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit derives delete length from `match` so the agent never has to count graphemes",
         %{owner: owner, route_ref: route_ref} do
      # Real-world failure that drove this: an agent passed len=29 for the
      # 30-grapheme string "범용(용역[지식·정보성과물]업 분야) 표준 하도급계약서",
      # leaving the trailing `)` behind. With `match`, the server measures
      # the string itself and ignores any miscount.
      target = "범용(용역[지식·정보성과물]업 분야) 표준 하도급계약서"
      doc_id = doc_with_text(owner, target <> " 본문")
      route_ref = %{route_ref | document_id: doc_id}

      args = %{
        "sec" => 0,
        "para" => 0,
        "off" => 0,
        "match" => target,
        # Deliberately also pass a wrong `len` — `match` must win.
        "len" => 29,
        "text" => "하도급계약"
      }

      assert {:ok, %{"ok" => true, "applied" => "edit"}} =
               MCP.call_tool(owner, route_ref, "doc.edit", paragraph_replace_text_args(args))

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))

      delete_op =
        Enum.find(change.payload, fn op -> Map.get(op, "op") == "delete_text" end)

      assert delete_op, "expected a delete_text op in the payload"
      assert get_in(delete_op, ["args", "len"]) == String.length(target)
    end

    test "doc.edit accepts a numeric `len`", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{
        "sec" => 0,
        "para" => 0,
        "off" => 0,
        "len" => 4,
        "text" => "X"
      }

      assert {:ok, %{"ok" => true, "applied" => "edit"}} =
               MCP.call_tool(owner, route_ref, "doc.edit", paragraph_replace_text_args(args))

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))

      delete_op =
        Enum.find(change.payload, fn op -> Map.get(op, "op") == "delete_text" end)

      assert get_in(delete_op, ["args", "len"]) == 4
    end

    test "doc.edit rejects when neither `match` nor `len` is provided", %{
      owner: owner,
      route_ref: route_ref
    } do
      assert {:error, {:invalid_params, _}} =
               MCP.call_tool(
                 owner,
                 route_ref,
                 "doc.edit",
                 paragraph_replace_text_args(%{
                   "sec" => 0,
                   "para" => 0,
                   "off" => 0,
                   "text" => "X"
                 })
               )
    end

    test "doc.get returns slim metadata + heading outline, NOT the full paragraph list", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_clauses(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, payload} = MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert payload["ok"] == true
      assert payload["d"] == "Clauses Doc"
      assert payload["t"] == "nda_v1"

      # Counts present and accurate.
      assert is_map(payload["counts"])
      assert payload["counts"]["sec"] == 1
      assert payload["counts"]["para"] == 5

      # Outline includes the title (level 0) + 제1조 / 제2조 (level 2).
      outline = payload["outline"]
      assert is_list(outline)
      assert [0, -1, 0, "Clauses Doc"] in outline
      assert Enum.any?(outline, fn [_, _, _, t] -> String.starts_with?(t, "제1조") end)
      assert Enum.any?(outline, fn [_, _, _, t] -> String.starts_with?(t, "제2조") end)
      assert [0, 2, 2, "제1조 (목적)"] in outline
      refute Enum.any?(outline, fn [_, _, _, t] -> String.contains?(t, "본 계약") end)

      # CRITICAL: no flat paragraph list — that's what doc.read is for.
      refute Map.has_key?(payload, "p")

      # Fields surface as compact id/label/kind/read-hint tuples.
      assert is_list(payload["f"])
    end

    test "doc.get bounds outline and field hints with cursors and no field values", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_many_outline_rows_and_fields(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, payload} = MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert length(payload["outline"]) == 12
      assert length(payload["f"]) == 10
      assert payload["cursors"]["outline"] == %{"from" => 12}
      assert payload["cursors"]["fields"] == %{"from" => 10}
      assert payload["read"]["paragraph_window"]["default_limit"] == 3
      assert payload["read"]["table_window"]["default_rows"] == 2
      refute inspect(payload) =~ "FIELD-VALUE-SHOULD-NOT-DUMP"

      assert {:ok, page} =
               MCP.call_tool(owner, route_ref, "doc.get", %{
                 "outline_from" => 12,
                 "outline_limit" => 3,
                 "field_from" => 10,
                 "field_limit" => 2
               })

      assert length(page["outline"]) == 3
      assert length(page["f"]) == 2
    end

    test "doc.get falls back to typed RHWP editables before the first snapshot", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id =
        create_doc(owner,
          title: "Fresh Service Agreement",
          type_key: "service_agreement_v1"
        )

      refute Repo.get_by(Contract.RhwpSnapshot.Record, document_id: doc_id)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"counts" => counts, "f" => fields} = payload} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert counts["sec"] > 0
      assert counts["para"] > 0
      refute inspect(payload) =~ "2026년"

      assert ["service_contract_start_date", "계약기간 시작일", "text_field", %{"sec" => 0}] =
               compact_field(fields, "service_contract_start_date")

      assert ["service_contract_end_date", "계약기간 종료일", "text_field", %{"sec" => 0}] =
               compact_field(fields, "service_contract_end_date")

      assert ["contract_period", "계약기간", "text_field", %{"sec" => 0, "para" => 12}] =
               compact_field(fields, "contract_period")

      assert {:ok,
              %{
                "revision" => base_revision,
                "total" => total,
                "hits" => [[0, 12, _off, _len, _before, "계약기간", _after, "paragraph"] | _]
              }} = MCP.call_tool(owner, route_ref, "doc.find", %{"needle" => "계약기간"})

      assert total > 0

      long_period = "2026년 2월 3일부터 2027년 4월 5일까지 CHAT-LONG-MCP"

      assert {:ok, %{"read" => %{"type" => "paragraph", "text" => original_paragraph}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "para" => 12})

      assert {:ok, %{"revision" => 2}} =
               MCP.call_tool(
                 owner,
                 route_ref,
                 "doc.edit",
                 paragraph_replace_text_args(%{
                   "sec" => 0,
                   "para" => 12,
                   "off" => 0,
                   "match" => original_paragraph,
                   "text" => " ◇ 계약기간  :  " <> long_period,
                   "base_revision" => base_revision
                 })
               )

      assert {:ok, %{"read" => %{"type" => "paragraph", "text" => paragraph}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "para" => 12})

      assert paragraph =~ long_period
      assert paragraph |> occurrences("CHAT-LONG-MCP") == 1
      assert paragraph |> occurrences("까지") == 1
      refute paragraph =~ "년   월"
      refute paragraph =~ original_paragraph
    end

    test "doc.find returns positional hits with surrounding context", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_clauses(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"ok" => true, "total" => total, "hits" => hits, "revision" => _}} =
               MCP.call_tool(owner, route_ref, "doc.find", %{"needle" => "갑"})

      assert total >= 1
      assert is_list(hits)
      [first | _] = hits
      assert [_sec, _para, _off, _len, _before, "갑", _after, _kind] = first
    end

    test "doc.find respects limit", %{owner: owner, route_ref: route_ref} do
      doc_id = doc_with_clauses(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"total" => total, "hits" => hits}} =
               MCP.call_tool(owner, route_ref, "doc.find", %{"needle" => "을", "limit" => 1})

      assert length(hits) == 1
      assert total >= 1
    end

    test "doc.find returns empty hits when needle is missing", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_clauses(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"total" => 0, "hits" => []}} =
               MCP.call_tool(owner, route_ref, "doc.find", %{"needle" => "이런문구는없음"})
    end

    test "doc.find rejects when `needle` is missing", %{
      owner: owner,
      route_ref: route_ref
    } do
      assert {:error, {:invalid_params, _}} =
               MCP.call_tool(owner, route_ref, "doc.find", %{})
    end

    test "doc.read returns a paragraph preview window with section coordinates", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_clauses(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"ok" => true, "read" => %{"type" => "paragraph_window", "items" => items}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "from" => 0,
                 "to" => 1
               })

      assert length(items) == 2
      assert [%{"sec" => 0, "para" => 0, "preview" => "Clauses Doc"}, %{"para" => 1}] = items
    end

    test "doc.read with a single `para` returns a bounded paragraph read", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_clauses(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"read" => %{"type" => "paragraph", "sec" => 0, "para" => 2, "text" => text}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "para" => 2})

      assert String.starts_with?(text, "제1조")
    end

    test "doc.edit replaces table cell text using a cell target from doc.read", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_table_cell(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok,
              %{
                "revision" => base_revision,
                "read" => %{"type" => "table_window", "tables" => tables}
              }} = MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "para" => 0})

      assert [
               %{
                 "control_index" => 0,
                 "rows" => 1,
                 "cols" => 2,
                 "cells" => table_cells
               }
             ] = tables

      assert length(table_cells) == 2

      assert {:ok, %{"read" => %{"type" => "cell", "cell" => cell}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "para" => 0,
                 "row" => 0,
                 "col" => 1
               })

      assert cell["text"] == "기존 금액"
      assert cell["control_index"] == 0
      assert cell["cell_index"] == 1
      assert cell["cell_para_index"] == 0

      assert cell["target"] == %{
               "type" => "cell",
               "sec" => 0,
               "para" => 0,
               "off" => 0,
               "match" => "기존 금액",
               "cell_path" => cell["cell_path"]
             }

      assert {:ok, %{"ok" => true, "applied" => "edit", "revision" => 2}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => %{
                   "type" => "cell",
                   "sec" => 0,
                   "para" => 0,
                   "off" => 0,
                   "match" => cell["text"],
                   "cell_path" => cell["cell_path"]
                 },
                 "text" => "변경 금액",
                 "base_revision" => base_revision
               })

      assert {:ok, %{"read" => %{"type" => "cell", "cell" => updated_cell}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "para" => 0,
                 "row" => 0,
                 "col" => 1
               })

      assert updated_cell["text"] == "변경 금액"
      refute updated_cell["text"] =~ "기존"

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
      assert Enum.all?(change.payload, &(get_in(&1, ["args", "cell_path"]) == cell["cell_path"]))
    end

    test "doc.edit rejects relabeling fixed phone table cells to email contact fields", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_phone_table_cell(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"revision" => base_revision, "read" => %{"type" => "cell", "cell" => cell}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "para" => 0,
                 "row" => 0,
                 "col" => 1
               })

      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      assert {:error, {:invalid_params, message}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => %{
                   "type" => "cell",
                   "sec" => 0,
                   "para" => 0,
                   "off" => 0,
                   "match" => cell["text"],
                   "cell_path" => cell["cell_path"]
                 },
                 "text" => "담당자/이메일 : 홍길동 / lead@example.com",
                 "base_revision" => base_revision
               })

      assert message =~ "fixed phone table cell"
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit allows paragraph edits after same-revision snapshot materializes table cell edits",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      doc_id = doc_with_table_cell_and_paragraph(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"revision" => base_revision, "read" => %{"type" => "cell", "cell" => cell}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "para" => 0,
                 "row" => 0,
                 "col" => 1
               })

      assert {:ok, %{"revision" => 2}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => %{
                   "type" => "cell",
                   "sec" => 0,
                   "para" => 0,
                   "off" => 0,
                   "match" => cell["text"],
                   "cell_path" => cell["cell_path"]
                 },
                 "text" => "변경 금액",
                 "base_revision" => base_revision
               })

      {:ok, _materialized_snapshot} =
        %Contract.RhwpSnapshot.Record{}
        |> Contract.RhwpSnapshot.Record.changeset(%{
          document_id: doc_id,
          revision: 2,
          r2_key: "documents/#{doc_id}/snapshots/2.hwp",
          ir_r2_key: "documents/#{doc_id}/snapshots/2.ir.json",
          format: "hwp",
          content_type: "application/x-hwp",
          projection: %{
            "title" => "Table Cell Doc",
            "contract_type" => "nda_v1",
            "sections" => [
              %{
                "idx" => 0,
                "paragraphs" => [
                  table_paragraph("품목", "변경 금액"),
                  %{"idx" => 1, "text" => " 2. 설계도, 작성지시서, 사양서류 등"}
                ]
              }
            ],
            "fields" => []
          }
        })
        |> Repo.insert()

      assert {:ok, %{"revision" => 3}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => %{
                   "type" => "paragraph",
                   "sec" => 0,
                   "para" => 1,
                   "off" => 0,
                   "match" => " 2. 설계도, 작성지시서, 사양서류 등"
                 },
                 "text" => " 2. 과업범위서, 요구사항정의서, 개선 설계서 및 운영대행 사양서류",
                 "base_revision" => 2
               })
    end

    test "doc.find searches table cells and returns a cell target payload", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_table_cell(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"revision" => 1, "total" => 1, "hits" => [hit]}} =
               MCP.call_tool(owner, route_ref, "doc.find", %{
                 "needle" => "기존 금액",
                 "context" => 10
               })

      assert [
               0,
               0,
               0,
               5,
               "",
               "기존 금액",
               "",
               "cell",
               %{
                 "row" => 0,
                 "col" => 1,
                 "cell_path" => cell_path,
                 "target" => target
               }
             ] = hit

      assert target == %{
               "type" => "cell",
               "sec" => 0,
               "para" => 0,
               "off" => 0,
               "match" => "기존 금액",
               "cell_path" => cell_path
             }
    end

    test "doc.edit rejects paragraph targets for table host paragraphs", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_table_cell(owner)
      route_ref = %{route_ref | document_id: doc_id}
      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      assert {:error, {:invalid_params, message}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => %{
                   "type" => "paragraph",
                   "sec" => 0,
                   "para" => 0,
                   "off" => 0,
                   "len" => 0
                 },
                 "text" => "지급조건"
               })

      assert message =~ "cell target"
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.edit delete_block rejects table host paragraphs", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_table_cell(owner)
      route_ref = %{route_ref | document_id: doc_id}
      before_change_ids = changes_for(doc_id) |> Enum.map(& &1.id)

      assert {:error, {:not_supported, message}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "op" => "delete_block",
                 "target" => %{"type" => "block", "sec" => 0, "para" => 0}
               })

      assert message =~ "table paragraphs"
      assert changes_for(doc_id) |> Enum.map(& &1.id) == before_change_ids
    end

    test "doc.read paginates via next_para when limit is hit", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_clauses(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"read" => %{"items" => first_page, "next_para" => 2}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "from" => 0,
                 "limit" => 2
               })

      assert length(first_page) == 2
    end

    test "doc.read clamps the Task 223 broad range into a small cursor window without table cell dumps",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      doc_id = doc_with_period_and_payment_table(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, payload} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "from" => 10,
                 "to" => 20,
                 "limit" => 20
               })

      assert %{
               "read" => %{
                 "type" => "paragraph_window",
                 "sec" => 0,
                 "items" => items,
                 "next_para" => 13
               }
             } = payload

      assert length(items) == 3
      assert Enum.map(items, & &1["para"]) == [10, 11, 12]
      assert Enum.all?(items, &Map.has_key?(&1, "read"))

      refute inspect(payload) =~ "PERIOD-TAIL-SHOULD-NOT-DUMP"
      refute inspect(payload) =~ "PAYMENT-CELL-SHOULD-NOT-DUMP"
    end

    test "doc.read single paragraph returns a bounded text window with a continuation cursor",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      long_text = String.duplicate("계약기간 본문 ", 80) <> "PARAGRAPH-TAIL-SHOULD-NOT-DUMP"
      doc_id = doc_with_text(owner, long_text)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok,
              %{
                "read" => %{
                  "type" => "paragraph",
                  "sec" => 0,
                  "para" => 0,
                  "text" => text,
                  "range" => %{"off" => 0, "next_off" => next_off}
                }
              }} = MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "para" => 0})

      assert String.length(text) <= 400
      assert next_off == String.length(text)
      refute text =~ "PARAGRAPH-TAIL-SHOULD-NOT-DUMP"
    end

    test "doc.read table paragraph returns a row/column window, and single cell read returns edit target",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      doc_id = doc_with_big_table(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok,
              %{
                "read" => %{
                  "type" => "table_window",
                  "tables" => [
                    %{
                      "rows" => 3,
                      "cols" => 4,
                      "row_from" => 0,
                      "row_limit" => 2,
                      "col_from" => 0,
                      "col_limit" => 2,
                      "cells" => cells
                    }
                  ]
                }
              }} = MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "para" => 0})

      assert length(cells) == 4
      refute inspect(cells) =~ "R2C3-PAYMENT-CELL-SHOULD-NOT-DUMP"

      assert {:ok,
              %{
                "read" => %{
                  "type" => "table_window",
                  "tables" => [
                    %{
                      "row_limit" => 3,
                      "col_limit" => 3,
                      "cells" => broad_cells
                    }
                  ]
                }
              }} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "para" => 0,
                 "row_limit" => 5,
                 "col_limit" => 6
               })

      assert length(broad_cells) == 9
      refute inspect(broad_cells) =~ "R2C3-PAYMENT-CELL-SHOULD-NOT-DUMP"

      assert {:ok,
              %{
                "read" => %{
                  "type" => "cell",
                  "cell" => %{
                    "row" => 2,
                    "col" => 3,
                    "text" => "R2C3-PAYMENT-CELL-SHOULD-NOT-DUMP",
                    "target" => target
                  }
                }
              }} =
               MCP.call_tool(owner, route_ref, "doc.read", %{
                 "sec" => 0,
                 "para" => 0,
                 "row" => 2,
                 "col" => 3
               })

      assert target["type"] == "cell"
      assert target["sec"] == 0
      assert target["para"] == 0
      assert target["match"] == "R2C3-PAYMENT-CELL-SHOULD-NOT-DUMP"
    end

    test "doc.read rejects when `sec` is missing", %{owner: owner, route_ref: route_ref} do
      assert {:error, {:invalid_params, _}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"para" => 0})
    end

    test "doc.get + doc.read let the agent re-fetch and continue same-paragraph field edits after offsets shift",
         %{
           owner: owner,
           route_ref: route_ref
         } do
      doc_id = doc_with_same_paragraph_tracked_fields(owner)
      route_ref = %{route_ref | document_id: doc_id}

      assert {:ok, %{"revision" => base_rev}} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert {:ok, %{"read" => %{"type" => "paragraph_window", "items" => items}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "from" => 0, "to" => 1})

      assert [%{"para" => 0, "preview" => "Header"}, %{"para" => 1, "preview" => "AAA BBB"}] =
               items

      assert {:ok, %{"read" => %{"type" => "field", "field" => party_a}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"field_id" => "party-a"})

      assert %{
               "id" => "party-a",
               "label" => "party_a",
               "kind" => "text",
               "value" => "AAA",
               "target" => %{
                 "type" => "paragraph",
                 "sec" => 0,
                 "para" => 1,
                 "off" => 0,
                 "match" => "AAA"
               }
             } = party_a

      assert {:ok, %{"read" => %{"type" => "field", "field" => party_b}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"field_id" => "party-b"})

      assert %{
               "id" => "party-b",
               "label" => "party_b",
               "kind" => "text",
               "value" => "BBB",
               "target" => %{
                 "type" => "paragraph",
                 "sec" => 0,
                 "para" => 1,
                 "off" => 4,
                 "match" => "BBB"
               }
             } = party_b

      assert {:ok, %{"f" => fields} = get_payload} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert ["party-a", "party_a", "text", %{"sec" => 0, "para" => 1}] =
               compact_field(fields, "party-a")

      assert ["party-b", "party_b", "text", %{"sec" => 0, "para" => 1}] =
               compact_field(fields, "party-b")

      refute inspect(get_payload) =~ "AAA"
      refute inspect(get_payload) =~ "BBB"

      assert {:ok, %{"revision" => first_rev}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => party_a["target"],
                 "text" => "ALPHA",
                 "base_revision" => base_rev
               })

      assert {:error, {:revision_conflict, expected: ^first_rev, got: ^base_rev}} =
               MCP.call_tool(
                 owner,
                 route_ref,
                 "doc.edit",
                 paragraph_replace_text_args(%{
                   "sec" => 0,
                   "para" => 1,
                   "off" => String.length("ALPHA "),
                   "match" => "BBB",
                   "text" => "OMEGA",
                   "base_revision" => base_rev
                 })
               )

      assert {:ok, %{"revision" => ^first_rev, "f" => _fields}} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert {:ok, %{"read" => %{"type" => "paragraph", "text" => "ALPHA BBB"}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "para" => 1})

      assert {:ok, %{"read" => %{"type" => "field", "field" => party_b_after_first}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"field_id" => "party-b"})

      assert party_b_after_first["value"] == "BBB"

      assert party_b_after_first["target"] == %{
               "type" => "paragraph",
               "sec" => 0,
               "para" => 1,
               "off" => String.length("ALPHA "),
               "match" => "BBB"
             }

      assert {:ok, %{"revision" => second_rev}} =
               MCP.call_tool(owner, route_ref, "doc.edit", %{
                 "target" => party_b_after_first["target"],
                 "text" => "OMEGA",
                 "base_revision" => first_rev
               })

      assert {:ok, %{"revision" => ^second_rev, "f" => fields}} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert {:ok, %{"read" => %{"type" => "paragraph", "text" => "ALPHA OMEGA"}}} =
               MCP.call_tool(owner, route_ref, "doc.read", %{"sec" => 0, "para" => 1})

      assert is_list(fields)
    end

    test "doc.get returns metadata/read hints without exposing body IR or an R2 URL", %{
      owner: owner,
      route_ref: route_ref
    } do
      assert {:ok, %{"ok" => true, "revision" => rev} = payload} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert is_integer(rev)
      assert is_list(payload["outline"])

      refute Enum.any?(payload["outline"], fn
               [_, _, _, text] when is_binary(text) -> String.contains?(text, "①")
               _ -> false
             end)

      assert is_map(payload["counts"])
      refute Map.has_key?(payload, "ir_url")
      refute Map.has_key?(payload, "ir")
      refute Map.has_key?(payload, "sections")
      refute Map.has_key?(payload, "p")
    end

    test "doc.get returns metadata without consulting R2 presign", %{
      owner: owner,
      route_ref: route_ref
    } do
      # Stub that would fail if doc.get still tried to generate URL metadata.
      defmodule R2PresignFailStub do
        def put(_, _, _ \\ []), do: {:ok, %{key: "x", etag: "y"}}
        def get(_, _ \\ []), do: {:error, :not_found}
        def delete(_, _ \\ []), do: :ok
        def presigned_url(_, _ \\ []), do: raise("doc.get must not presign IR URLs")
      end

      original = Application.get_env(:contract, :io_drivers, [])
      Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2PresignFailStub))
      on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)

      assert {:ok, %{"ok" => true, "revision" => _rev} = payload} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert is_list(payload["outline"])
      assert is_map(payload["counts"])
      refute Map.has_key?(payload, "ir_url")
    end

    test "doc.get does not bootstrap snapshot rows just to expose optional URL metadata", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      original = Application.get_env(:contract, :io_drivers, [])

      Application.put_env(
        :contract,
        :io_drivers,
        Keyword.put(original, :r2, Contract.IO.R2Stub)
      )

      on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)

      Contract.IO.R2Stub.setup()
      Contract.IO.R2Stub.reset()

      refute Repo.get_by(Contract.Snapshot, document_id: doc_id)

      assert {:ok, %{"ok" => true} = payload} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      assert is_list(payload["outline"])
      refute Map.has_key?(payload, "ir_url")
      refute Repo.get_by(Contract.Snapshot, document_id: doc_id)
    end

    test "doc.get does not expose a presigned IR URL for an existing snapshot", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      original = Application.get_env(:contract, :io_drivers, [])

      Application.put_env(
        :contract,
        :io_drivers,
        Keyword.put(original, :r2, Contract.IO.R2Stub)
      )

      on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)

      Contract.IO.R2Stub.setup()
      Contract.IO.R2Stub.reset()

      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      ir_key = "documents/#{doc_id}/snapshots/1.ir.json"

      ir = %{
        "title" => "Agent Doc Tools",
        "contract_type" => "nda_v1",
        "sections" => [%{"idx" => 0, "paragraphs" => [%{"idx" => 0, "text" => "Body"}]}],
        "fields" => []
      }

      assert {:ok, _} = Contract.IO.R2Stub.put(hwp_key, "hwp-bytes")
      assert {:ok, _} = Contract.IO.R2Stub.put(ir_key, Jason.encode!(ir))

      {:ok, _} =
        %Contract.RhwpSnapshot.Record{}
        |> Contract.RhwpSnapshot.Record.changeset(%{
          document_id: doc_id,
          revision: 1,
          r2_key: hwp_key,
          ir_r2_key: ir_key,
          format: "hwp",
          content_type: "application/x-hwp",
          projection: ir
        })
        |> Repo.insert()

      assert {:ok, %{"outline" => outline, "counts" => counts} = payload} =
               MCP.call_tool(owner, route_ref, "doc.get", %{})

      refute Map.has_key?(payload, "ir_url")
      assert is_list(outline)
      assert counts["para"] == 1
    end

    test "doc.get short-circuits when since_revision >= revision", %{
      owner: owner,
      route_ref: route_ref
    } do
      # 1) Get current revision via a normal doc.get.
      {:ok, %{"revision" => rev}} = MCP.call_tool(owner, route_ref, "doc.get", %{})

      # 2) Re-call with since_revision = rev — server must report
      # unchanged without rebuilding metadata/read hints.
      assert {:ok, %{"ok" => true, "unchanged" => true, "revision" => ^rev}} =
               MCP.call_tool(owner, route_ref, "doc.get", %{"since_revision" => rev})
    end

    test "legacy private mutation tool names are rejected by direct MCP.call_tool", %{
      owner: owner,
      route_ref: route_ref
    } do
      for tool <-
            ~w(doc.edit_text doc.insert_block doc.delete_block doc.edit_table doc.set_field_value) do
        assert {:error, {:unknown_tool, ^tool}} = MCP.call_tool(owner, route_ref, tool, %{})
      end
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
    type_key = Keyword.get(opts, :type_key, "nda_v1")

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => title, "type_key" => type_key}
    }

    assert {:ok, %Change{}} = Runtime.apply(ctx, action)
    doc_id
  end

  # A doc whose snapshot has a title row, an opening blurb, and two clauses
  # (제1조 / 제2조) with body text — exercises the find/read/outline trio.
  defp doc_with_clauses(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Clauses Doc")

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Clauses Doc",
          "contract_type" => "nda_v1",
          "sections" => [
            %{
              "idx" => 0,
              "paragraphs" => [
                %{"idx" => 0, "text" => "Clauses Doc"},
                %{"idx" => 1, "text" => "갑과 을이 다음과 같이 합의한다."},
                %{"idx" => 2, "text" => "제1조 (목적) 본 계약은 갑의 업무를 정한다."},
                %{"idx" => 3, "text" => "갑은 을에게 정해진 비용을 지급한다."},
                %{"idx" => 4, "text" => "제2조 (기간) 본 계약의 유효 기간은 1년으로 한다."}
              ]
            }
          ],
          "fields" => []
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_with_text(%Context{} = ctx, text) do
    doc_id = create_doc(ctx, title: "Text Doc")

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Text Doc",
          "contract_type" => "nda_v1",
          "sections" => [
            %{
              "idx" => 0,
              "paragraphs" => [
                %{"idx" => 0, "text" => text}
              ]
            }
          ],
          "fields" => []
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_with_paragraphs(%Context{} = ctx, texts) when is_list(texts) do
    doc_id = create_doc(ctx, title: "Paragraphs Doc")

    paragraphs =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {text, idx} -> %{"idx" => idx, "text" => text} end)

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Paragraphs Doc",
          "contract_type" => "nda_v1",
          "sections" => [
            %{
              "idx" => 0,
              "paragraphs" => paragraphs
            }
          ],
          "fields" => []
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_with_many_outline_rows_and_fields(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Bounded Metadata Doc")

    paragraphs =
      for idx <- 0..18 do
        %{"idx" => idx, "text" => "제#{idx + 1}조 (항목 #{idx + 1}) 본문은 metadata에 없어야 한다."}
      end

    fields =
      for idx <- 0..13 do
        %{
          "id" => "field-#{idx}",
          "label" => "필드 #{idx}",
          "kind" => "text",
          "position" => %{
            "sec" => 0,
            "para" => idx,
            "off_start" => 0,
            "off_end" => 4
          },
          "value" => "FIELD-VALUE-SHOULD-NOT-DUMP-#{idx}"
        }
      end

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Bounded Metadata Doc",
          "contract_type" => "nda_v1",
          "sections" => [%{"idx" => 0, "paragraphs" => paragraphs}],
          "fields" => fields
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_with_table_cell(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Table Cell Doc")

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Table Cell Doc",
          "contract_type" => "nda_v1",
          "sections" => [
            %{
              "idx" => 0,
              "paragraphs" => [
                %{
                  "idx" => 0,
                  "kind" => "table",
                  "text" => "",
                  "tables" => [
                    %{
                      "control_idx" => 0,
                      "rows" => 1,
                      "cols" => 2,
                      "cells" => [
                        %{
                          "row" => 0,
                          "col" => 0,
                          "cell_idx" => 0,
                          "paragraphs" => [%{"idx" => 0, "text" => "품목"}]
                        },
                        %{
                          "row" => 0,
                          "col" => 1,
                          "cell_idx" => 1,
                          "paragraphs" => [%{"idx" => 0, "text" => "기존 금액"}]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ],
          "fields" => []
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_with_phone_table_cell(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Phone Table Cell Doc")

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Phone Table Cell Doc",
          "contract_type" => "nda_v1",
          "sections" => [
            %{
              "idx" => 0,
              "paragraphs" => [
                table_paragraph("상호", "전화번호 :")
              ]
            }
          ],
          "fields" => []
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_with_table_cell_and_paragraph(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Table Cell Doc")

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Table Cell Doc",
          "contract_type" => "nda_v1",
          "sections" => [
            %{
              "idx" => 0,
              "paragraphs" => [
                table_paragraph("품목", "기존 금액"),
                %{"idx" => 1, "text" => " 2. 설계도, 작성지시서, 사양서류 등"}
              ]
            }
          ],
          "fields" => []
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_with_period_and_payment_table(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Task 223 Broad Read Doc")

    paragraphs =
      Enum.map(0..20, fn idx ->
        cond do
          idx == 10 ->
            %{
              "idx" => idx,
              "text" =>
                "계약기간은 2026년 1월 1일부터 2026년 12월 31일까지로 한다. " <>
                  String.duplicate("범위본문 ", 80) <> "PERIOD-TAIL-SHOULD-NOT-DUMP"
            }

          idx == 12 ->
            big_table_paragraph(idx)

          true ->
            %{"idx" => idx, "text" => "일반 조항 #{idx}"}
        end
      end)

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 61,
        r2_key: "documents/#{doc_id}/snapshots/61.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/61.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Task 223 Broad Read Doc",
          "contract_type" => "nda_v1",
          "sections" => [%{"idx" => 0, "paragraphs" => paragraphs}],
          "fields" => []
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_with_big_table(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Big Table Doc")

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Big Table Doc",
          "contract_type" => "nda_v1",
          "sections" => [%{"idx" => 0, "paragraphs" => [big_table_paragraph(0)]}],
          "fields" => []
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp big_table_paragraph(idx) do
    cells =
      for row <- 0..2, col <- 0..3 do
        text =
          if row == 2 and col == 3 do
            "R2C3-PAYMENT-CELL-SHOULD-NOT-DUMP"
          else
            "R#{row}C#{col}"
          end

        %{
          "row" => row,
          "col" => col,
          "cell_idx" => row * 4 + col,
          "paragraphs" => [%{"idx" => 0, "text" => text}]
        }
      end

    %{
      "idx" => idx,
      "kind" => "table",
      "text" => "",
      "tables" => [
        %{
          "control_idx" => 0,
          "rows" => 3,
          "cols" => 4,
          "cells" => cells
        }
      ]
    }
  end

  defp table_paragraph(left_text, right_text) do
    %{
      "idx" => 0,
      "kind" => "table",
      "text" => "",
      "tables" => [
        %{
          "control_idx" => 0,
          "rows" => 1,
          "cols" => 2,
          "cells" => [
            %{
              "row" => 0,
              "col" => 0,
              "cell_idx" => 0,
              "paragraphs" => [%{"idx" => 0, "text" => left_text}]
            },
            %{
              "row" => 0,
              "col" => 1,
              "cell_idx" => 1,
              "paragraphs" => [%{"idx" => 0, "text" => right_text}]
            }
          ]
        }
      ]
    }
  end

  defp doc_with_same_paragraph_tracked_fields(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Same Paragraph Field Doc")

    {:ok, _} =
      %Contract.RhwpSnapshot.Record{}
      |> Contract.RhwpSnapshot.Record.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwp",
        ir_r2_key: "documents/#{doc_id}/snapshots/1.ir.json",
        format: "hwp",
        content_type: "application/x-hwp",
        projection: %{
          "title" => "Same Paragraph Field Doc",
          "contract_type" => "nda_v1",
          "sections" => [
            %{
              "idx" => 0,
              "paragraphs" => [
                %{"idx" => 0, "text" => "Header"},
                %{"idx" => 1, "text" => "AAA BBB"}
              ]
            }
          ],
          "fields" => [
            %{
              "id" => "party-a",
              "label" => "party_a",
              "kind" => "text",
              "position" => %{
                "sec" => 0,
                "para" => 1,
                "off_start" => 0,
                "off_end" => 3
              },
              "value" => "AAA"
            },
            %{
              "id" => "party-b",
              "label" => "party_b",
              "kind" => "text",
              "position" => %{
                "sec" => 0,
                "para" => 1,
                "off_start" => 4,
                "off_end" => 7
              },
              "value" => "BBB"
            }
          ]
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp compact_field(fields, id) do
    Enum.find(fields, fn
      [^id | _] -> true
      _ -> false
    end)
  end

  defp paragraph_replace_text_args(args) do
    target =
      %{
        "type" => "paragraph",
        "sec" => Map.get(args, "sec"),
        "para" => Map.get(args, "para"),
        "off" => Map.get(args, "off")
      }
      |> maybe_put_from(args, "match")
      |> maybe_put_from(args, "len")

    %{"target" => target, "text" => Map.get(args, "text") || ""}
    |> maybe_put_from(args, "base_revision")
  end

  defp maybe_put_from(map, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(map, key, value)
      :error -> map
    end
  end

  defp occurrences(text, needle) do
    text
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  defp doc_mcp_route_ref(%Context{} = ctx, doc_id) do
    run_id = live_run_id()

    %RouteRef{
      document_id: doc_id,
      user_id: ctx.user.id,
      agent_run_id: run_id,
      purpose: "agent_doc_mcp",
      scopes: ["agent_doc"],
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
    }
  end

  defp live_run_id do
    run_id = Ecto.UUID.generate()
    parent = self()

    _pid =
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

  defp register_run_id(run_id) do
    case Registry.register(Contract.Agent.Document.RunRegistry, run_id, []) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp start_agent_attempt(%Context{} = ctx, doc_id) do
    parent = self()

    Contract.IO.OpenAIMock
    |> expect(:stream_chat, fn _params, _opts ->
      {:ok, %{stream: blocking_stream(parent), task_pid: self()}}
    end)

    action = %Command{
      kind: :chat_message,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      message: "Hold this run open",
      payload: %{"test_pid" => self()}
    }

    assert {:ok, %Run{} = run} = Document.start(ctx, action)
    assert_receive {:agent_stream_started, _stream_pid}, 2_000

    on_exit(fn ->
      _ = Document.suspend(ctx, doc_id)
    end)

    run
  end

  defp start_agent_attempt_with_hosted_route_ref(%Context{} = ctx, doc_id) do
    parent = self()

    Contract.IO.OpenAIMock
    |> expect(:stream_chat, fn params, _opts ->
      send(parent, {:openai_params, params})
      {:ok, %{stream: blocking_stream(parent), task_pid: self()}}
    end)

    action = %Command{
      kind: :chat_message,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      message: "Use the hosted document tool",
      payload: %{"test_pid" => self()}
    }

    assert {:ok, %Run{} = run} = Document.start(ctx, action)
    assert_receive {:openai_params, %{tools: tools}}, 2_000
    assert_receive {:agent_stream_started, _stream_pid}, 2_000

    on_exit(fn ->
      _ = Document.suspend(ctx, doc_id)
    end)

    bearer =
      tools
      |> Enum.find(&(Map.get(&1, :server_label) == "contract-doc"))
      |> get_in([:headers, "Authorization"])
      |> String.replace_prefix("Bearer ", "")

    assert {:ok, %RouteRef{} = route_ref} = Contract.Gateway.verify_route_ref(ctx, bearer)

    {run, route_ref}
  end

  defp blocking_stream(parent) do
    Stream.resource(
      fn -> :waiting end,
      fn
        :waiting ->
          send(parent, {:agent_stream_started, self()})

          receive do
            :release_stream -> {[], :done}
          after
            5_000 -> {[], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp changes_for(doc_id) do
    import Ecto.Query

    Repo.all(
      from c in Change, where: c.document_id == ^doc_id, order_by: [asc: c.result_revision]
    )
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
end
