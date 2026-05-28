defmodule Contract.RhwpSnapshotTest do
  use Contract.DataCase, async: false

  alias Contract.Change
  alias Contract.Command
  alias Contract.Context
  alias Contract.Documents
  alias Contract.IO.R2Stub
  alias Contract.RhwpSnapshot.Record
  alias Contract.RhwpSnapshot
  alias Contract.Runtime
  alias Contract.Snapshot
  alias Contract.Store

  setup do
    R2Stub.setup()
    R2Stub.reset()

    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)
    :ok
  end

  defp scope do
    user = %Contract.Accounts.User{id: Ecto.UUID.generate()}
    Context.for_user(user)
  end

  defp create_doc(%Context{} = ctx, title \\ "Doc") do
    doc_id = Ecto.UUID.generate()

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => title, "type_key" => "nda_v1"}
    }

    assert {:ok, %Change{}} = Runtime.apply(ctx, action)
    doc_id
  end

  describe "commit/4 — dual write" do
    test "writes native .hwp, companion .ir.json, and the rhwp_snapshots row" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      ir_key = "documents/#{doc_id}/snapshots/1.ir.json"

      # Simulate the .hwp already on R2 (the client PUT it before
      # the commit handler runs).
      R2Stub.put(hwp_key, "fake-hwp-bytes")
      ir = %{"title" => "Doc", "sections" => [%{"idx" => 0, "paragraphs" => []}]}

      assert {:ok, %Record{} = snap} = RhwpSnapshot.commit(doc_id, 1, hwp_key, ir)
      assert snap.document_id == doc_id
      assert snap.revision == 1
      assert snap.format == "hwp"
      assert snap.content_type == "application/x-hwp"
      assert snap.r2_key == hwp_key
      assert snap.ir_r2_key == ir_key

      objects = R2Stub.objects()
      assert Map.has_key?(objects, hwp_key)
      assert Map.has_key?(objects, ir_key)

      assert {:ok, %{"title" => "Doc"}} = Jason.decode(objects[ir_key])
    end

    test "rolls back both R2 blobs when the snapshots row insert fails" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      ir_key = "documents/#{doc_id}/snapshots/1.ir.json"

      R2Stub.put(hwp_key, "fake-hwp-bytes")

      # Force the insert to violate the FK by passing a bogus document_id
      # — Repo will return an error_changeset. We pass a malformed UUID
      # to fail the cast.
      assert {:error, _reason} =
               RhwpSnapshot.commit("not-a-uuid", 1, hwp_key, %{"title" => "X"})

      # Both R2 keys must be gone after rollback.
      objects = R2Stub.objects()
      refute Map.has_key?(objects, hwp_key)
      refute Map.has_key?(objects, ir_key)
    end

    test "retries transient IR PUT errors and succeeds on a later attempt" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"

      R2Stub.put(hwp_key, "fake-hwp-bytes")

      # Only the first PUT fails — the retry should succeed.
      R2Stub.fail_next(:put, :timeout)

      assert {:ok, %Record{}} = RhwpSnapshot.commit(doc_id, 1, hwp_key, %{"x" => 1})
    end

    test "does not overwrite the runtime Store snapshot at the same revision" do
      ctx = scope()
      doc_id = create_doc(ctx)
      assert {:ok, _state} = Store.snapshot(doc_id, 1)

      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      R2Stub.put(hwp_key, "fake-hwp-bytes")
      ir = %{"title" => "Doc", "sections" => [], "fields" => []}

      assert {:ok, %Record{} = rhwp_snap} = RhwpSnapshot.commit(doc_id, 1, hwp_key, ir)
      assert rhwp_snap.r2_key == hwp_key

      assert %Snapshot{r2_key: state_key} =
               Contract.Repo.get_by(Snapshot, document_id: doc_id, revision: 1)

      assert state_key == "documents/#{doc_id}/snapshots/1.json"
    end

    test "upload_and_commit/5 writes native HWP bytes server-side before committing IR" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      ir_key = "documents/#{doc_id}/snapshots/1.ir.json"

      ir = %{
        "title" => "Doc",
        "sections" => [%{"idx" => 0, "paragraphs" => [%{"idx" => 0, "text" => "Body"}]}]
      }

      assert {:ok, %Record{} = snap} =
               RhwpSnapshot.upload_and_commit(doc_id, 1, "server-side-hwp", ir, "hwp")

      assert snap.r2_key == hwp_key
      assert snap.ir_r2_key == ir_key
      assert snap.format == "hwp"
      assert snap.projection == ir

      objects = R2Stub.objects()
      assert objects[hwp_key] == "server-side-hwp"
      assert {:ok, ^ir} = Jason.decode(objects[ir_key])
    end

    test "candidates_for_document/3 returns newest snapshots for render fallback" do
      ctx = scope()
      doc_id = create_doc(ctx)

      for revision <- [1, 2, 3] do
        key = "documents/#{doc_id}/snapshots/#{revision}.hwp"
        assert {:ok, _} = R2Stub.put(key, "hwp-#{revision}")

        assert {:ok, %Record{}} =
                 RhwpSnapshot.commit(doc_id, revision, key, %{"revision" => revision})
      end

      assert [
               %Record{revision: 3},
               %Record{revision: 2}
             ] = RhwpSnapshot.candidates_for_document(doc_id, "hwp", limit: 2)
    end

    test "upload_and_commit/5 rejects native checkpoints after write completion" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"

      R2Stub.put(hwp_key, "approved-hwp")
      assert {:ok, %Record{}} = RhwpSnapshot.commit(doc_id, 1, hwp_key, %{"revision" => 1})
      assert {:ok, _doc} = Documents.complete_write(ctx, doc_id)

      assert {:error, :write_completed} =
               RhwpSnapshot.upload_and_commit(doc_id, 1, "mutated-hwp", %{"revision" => 1}, "hwp")

      assert R2Stub.objects()[hwp_key] == "approved-hwp"
    end

    test "commit/4 refuses to replace the completion-approved snapshot row" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      ir_key = "documents/#{doc_id}/snapshots/1.ir.json"

      R2Stub.put(hwp_key, "approved-hwp")
      assert {:ok, %Record{}} = RhwpSnapshot.commit(doc_id, 1, hwp_key, %{"approved" => true})
      assert {:ok, _doc} = Documents.complete_write(ctx, doc_id)

      assert {:error, :write_completed} =
               RhwpSnapshot.commit(doc_id, 1, hwp_key, %{"approved" => false})

      assert %Record{projection: %{"approved" => true}, r2_key: ^hwp_key} =
               Repo.get_by!(Record, document_id: doc_id, revision: 1)

      objects = R2Stub.objects()
      assert objects[hwp_key] == "approved-hwp"
      assert {:ok, %{"approved" => true}} = Jason.decode(objects[ir_key])
    end
  end

  describe "to_agent_ir/1 with no snapshot" do
    test "returns an empty IR — no legacy node-graph reconstruction" do
      ctx = scope()
      doc_id = create_doc(ctx, "Cold Doc")
      {:ok, state} = Runtime.load(ctx, doc_id)

      refute Contract.Repo.get_by(Snapshot, document_id: doc_id, revision: state.revision)

      ir = Contract.MCP.Projection.to_agent_ir(state)
      assert is_map(ir)
      assert ir["sections"] == []
      assert ir["fields"] == []
      assert ir["revision"] == state.revision
    end
  end

  describe "Projection structural text replay" do
    test "replays insert_paragraph before insert_text and shifts following paragraph indexes" do
      ctx = scope()
      doc_id = create_doc(ctx, "Split replay")

      insert_rhwp_snapshot!(doc_id, 1, split_base_ir())
      assert {:ok, %Change{result_revision: 2}} = apply_split_doc_write(ctx, doc_id)

      {:ok, state} = Store.load(doc_id)
      ir = Contract.MCP.Projection.to_agent_ir(state)

      assert Contract.MCP.Projection.paragraph_text_at(ir, 0, 0) == "Alpha"
      assert Contract.MCP.Projection.paragraph_text_at(ir, 0, 1) == "NEW Beta"
      assert Contract.MCP.Projection.paragraph_text_at(ir, 0, 2) == "Gamma"
    end

    test "same-revision validation rejects marker text without structural paragraph split" do
      ctx = scope()
      doc_id = create_doc(ctx, "Bad split replay")

      insert_rhwp_snapshot!(doc_id, 1, split_base_ir())
      assert {:ok, %Change{result_revision: 2}} = apply_split_doc_write(ctx, doc_id)

      insert_rhwp_snapshot!(doc_id, 2, %{
        "title" => "Bad split replay",
        "contract_type" => "nda_v1",
        "sections" => [
          %{
            "idx" => 0,
            "paragraphs" => [
              %{"idx" => 0, "text" => "Alpha Beta"},
              %{"idx" => 1, "text" => "NEW Beta"},
              %{"idx" => 2, "text" => "Gamma"}
            ]
          }
        ],
        "fields" => []
      })

      {:ok, state} = Store.load(doc_id)

      assert {:error, {:invalid_params, message}} =
               Contract.MCP.Projection.validate_text_edit_basis(state)

      assert message =~ "same-revision projection basis is stale"
    end
  end

  defp split_base_ir do
    %{
      "title" => "Split replay",
      "contract_type" => "nda_v1",
      "sections" => [
        %{
          "idx" => 0,
          "paragraphs" => [
            %{"idx" => 0, "text" => "Alpha Beta"},
            %{"idx" => 1, "text" => "Gamma"}
          ]
        }
      ],
      "fields" => []
    }
  end

  defp apply_split_doc_write(ctx, doc_id) do
    Runtime.apply(ctx, %Command{
      kind: :doc_write,
      document_id: doc_id,
      actor_type: :agent,
      actor_id: ctx.user.id,
      base_revision: 1,
      idempotency_key: "split-#{Ecto.UUID.generate()}",
      payload: %{
        "sec" => 0,
        "para" => 0,
        "type" => "paragraph",
        "payload" => %{
          "cmd" => "insert_paragraph_after",
          "payload" => %{"text" => "NEW"}
        },
        "resolved" => %{"off" => 5}
      }
    })
  end

  defp insert_rhwp_snapshot!(doc_id, revision, ir) do
    assert {:ok, %Record{} = snapshot} =
             RhwpSnapshot.upload_and_commit(doc_id, revision, "hwp-#{revision}", ir, "hwp")

    snapshot
  end
end
