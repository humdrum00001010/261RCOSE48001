defmodule Ecrits.Doc.ProjectionTest do
  @moduledoc """
  Unit tests for `Ecrits.Doc.Projection` — the exfuse doc-VFS DocLang projection.

  The pure surface (supported?/projected_name/source_basename/supported_exts) is
  toolchain-free. The end-to-end `project_file/2` + `fingerprint/1` tests run
  against the REAL doc layer through a private server registry and the ehwp NIF;
  they self-skip green when the NIF is unavailable, so the default suite stays
  free of native deps.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Projection
  alias Ecrits.Document
  alias Ecrits.Fuse.{DocFs, OpenDocs}

  describe "supported?/1" do
    test "true for every supported extension, case-insensitive" do
      for ext <- ~w(.hwp .hwpx .docx .pptx .xlsx) do
        assert Projection.supported?("report" <> ext)
        assert Projection.supported?("REPORT" <> String.upcase(ext))
      end
    end

    test "false for unsupported extensions and non-binaries" do
      refute Projection.supported?("notes.txt")
      refute Projection.supported?("archive.zip")
      refute Projection.supported?("no_extension")
      refute Projection.supported?(nil)
      refute Projection.supported?(123)
    end

    test "matches the published supported_exts list" do
      assert Projection.supported_exts() == ~w(.hwp .hwpx .docx .pptx .xlsx)
    end
  end

  describe "projected_name/1 and source_basename/1 round-trip" do
    test "projected_name appends .doclang.xml" do
      assert Projection.projected_suffix() == ".doclang.xml"
      assert Projection.projected_name("report.hwp") == "report.hwp.doclang.xml"
      assert Projection.projected_name("a/b/c.pptx") == "a/b/c.pptx.doclang.xml"
    end

    test "source_basename strips a trailing .doclang.xml" do
      assert Projection.source_basename("report.hwp.doclang.xml") == "report.hwp"
      assert Projection.source_basename("workbook.xlsx.doclang.xml") == "workbook.xlsx"
    end

    test "source_basename returns nil without a .doclang.xml suffix" do
      assert Projection.source_basename("notes.txt") == nil
      assert Projection.source_basename("report.hwp") == nil
      assert Projection.source_basename("report.hwp.md") == nil
      assert Projection.source_basename("report.hwp.xml") == nil
      assert Projection.source_basename("report.hwp.jsonl") == nil
      assert Projection.source_basename(nil) == nil
    end

    test "the two are inverse for supported names" do
      for ext <- Projection.supported_exts() do
        name = "doc" <> ext
        assert name |> Projection.projected_name() |> Projection.source_basename() == name
      end
    end
  end

  describe "project_file/2 error handling (no NIF required)" do
    test "unsupported extension is a clean error, never a raise" do
      assert {:error, {:unsupported, ".txt"}} =
               Projection.project_file("/tmp/whatever.txt")
    end

    test "non-binary path is rejected" do
      assert {:error, :invalid_path} = Projection.project_file(:not_a_path)
    end

    test "fingerprint propagates the same error" do
      assert {:error, {:unsupported, ".txt"}} = Projection.fingerprint("/tmp/whatever.txt")
      assert {:error, :invalid_path} = Projection.fingerprint(:not_a_path)
    end
  end

  describe "VFS edit highlight ranges" do
    test "browser playback follows document order instead of ehwp writeback order" do
      changes = [
        {:text,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 20, "offset" => 4},
           "text" => "뒤"
         }, "뒤"},
        {:text,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 11, "offset" => 2},
           "text" => "앞쪽"
         }, "앞쪽"}
      ]

      groups = Projection.__browser_preview_groups_for_test__(changes)

      assert Enum.map(groups, fn [{:text, op, _marker}] ->
               {op["ref"]["paragraph"], op["ref"]["offset"], op["text"]}
             end) == [
               {11, 2, "앞쪽"},
               {20, 4, "뒤"}
             ]
    end

    test "persisted highlight selection follows document order instead of ehwp writeback order" do
      changes = [
        {:text,
         %{
           "op" => "insert_text",
           "ref" => %{
             "section" => 0,
             "paragraph" => 860,
             "offset" => 0,
             "cell" => %{
               "parentParaIndex" => 860,
               "controlIndex" => 0,
               "cellIndex" => 3,
               "cellParaIndex" => 0
             }
           },
           "text" => "뒤쪽"
         }, "뒤쪽"},
        {:text,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 14, "offset" => 2},
           "text" => "앞쪽"
         }, "앞쪽"}
      ]

      highlights = Projection.__highlights_for_changes_for_test__(changes, [%{}, %{}])

      assert Enum.map(highlights, fn highlight ->
               ref = highlight["ref"]
               cell = ref["cell"]
               if is_map(cell), do: cell["parentParaIndex"], else: ref["paragraph"]
             end) == [14, 860]
    end

    test "browser property sets translate IR paragraph kind to the editor vocabulary" do
      ref = %{"section" => 0, "paragraph" => 73}
      change = {:set, ref, "paragraph", %{"alignment" => "justify"}}

      assert [
               %{
                 "ref" => ^ref,
                 "props" => %{"kind" => "para", "alignment" => "justify"}
               }
             ] = Projection.__browser_sets_for_test__([change])
    end

    test "replace_text highlights only the changed replacement span" do
      title = "범용(용역[지식ㆍ정보성과물]업 분야) 표준하도급계약서 "
      marker = "CHATRAIL_FSKIT_HWP_OK"

      op = %{
        "op" => "replace_text",
        "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
        "query" => title,
        "replacement" => title <> marker
      }

      assert %{
               "kind" => "text",
               "op" => "replace_text",
               "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
               "offset" => offset,
               "length" => length,
               "text" => ^marker
             } = Projection.__text_highlight_for_test__(op, title <> marker)

      assert offset == String.length(title)
      assert length == String.length(marker)
    end

    # 2026-07-19 field feedback ("highlight only changes not a whole para"):
    # a whole-paragraph rewrite arrives as delete_range + insert_text whose
    # insert carries the ENTIRE new text; the collapsed pair highlight must
    # narrow to the range that differs from the deleted old text.
    test "a delete+insert replacement pair highlights only the changed span" do
      old = "◇ 화학업종 관련 제조위탁명  : ecrits"
      new = "◇ 화학업종 관련 제조위탁명 (test)  : ecrits"

      insert = %{
        "op" => "insert_text",
        "ref" => %{"section" => 0, "paragraph" => 11, "offset" => 0},
        "text" => new
      }

      assert %{
               "kind" => "text",
               "offset" => offset,
               "length" => length,
               "text" => changed
             } = Projection.__replacement_pair_highlight_for_test__(insert, new, old)

      assert changed =~ "(test)"
      refute changed =~ "화학업종"
      assert offset == String.length("◇ 화학업종 관련 제조위탁명 ")
      assert length == String.length(changed)
      assert length < String.length(new)
    end

    test "set_cell highlights the new cell text" do
      ref = %{
        "section" => 0,
        "paragraph" => 16,
        "offset" => 0,
        "cell" => %{
          "parentParaIndex" => 16,
          "controlIndex" => 0,
          "cellIndex" => 1,
          "cellParaIndex" => 0
        }
      }

      op = %{"op" => "set_cell", "ref" => ref, "text" => "성과물"}

      assert %{
               "kind" => "text",
               "op" => "set_cell",
               "ref" => ^ref,
               "offset" => 0,
               "length" => 3,
               "text" => "성과물"
             } = Projection.__text_highlight_for_test__(op, "성과물")
    end

    test "inserted paragraph highlights use the applied body paragraphs, not the stale cell anchor" do
      stale_anchor = %{
        "section" => 0,
        "paragraph" => 17,
        "offset" => 4,
        "cell" => %{
          "parentParaIndex" => 17,
          "controlIndex" => 0,
          "cellIndex" => 22,
          "cellParaIndex" => 0
        }
      }

      text = "Sonnet 18\nShall I compare thee to a summer's day?"

      changes = [
        {:text, %{"op" => "insert_paragraph", "ref" => stale_anchor, "text" => text}, text}
      ]

      applied = [%{"inserted" => String.length(text), "paragraph" => 17, "ref" => stale_anchor}]

      assert [heading, first_line] =
               Projection.__highlights_for_changes_for_test__(changes, applied)

      assert heading == %{
               "kind" => "text",
               "op" => "insert_paragraph",
               "ref" => %{"section" => 0, "paragraph" => 17, "offset" => 0},
               "offset" => 0,
               "length" => 9,
               "text" => "Sonnet 18"
             }

      assert first_line["ref"] == %{"section" => 0, "paragraph" => 18, "offset" => 0}
      assert first_line["length"] == 39
      refute Map.has_key?(first_line["ref"], "cell")
    end

    test "persisted highlights follow paragraphs shifted by structural inserts" do
      table_ref = %{"section" => 0, "paragraph" => 16}
      picture_ref = %{"section" => 0, "paragraph" => 75}

      changes = [
        {:insert_table, %{"op" => "insert_table", "ref" => table_ref}, "단계"},
        {:text,
         %{
           "op" => "insert_paragraph",
           "ref" => table_ref,
           "text" => "업무 1\n업무 2\n업무 3"
         }, "업무 1\n업무 2\n업무 3"},
        {:insert_picture, %{"op" => "insert_picture", "ref" => picture_ref}, "brand", %{}}
      ]

      cell_ref = %{
        "section" => 0,
        "paragraph" => 76,
        "cell" => %{"parentParaIndex" => 76, "controlIndex" => 0, "cellIndex" => 2}
      }

      highlights = [
        %{"op" => "insert_text", "ref" => %{"section" => 0, "paragraph" => 630}},
        %{"op" => "insert_text", "ref" => %{"section" => 0, "paragraph" => 74}},
        %{"op" => "set_cell", "ref" => cell_ref},
        %{"op" => "insert_table", "ref" => %{"section" => 0, "paragraph" => 17}},
        %{"op" => "insert_paragraph", "ref" => %{"section" => 0, "paragraph" => 17}},
        %{"op" => "insert_picture", "ref" => picture_ref}
      ]

      assert [jurisdiction, date, signature, table, inserted_paragraph, picture] =
               Projection.__remap_persisted_highlights_for_test__(highlights, changes)

      assert jurisdiction["ref"]["paragraph"] == 637
      assert date["ref"]["paragraph"] == 81
      assert signature["ref"]["paragraph"] == 83
      assert signature["ref"]["cell"]["parentParaIndex"] == 83
      assert table["ref"]["paragraph"] == 20
      assert inserted_paragraph["ref"]["paragraph"] == 17
      assert picture["ref"] == picture_ref
    end

    test "persisted highlights count the native table paragraph bundle" do
      changes = [
        {:insert_table, %{"op" => "insert_table", "ref" => %{"section" => 0, "paragraph" => 630}},
         "단계"},
        {:text,
         %{
           "op" => "insert_paragraph",
           "ref" => %{"section" => 0, "paragraph" => 630},
           "text" => "업무 1\n업무 2\n업무 3"
         }, "업무 1\n업무 2\n업무 3"}
      ]

      highlights = [
        %{
          "op" => "replace_text",
          "ref" => %{
            "section" => 0,
            "paragraph" => 697,
            "cell" => %{
              "parentParaIndex" => 697,
              "controlIndex" => 0,
              "cellIndex" => 2,
              "cellParaIndex" => 0
            }
          }
        }
      ]

      assert [highlight] =
               Projection.__remap_persisted_highlights_for_test__(highlights, changes)

      assert highlight["ref"]["paragraph"] == 703
      assert highlight["ref"]["cell"]["parentParaIndex"] == 703
    end

    test "persisted highlight remapping applies later insertion coordinates sequentially" do
      changes = [
        {:insert_picture,
         %{"op" => "insert_picture", "ref" => %{"section" => 0, "paragraph" => 859}}, "brand",
         %{}},
        {:insert_table, %{"op" => "insert_table", "ref" => %{"section" => 0, "paragraph" => 16}},
         "단계"}
      ]

      highlights = [
        %{
          "op" => "insert_text",
          "ref" => %{"section" => 0, "paragraph" => 858},
          "offset" => 0,
          "length" => 12,
          "text" => "2026년 7월 15일"
        }
      ]

      assert [%{"ref" => %{"paragraph" => 862}}] =
               Projection.__remap_persisted_highlights_for_test__(highlights, changes)
    end
  end

  describe "browser-authority write transaction" do
    @tag :edit_failure
    test "commit timeout restores the exact source and rolls the browser back without publishing" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_rollback_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      source_preimage = <<0, 1, 2, 3, 255, 254, 253, 10, 0>>
      browser_export = <<9, 8, 7, 6, 5, 4, 3, 2, 1>>
      mounted_name = Path.basename(path)
      edit_id = "browser-commit-timeout"

      File.mkdir_p!(root)
      File.write!(path, source_preimage)

      on_exit(fn ->
        OpenDocs.unstage(root, mounted_name)
        OpenDocs.uncache_committed(root, mounted_name)
        File.rm_rf(root)
      end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      owner = self()

      viewer =
        start_supervised!(
          {Task,
           fn ->
             browser_transaction_loop(
               owner,
               path,
               browser_export,
               :timeout
             )
           end}
        )

      changes = [
        {:text,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
           "text" => "edited"
         }, "edited"}
      ]

      assert {:error, {:browser_timeout, "viewer did not reply in time"}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 changes,
                 root: root,
                 edit_id: edit_id,
                 browser_commit_timeout: 20
               )

      assert_receive {:browser_transaction, :vfs_write, ^edit_id, ^source_preimage}
      assert_receive {:browser_transaction, :vfs_commit, ^edit_id, ^browser_export}
      assert_receive {:browser_transaction, :vfs_rollback, ^edit_id, ^source_preimage}

      assert File.read!(path) == source_preimage
      assert :error = OpenDocs.staged(root, mounted_name)
      assert :error = OpenDocs.committed(root, mounted_name)
      refute_receive {:vfs_doc_edited, _info}
    end

    test "coordinator survives request-owner death after source replace and completes browser commit" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_owner_death_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      source_preimage = <<0, 1, 2, 3>>
      browser_export = <<9, 8, 7, 6>>
      edit_id = "browser-owner-death-gap"
      File.mkdir_p!(root)
      File.write!(path, source_preimage)

      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      owner = self()

      viewer =
        start_test_task(fn ->
          browser_transaction_loop(
            owner,
            path,
            browser_export,
            {:ok, %{"committed" => true}}
          )
        end)

      checkpoint = fn
        :source_written ->
          send(owner, {:browser_source_written, self()})

          receive do
            :continue_browser_commit -> :ok
          end
      end

      request_owner =
        start_test_task(fn ->
          result =
            Projection.__apply_browser_changes_for_test__(
              viewer,
              path,
              :hwp,
              browser_text_change("survives"),
              root: root,
              edit_id: edit_id,
              browser_transaction_checkpoint_fun: checkpoint
            )

          send(owner, {:request_owner_result, result})
        end)

      assert_receive {:browser_transaction, :vfs_write, ^edit_id, ^source_preimage}
      assert_receive {:browser_transaction_owner, :vfs_write, ^edit_id, write_owner}
      assert_receive {:browser_source_written, coordinator}
      assert coordinator != request_owner
      assert coordinator == write_owner
      assert {:ok, ^browser_export} = Exfuse.Fs.Real.read_native(path)

      request_owner_ref = Process.monitor(request_owner)
      Process.exit(request_owner, :kill)

      assert_receive {:DOWN, ^request_owner_ref, :process, ^request_owner, :killed}
      refute_receive {:browser_transaction, :vfs_commit, ^edit_id, _bytes}
      refute_receive {:browser_transaction, :vfs_rollback, ^edit_id, _bytes}

      coordinator_ref = Process.monitor(coordinator)
      send(coordinator, :continue_browser_commit)

      assert_receive {:browser_transaction, :vfs_commit, ^edit_id, ^browser_export}
      assert_receive {:browser_transaction_owner, :vfs_commit, ^edit_id, ^coordinator}
      assert_receive {:vfs_doc_edited, %{edit_id: ^edit_id, browser_authority: true}}, 1_000
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}

      assert {:ok, ^browser_export} = Exfuse.Fs.Real.read_native(path)
      refute_receive {:browser_transaction, :vfs_rollback, ^edit_id, _bytes}
      refute_receive {:request_owner_result, _result}
    end

    @tag :edit_failure
    test "invalidated and aborted commit fences roll browser playback back before source commit" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_cancel_fence_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      source_preimage = <<0, 1, 2, 3>>
      browser_export = <<9, 8, 7, 6>>
      edit_id = "browser-cancel-fence"
      File.mkdir_p!(root)
      File.write!(path, source_preimage)
      on_exit(fn -> File.rm_rf(root) end)

      owner = self()

      viewer =
        start_test_task(fn ->
          browser_transaction_loop(owner, path, browser_export, {:ok, %{"committed" => true}})
        end)

      dead_session = spawn(fn -> :ok end)
      dead_ref = Process.monitor(dead_session)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead_session, :normal}

      assert {:error, :turn_invalidated} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("cancelled"),
                 root: root,
                 edit_id: edit_id,
                 agent_session: dead_session,
                 agent_id: "agent-a",
                 instance_id: "instance-a",
                 turn_id: "turn-a"
               )

      assert_receive {:browser_transaction, :vfs_write, ^edit_id, ^source_preimage}
      assert_receive {:browser_transaction, :vfs_rollback, ^edit_id, ^source_preimage}
      refute_receive {:browser_transaction, :vfs_commit, ^edit_id, _bytes}
      assert File.read!(path) == source_preimage
      refute_receive {:vfs_doc_edited, %{edit_id: ^edit_id}}

      aborted_edit_id = "browser-aborted-fence"

      assert {:error, {:browser_writeback_failed, :hwp, :aborted}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("aborted"),
                 root: root,
                 edit_id: aborted_edit_id,
                 turn_commit_fun: fn _identity, _commit -> :aborted end
               )

      assert_receive {:browser_transaction, :vfs_write, ^aborted_edit_id, ^source_preimage}
      assert_receive {:browser_transaction, :vfs_rollback, ^aborted_edit_id, ^source_preimage}
      refute_receive {:browser_transaction, :vfs_commit, ^aborted_edit_id, _bytes}
      assert File.read!(path) == source_preimage
    end

    test "OpenDocs agent session metadata reaches Projection commit options" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_owner_propagation_#{System.unique_integer([:positive])}"
        )

      name = "contract.hwp"
      path = Path.join(root, name)
      File.mkdir_p!(root)
      File.write!(path, <<0, 1, 2, 3>>)

      OpenDocs.open(root, name,
        source_path: path,
        agent_session: self(),
        agent_id: "agent-a",
        instance_id: "instance-a",
        turn_id: "turn-a"
      )

      on_exit(fn ->
        OpenDocs.close(root, name)
        File.rm_rf(root)
      end)

      opts = DocFs.__owner_identity_opts_for_test__(root, name, path)
      assert opts[:agent_session] == self()
      owner = self()
      viewer = start_test_task(fn -> browser_commit_loop(<<9, 8, 7, 6>>) end)

      turn_commit = fn identity, _commit ->
        send(owner, {:projection_commit_identity, identity})
        :aborted
      end

      assert {:error, {:browser_writeback_failed, :hwp, :aborted}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("propagated"),
                 opts ++
                   [
                     root: root,
                     edit_id: "owner-propagation-edit",
                     turn_commit_fun: turn_commit
                   ]
               )

      assert_receive {:projection_commit_identity,
                      %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}}
    end

    test "routed document identity is preserved across write, commit, and rollback payloads" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_document_fence_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      File.mkdir_p!(root)
      File.write!(path, <<0, 1, 2, 3>>)
      on_exit(fn -> File.rm_rf(root) end)

      owner = self()
      expected_document_id = "routed-document-id"

      viewer =
        start_test_task(fn ->
          browser_payload_loop(owner, <<9, 8, 7, 6>>, {:error, "document switched"})
        end)

      turn_commit = fn _identity, commit ->
        result = commit.()
        send(owner, {:commit_lock_returned, Exfuse.Fs.Real.read_native(path)})
        result
      end

      assert {:error, {:browser_writeback_rejected, "document switched"}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("fenced"),
                 root: root,
                 edit_id: "document-fence-edit",
                 expected_document_id: expected_document_id,
                 agent_id: "agent-a",
                 instance_id: "instance-a",
                 turn_id: "turn-a",
                 turn_commit_fun: turn_commit
               )

      for verb <- [:vfs_write, :vfs_commit, :vfs_rollback] do
        assert_receive {:browser_payload, ^verb,
                        %{
                          edit_id: "document-fence-edit",
                          expected_document_id: ^expected_document_id,
                          agent_id: "agent-a",
                          instance_id: "instance-a",
                          turn_id: "turn-a"
                        }}
      end

      assert_receive {:commit_lock_returned, {:ok, <<0, 1, 2, 3>>}}
    end

    test "postcommit returns while file_server is suspended and publishes the carried export later" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_postcommit_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      source_preimage = <<0, 1, 2, 3>>
      browser_export = <<9, 8, 7, 6, 5, 4, 3, 2, 1>>
      edit_id = "browser-postcommit-with-file-server-suspended"

      File.mkdir_p!(root)
      File.write!(path, source_preimage)

      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      viewer = start_test_task(fn -> browser_commit_loop(browser_export) end)
      owner = self()
      file_server = Process.whereis(:file_server_2)
      :ok = :sys.suspend(file_server)
      on_exit(fn -> :sys.resume(file_server) end)

      _worker =
        start_test_task(fn ->
          result =
            Projection.__apply_browser_changes_for_test__(
              viewer,
              path,
              :hwp,
              browser_text_change("edited"),
              root: root,
              edit_id: edit_id
            )

          send(owner, {:postcommit_result, result})
        end)

      assert_receive {:postcommit_result, {:ok, %{applied: 1}}}, 1_000

      assert_receive {:vfs_doc_edited,
                      %{edit_id: ^edit_id, phase: :committed, preview_snapshot: nil}},
                     1_000

      :ok = :sys.resume(file_server)

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: ^edit_id,
                        phase: :snapshot_ready,
                        preview_snapshot: %{sha256: snapshot_sha256}
                      }},
                     1_000

      assert snapshot_sha256 == Document.sha256(browser_export)
      assert File.read!(path) == browser_export
    end

    test "committed snapshots publish once each in save order when an older snapshot blocks" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_preview_order_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      File.mkdir_p!(root)
      File.write!(path, <<0>>)
      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      owner = self()
      old_bytes = <<1, 1, 1>>
      new_bytes = <<2, 2, 2>>
      old_viewer = start_test_task(fn -> browser_commit_loop(old_bytes) end)
      new_viewer = start_test_task(fn -> browser_commit_loop(new_bytes) end)

      blocking_snapshot = fn document_id, bytes ->
        send(owner, {:old_snapshot_started, self(), document_id, bytes})

        receive do
          :release_old_snapshot ->
            id = Document.sha256(bytes)
            {:ok, %{id: id, document_id: document_id, byte_size: byte_size(bytes), sha256: id}}
        end
      end

      assert {:ok, %{applied: 1}} =
               Projection.__apply_browser_changes_for_test__(
                 old_viewer,
                 path,
                 :hwp,
                 browser_text_change("old"),
                 root: root,
                 edit_id: "older-edit",
                 preview_snapshot_fun: blocking_snapshot
               )

      assert_receive {:old_snapshot_started, old_task, _document_id, ^old_bytes}

      assert_receive {:vfs_doc_edited,
                      %{edit_id: "older-edit", phase: :committed, preview_snapshot: nil}}

      immediate_snapshot = fn document_id, bytes ->
        id = Document.sha256(bytes)
        {:ok, %{id: id, document_id: document_id, byte_size: byte_size(bytes), sha256: id}}
      end

      assert {:ok, %{applied: 1}} =
               Projection.__apply_browser_changes_for_test__(
                 new_viewer,
                 path,
                 :hwp,
                 browser_text_change("new"),
                 root: root,
                 edit_id: "newer-edit",
                 preview_snapshot_fun: immediate_snapshot
               )

      assert_receive {:vfs_doc_edited,
                      %{edit_id: "newer-edit", phase: :committed, preview_snapshot: nil}}

      refute_receive {:vfs_doc_edited, %{phase: :snapshot_ready}}, 50
      send(old_task, :release_old_snapshot)

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: "older-edit",
                        phase: :snapshot_ready,
                        preview_snapshot: %{sha256: old_sha}
                      }},
                     1_000

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: "newer-edit",
                        phase: :snapshot_ready,
                        preview_snapshot: %{sha256: new_sha}
                      }},
                     1_000

      assert old_sha == Document.sha256(old_bytes)
      assert new_sha == Document.sha256(new_bytes)
      refute_receive {:vfs_doc_edited, _info}, 50
    end

    test "snapshot persistence failure still publishes the terminal edit event" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_browser_preview_error_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      File.mkdir_p!(root)
      File.write!(path, <<0>>)
      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      viewer = start_supervised!({Task, fn -> browser_commit_loop(<<3, 3, 3>>) end})

      assert {:ok, %{applied: 1}} =
               Projection.__apply_browser_changes_for_test__(
                 viewer,
                 path,
                 :hwp,
                 browser_text_change("error"),
                 root: root,
                 edit_id: "snapshot-error-edit",
                 preview_snapshot_fun: fn _document_id, _bytes -> {:error, :disk_full} end
               )

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: "snapshot-error-edit",
                        preview_snapshot_error: "disk_full"
                      }},
                     1_000
    end

    test "deferred server preview snapshots use captured post-save bytes, not a later reread" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_server_snapshot_capture_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      captured_bytes = <<1, 2, 3, 4>>
      later_bytes = <<9, 9, 9, 9>>
      File.mkdir_p!(root)
      File.write!(path, captured_bytes)
      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      owner = self()

      blocking_snapshot = fn document_id, bytes ->
        send(owner, {:server_snapshot_started, self(), document_id, bytes})

        receive do
          :release_server_snapshot ->
            id = Document.sha256(bytes)
            {:ok, %{id: id, document_id: document_id, byte_size: byte_size(bytes), sha256: id}}
        end
      end

      :ok =
        Projection.__broadcast_edit_for_test__(
          path,
          browser_text_change("server"),
          [%{}],
          root: root,
          edit_id: "server-captured-snapshot",
          preview_snapshot_bytes_result: {:ok, captured_bytes},
          preview_snapshot_fun: blocking_snapshot
        )

      assert_receive {:server_snapshot_started, snapshot_task, _document_id, ^captured_bytes}
      File.write!(path, later_bytes)
      send(snapshot_task, :release_server_snapshot)

      assert_receive {:vfs_doc_edited,
                      %{
                        edit_id: "server-captured-snapshot",
                        preview_snapshot: %{sha256: snapshot_sha}
                      }},
                     1_000

      assert snapshot_sha == Document.sha256(captured_bytes)
      assert File.read!(path) == later_bytes
    end

    test "a final preview publication token is consumed exactly once" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_preview_once_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      token = OpenDocs.begin_preview_publication(root, path, "once-edit")
      info = %{path: path, edit_id: "once-edit"}

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      assert :ok = OpenDocs.publish_preview_if_current(root, path, token, info)
      assert :stale = OpenDocs.publish_preview_if_current(root, path, token, info)
      assert_receive {:vfs_doc_edited, ^info}
      refute_receive {:vfs_doc_edited, ^info}, 50
    end

    test "committed edit facts publish before their durable snapshot is ready" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_committed_fact_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      committed_bytes = <<4, 5, 6, 7>>
      revision = Document.sha256("complete accepted projection")
      owner = self()

      File.mkdir_p!(root)
      File.write!(path, committed_bytes)
      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      blocking_snapshot = fn document_id, bytes ->
        send(owner, {:lifecycle_snapshot_started, self(), document_id, bytes})

        receive do
          :release_lifecycle_snapshot ->
            id = Document.sha256(bytes)
            {:ok, %{id: id, document_id: document_id, byte_size: byte_size(bytes), sha256: id}}
        end
      end

      :ok =
        Projection.__broadcast_edit_for_test__(
          path,
          browser_text_change("committed"),
          [%{}],
          root: root,
          edit_id: "committed-edit",
          phase: :committed,
          revision: revision,
          turn_id: "turn-a",
          agent_id: "agent-a",
          instance_id: "instance-a",
          preview_snapshot_bytes_result: {:ok, committed_bytes},
          preview_snapshot_fun: blocking_snapshot
        )

      assert_receive {:vfs_doc_edited,
                      %{
                        phase: :committed,
                        edit_id: "committed-edit",
                        revision: ^revision,
                        preview_snapshot: nil,
                        preview_snapshot_error: nil
                      } = committed}

      assert committed.document_id == Document.id_for(root, "contract.hwp")
      assert_receive {:lifecycle_snapshot_started, snapshot_task, _document_id, ^committed_bytes}
      refute_receive {:vfs_doc_edited, %{phase: :snapshot_ready}}, 20

      send(snapshot_task, :release_lifecycle_snapshot)

      assert_receive {:vfs_doc_edited,
                      %{
                        phase: :snapshot_ready,
                        edit_id: "committed-edit",
                        revision: ^revision,
                        preview_snapshot: %{sha256: snapshot_sha}
                      }}

      assert snapshot_sha == Document.sha256(committed_bytes)
    end

    test "a complete candidate publishes one phase-explicit revision without preview steps" do
      root =
        Path.join(
          System.tmp_dir!(),
          "projection_candidate_fact_#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "contract.hwp")
      revision = Document.sha256("complete candidate")

      File.mkdir_p!(root)
      File.write!(path, <<0>>)
      on_exit(fn -> File.rm_rf(root) end)

      Phoenix.PubSub.subscribe(
        Ecrits.PubSub,
        "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(root)
      )

      :ok =
        Projection.__broadcast_edit_for_test__(
          path,
          browser_text_change("candidate"),
          [%{}],
          root: root,
          edit_id: "candidate-edit",
          phase: :candidate,
          revision: revision,
          preview_only: true,
          turn_id: "turn-a",
          agent_id: "agent-a",
          instance_id: "instance-a"
        )

      assert_receive {:vfs_doc_edited,
                      %{
                        phase: :candidate,
                        edit_id: "candidate-edit",
                        revision: ^revision,
                        preview_only: true,
                        preview_snapshot: nil,
                        preview_snapshot_error: nil
                      } = candidate}

      assert candidate.document_id == Document.id_for(root, "contract.hwp")
      refute Map.has_key?(candidate, :preview_steps)
      refute_receive {:vfs_doc_edited, _info}, 20
    end
  end

  # What survives of the HWPX write-back suite: the positional two-cursor diff
  # itself (`__compute_ir_changes_for_test__`). Its 18 sibling e2e cases drove
  # the deleted `:ehwp` NIF and had been self-skipping to a green "pass" that
  # executed no assertion, so they are gone with the arm.
  describe "write_back/3 change computation" do
    test "uses the source basename as a fallback picture description" do
      old_nodes = [
        %{
          "ref" => %{"section" => 0, "paragraph" => 1, "offset" => 0},
          "text" => "before",
          "type" => "paragraph"
        }
      ]

      new_nodes = [
        %{"text" => "before", "type" => "paragraph"},
        %{
          "src" => "/tmp/ecrits-fuse-hwpx-tidewave/bird_song_sparrow.jpg",
          "type" => "picture"
        }
      ]

      assert [
               {:insert_picture,
                %{
                  "description" => "bird_song_sparrow.jpg",
                  "src" => "/tmp/ecrits-fuse-hwpx-tidewave/bird_song_sparrow.jpg"
                }, "/tmp/ecrits-fuse-hwpx-tidewave/bird_song_sparrow.jpg", %{}}
             ] = Projection.__compute_ir_changes_for_test__(old_nodes, new_nodes)
    end

    test "still allows deleting one picture while editing the next picture by identity" do
      old_nodes = [
        %{
          "description" => "AGENT_APPEND_RED",
          "height" => 22_000,
          "ref" => %{"section" => 2, "paragraph" => 10, "control" => 0, "type" => "picture"},
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 22_000
        },
        %{
          "description" => "AGENT_APPEND_BLUE",
          "height" => 22_000,
          "ref" => %{"section" => 2, "paragraph" => 10, "control" => 1, "type" => "picture"},
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 22_000
        }
      ]

      new_nodes = [
        %{
          "description" => "AGENT_APPEND_BLUE",
          "height" => 24_000,
          "text" => "",
          "treatAsChar" => true,
          "type" => "picture",
          "width" => 24_000
        }
      ]

      assert [
               {:delete_node, %{"op" => "delete_node"}, "AGENT_APPEND_RED"},
               {:set, %{"control" => 1, "paragraph" => 10, "section" => 2, "type" => "picture"},
                "picture", %{"height" => 24_000, "width" => 24_000}}
             ] = Projection.__compute_ir_changes_for_test__(old_nodes, new_nodes)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp browser_transaction_loop(owner, path, exported_bytes, commit_reply) do
    receive do
      {:doc_browser_request, from, ref, verb, %{edit_id: edit_id}} ->
        handle_browser_transaction_request(
          owner,
          path,
          exported_bytes,
          commit_reply,
          from,
          ref,
          verb,
          edit_id
        )

      {:doc_browser_request, from, ref, verb, %{edit_id: edit_id}, _expected_document_id} ->
        handle_browser_transaction_request(
          owner,
          path,
          exported_bytes,
          commit_reply,
          from,
          ref,
          verb,
          edit_id
        )
    end
  end

  defp handle_browser_transaction_request(
         owner,
         path,
         exported_bytes,
         commit_reply,
         from,
         ref,
         verb,
         edit_id
       ) do
    send(owner, {:browser_transaction, verb, edit_id, File.read!(path)})
    send(owner, {:browser_transaction_owner, verb, edit_id, from})

    reply =
      case verb do
        :vfs_write -> {:ok, %{"bytes" => exported_bytes}}
        :vfs_commit when commit_reply == :timeout -> :no_reply
        :vfs_commit -> commit_reply
        :vfs_rollback -> {:ok, %{"rolled_back" => true}}
      end

    reply_and_ack_browser_request(from, ref, reply)
    browser_transaction_loop(owner, path, exported_bytes, commit_reply)
  end

  defp browser_commit_loop(exported_bytes) do
    receive do
      {:doc_browser_request, from, ref, verb, _payload} ->
        handle_browser_commit_request(exported_bytes, from, ref, verb)

      {:doc_browser_request, from, ref, verb, _payload, _expected_document_id} ->
        handle_browser_commit_request(exported_bytes, from, ref, verb)
    end
  end

  defp handle_browser_commit_request(exported_bytes, from, ref, verb) do
    reply =
      case verb do
        :vfs_write -> {:ok, %{"bytes" => exported_bytes}}
        :vfs_commit -> {:ok, %{"committed" => true}}
        :vfs_rollback -> {:ok, %{"rolled_back" => true}}
      end

    reply_and_ack_browser_request(from, ref, reply)
    browser_commit_loop(exported_bytes)
  end

  defp browser_payload_loop(owner, exported_bytes, commit_reply) do
    receive do
      {:doc_browser_request, from, ref, verb, payload} ->
        handle_browser_payload(owner, exported_bytes, commit_reply, from, ref, verb, payload)

      {:doc_browser_request, from, ref, verb, payload, _expected_document_id} ->
        handle_browser_payload(owner, exported_bytes, commit_reply, from, ref, verb, payload)
    end
  end

  defp handle_browser_payload(owner, exported_bytes, commit_reply, from, ref, verb, payload) do
    send(owner, {:browser_payload, verb, payload})

    reply =
      case verb do
        :vfs_write -> {:ok, %{"bytes" => exported_bytes}}
        :vfs_commit -> commit_reply
        :vfs_rollback -> {:ok, %{"rolled_back" => true}}
      end

    reply_and_ack_browser_request(from, ref, reply)
    browser_payload_loop(owner, exported_bytes, commit_reply)
  end

  defp reply_and_ack_browser_request(_from, _ref, :no_reply), do: :ok

  defp reply_and_ack_browser_request(from, ref, reply) do
    send(from, {:doc_browser_reply, ref, reply})

    receive do
      {:doc_browser_request_completed, ^from, ^ref, ack_ref} ->
        send(from, {:doc_browser_request_completion_ack, ack_ref, :ok})
    end
  end

  defp browser_text_change(marker) do
    [
      {:text,
       %{
         "op" => "insert_text",
         "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
         "text" => marker
       }, marker}
    ]
  end

  defp start_test_task(fun) when is_function(fun, 0) do
    child_spec = Supervisor.child_spec({Task, fun}, id: make_ref())
    start_supervised!(child_spec)
  end

  # A new body paragraph from a DocLang buffer insert lowers to `insert_text` with
  # a LEADING "\n" (the browser arm has no insert_paragraph verb), and the op's ref
  # is the ANCHOR — the end of the PRECEDING paragraph. Highlighting that ref marks
  # the wrong paragraph, and a zero-width range at a paragraph end yields no
  # rectangle at all: the preview shows the right page with no visible highlight.
  describe "highlights for a buffer-inserted paragraph" do
    test "marks the NEW paragraph, not the anchor it was written at" do
      op = %{
        "op" => "insert_text",
        "ref" => %{"section" => 0, "paragraph" => 11, "offset" => 13},
        "text" => "\n※ 납품 지연 시 지체상금은 별도 협의한다."
      }

      assert [highlight] =
               Projection.__highlights_for_changes_for_test__(
                 [{:text, op, "※ 납품 지연 시 지체상금은 별도 협의한다."}],
                 [1]
               )

      # anchor is paragraph 11 -> the break opens paragraph 12
      assert highlight["ref"]["paragraph"] == 12
      assert highlight["ref"]["offset"] == 0
      assert highlight["offset"] == 0
      assert highlight["length"] == String.length("※ 납품 지연 시 지체상금은 별도 협의한다.")
      assert highlight["text"] == "※ 납품 지연 시 지체상금은 별도 협의한다."
    end

    test "a multi-line insert marks each resulting paragraph in order" do
      op = %{
        "op" => "insert_text",
        "ref" => %{"section" => 0, "paragraph" => 4, "offset" => 0},
        "text" => "\n첫째 줄\n둘째 줄"
      }

      assert [first, second] =
               Projection.__highlights_for_changes_for_test__([{:text, op, "첫째 줄"}], [1])

      assert first["ref"]["paragraph"] == 5
      assert second["ref"]["paragraph"] == 6
      assert first["text"] == "첫째 줄"
      assert second["text"] == "둘째 줄"
    end

    test "an ordinary in-place insert_text (no leading break) still marks its own ref" do
      op = %{
        "op" => "insert_text",
        "ref" => %{"section" => 0, "paragraph" => 7, "offset" => 0},
        "text" => "빈 문단을 채운다"
      }

      assert [highlight] =
               Projection.__highlights_for_changes_for_test__([{:text, op, "빈 문단을 채운다"}], [1])

      assert highlight["ref"]["paragraph"] == 7
    end
  end
end
