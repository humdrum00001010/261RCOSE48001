defmodule Contract.StoreTest do
  use Contract.DataCase, async: true

  alias Contract.Change
  alias Contract.IO.R2Stub
  alias Contract.Lease
  alias Contract.Operation
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

  defp new_document_id, do: Ecto.UUID.generate()

  defp acquire_lease(document_id) do
    {:ok, lease} = Lease.acquire(document_id, "test-owner-#{System.unique_integer([:positive])}")
    lease
  end

  defp build_create_change(document_id, opts \\ []) do
    %Change{
      matter_id: Keyword.get(opts, :matter_id, Ecto.UUID.generate()),
      document_id: document_id,
      action_kind: "create_document",
      actor_type: :user,
      actor_id: Keyword.get(opts, :actor_id, Ecto.UUID.generate()),
      base_revision: 0,
      applied_revision: nil,
      idempotency_key: Keyword.get(opts, :idempotency_key, "create-#{document_id}"),
      ops: [
        %{
          "op" => "create_node",
          "target_type" => "document",
          "target_id" => document_id,
          "args" => %{"title" => Keyword.get(opts, :title, "T"), "type_key" => "nda"}
        }
      ],
      marks: [],
      message: nil,
      affected_refs: [],
      preimage: %{},
      inverse_ops: [],
      status: :active
    }
  end

  defp build_followup_change(document_id, base_revision, opts \\ []) do
    %Change{
      matter_id: Ecto.UUID.generate(),
      document_id: document_id,
      action_kind: "rename_document",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: base_revision,
      applied_revision: nil,
      idempotency_key: Keyword.get(opts, :idempotency_key, "rev-#{base_revision}"),
      ops: [
        %{
          "op" => "set_attr",
          "target_type" => "document",
          "target_id" => document_id,
          "args" => %{"key" => "title", "value" => Keyword.get(opts, :title, "Renamed")}
        }
      ],
      marks: [],
      message: nil,
      affected_refs: [],
      preimage: %{},
      inverse_ops: [],
      status: :active
    }
  end

  describe "latest_revision/1" do
    test "returns 0 for an unknown document" do
      assert {:ok, 0} = Store.latest_revision(new_document_id())
    end

    test "returns the max applied_revision" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
      assert {:ok, 1} = Store.latest_revision(doc)

      assert {:ok, _} =
               Store.append(doc, build_followup_change(doc, 1), lease.fencing_token)

      assert {:ok, 2} = Store.latest_revision(doc)
    end
  end

  describe "append/3" do
    test "persists a Change row and bumps applied_revision to latest + 1" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      assert {:ok, %Change{applied_revision: 1} = persisted} =
               Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert persisted.document_id == doc
      assert persisted.action_kind == "create_document"
    end

    test "broadcasts {:change_committed, _} on the document topic" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, Store.pubsub_topic(doc))

      assert {:ok, change} =
               Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert_receive {:change_committed, %Change{id: id}}, 1_000
      assert id == change.id
    end

    test "rejects a stale fencing token with {:error, {:fenced_out, _, _, _}}" do
      doc = new_document_id()
      _lease = acquire_lease(doc)

      # Force-bump the lease by acquiring under a different owner after
      # expiring the current row.
      Lease.force_expire!(doc)
      {:ok, _new_lease} = Lease.acquire(doc, "different-owner")

      assert {:error, {:fenced_out, _current, _supplied, _meta}} =
               Store.append(doc, build_create_change(doc), 1)
    end

    test "rejects a base_revision mismatch with {:error, {:revision_conflict, _}}" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      bad = build_followup_change(doc, 99, idempotency_key: "bad")

      assert {:error, {:revision_conflict, expected: 1, got: 99}} =
               Store.append(doc, bad, lease.fencing_token)
    end

    test "idempotency: replaying the same idempotency_key returns the original row" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      change = build_create_change(doc, idempotency_key: "idem-1")

      assert {:ok, persisted1} = Store.append(doc, change, lease.fencing_token)
      assert {:ok, persisted2} = Store.append(doc, change, lease.fencing_token)

      assert persisted1.id == persisted2.id
      assert {:ok, 1} = Store.latest_revision(doc)
    end

    test "idempotency keyed per-document — same key under different doc is allowed" do
      doc_a = new_document_id()
      doc_b = new_document_id()
      lease_a = acquire_lease(doc_a)
      lease_b = acquire_lease(doc_b)

      change_a = build_create_change(doc_a, idempotency_key: "shared")
      change_b = build_create_change(doc_b, idempotency_key: "shared")

      assert {:ok, ca} = Store.append(doc_a, change_a, lease_a.fencing_token)
      assert {:ok, cb} = Store.append(doc_b, change_b, lease_b.fencing_token)

      assert ca.id != cb.id
    end

    test "nil idempotency_key never collides" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      change1 = build_create_change(doc, idempotency_key: nil)

      assert {:ok, c1} = Store.append(doc, change1, lease.fencing_token)
      assert {:ok, _} = Store.latest_revision(doc)

      change2 = build_followup_change(doc, 1, idempotency_key: nil)
      assert {:ok, c2} = Store.append(doc, change2, lease.fencing_token)
      assert c1.id != c2.id
    end

    test "second commit advances revision to 2 with base_revision=1" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert {:ok, %Change{applied_revision: 2}} =
               Store.append(doc, build_followup_change(doc, 1), lease.fencing_token)
    end

    test "rejects when fencing_token doesn't match the current row" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      bad_token = lease.fencing_token - 1

      assert {:error, {:fenced_out, _, _, _}} =
               Store.append(doc, build_create_change(doc), bad_token)
    end
  end

  describe "changes_since/2" do
    test "returns [] when none after revision" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert {:ok, []} = Store.changes_since(doc, 1)
      assert {:ok, []} = Store.changes_since(doc, 99)
    end

    test "returns all changes when revision is 0" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert {:ok, _} =
               Store.append(doc, build_followup_change(doc, 1), lease.fencing_token)

      assert {:ok, [c1, c2]} = Store.changes_since(doc, 0)
      assert c1.applied_revision == 1
      assert c2.applied_revision == 2
    end

    test "results are sorted by applied_revision ascending" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_followup_change(doc, 1, idempotency_key: "a"),
                 lease.fencing_token
               )

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_followup_change(doc, 2, idempotency_key: "b"),
                 lease.fencing_token
               )

      assert {:ok, [_, _, _] = changes} = Store.changes_since(doc, 0)
      assert Enum.map(changes, & &1.applied_revision) == [1, 2, 3]
    end
  end

  describe "load/1" do
    test "returns empty state at revision 0 for an unknown document" do
      doc = new_document_id()
      assert {:ok, %Runtime.State{revision: 0, projection: proj}} = Store.load(doc)
      assert proj == Runtime.State.empty_projection()
    end

    test "replays all changes into the projection" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      assert {:ok, _} =
               Store.append(doc, build_create_change(doc, title: "Initial"), lease.fencing_token)

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_followup_change(doc, 1, title: "Renamed"),
                 lease.fencing_token
               )

      assert {:ok, %Runtime.State{revision: 2, projection: proj}} = Store.load(doc)
      assert proj.title == "Renamed"
    end

    test "load is consistent with fold-replay of changes" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
      assert {:ok, _} = Store.append(doc, build_followup_change(doc, 1), lease.fencing_token)

      assert {:ok, %Runtime.State{revision: rev}} = Store.load(doc)
      assert rev == 2
    end
  end

  describe "snapshot/2" do
    test "writes a snapshot row + R2 object at the current revision" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
      assert {:ok, _} = Store.append(doc, build_followup_change(doc, 1), lease.fencing_token)

      assert {:ok, %Runtime.State{revision: 2}} = Store.snapshot(doc, 2)

      assert %Snapshot{revision: 2, r2_key: key} =
               Contract.Repo.get_by(Snapshot, document_id: doc, revision: 2)

      assert key == "documents/#{doc}/snapshots/2.json"
      assert Map.has_key?(R2Stub.objects(), key)
    end

    test "load/1 short-circuits via snapshot + later changes" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
      assert {:ok, _} = Store.snapshot(doc, 1)

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_followup_change(doc, 1, title: "After"),
                 lease.fencing_token
               )

      assert {:ok, %Runtime.State{revision: 2, projection: %{title: "After"}}} =
               Store.load(doc)
    end

    test "rolls back the DB row when R2 put fails" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      R2Stub.fail_next(:put, :network_down)

      assert {:error, :network_down} = Store.snapshot(doc, 1)
      assert nil == Contract.Repo.get_by(Snapshot, document_id: doc, revision: 1)
    end

    test "errors when requested revision doesn't match current state" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert {:error, {:snapshot_revision_mismatch, expected: 99, got: 1}} =
               Store.snapshot(doc, 99)
    end
  end

  describe "idempotency_seen? / previous_result" do
    test "idempotency_seen? returns false for nil/unseen keys" do
      doc = new_document_id()
      refute Store.idempotency_seen?(doc, nil)
      refute Store.idempotency_seen?(doc, "never-seen")
    end

    test "idempotency_seen? returns true after the change exists" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_create_change(doc, idempotency_key: "seen"),
                 lease.fencing_token
               )

      assert Store.idempotency_seen?(doc, "seen")
      refute Store.idempotency_seen?(doc, "different")
    end

    test "previous_result returns the persisted Change for a seen key" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      assert {:ok, persisted} =
               Store.append(
                 doc,
                 build_create_change(doc, idempotency_key: "prev"),
                 lease.fencing_token
               )

      assert {:ok, %Change{id: id}} = Store.previous_result(doc, "prev")
      assert id == persisted.id
    end

    test "previous_result returns {:error, :not_found} when missing" do
      assert {:error, :not_found} = Store.previous_result(new_document_id(), "missing")
      assert {:error, :not_found} = Store.previous_result(new_document_id(), nil)
    end
  end

  describe "transaction/1" do
    test "commits on {:ok, value}" do
      assert {:ok, 42} = Store.transaction(fn -> {:ok, 42} end)
    end

    test "rolls back on {:error, reason}" do
      assert {:error, :nope} = Store.transaction(fn -> {:error, :nope} end)
    end

    test "rolls back on bad return shape" do
      assert {:error, {:bad_transaction_return, :weird}} =
               Store.transaction(fn -> :weird end)
    end

    test "actual DB writes inside a failed transaction get rolled back" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      result =
        Store.transaction(fn ->
          {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
          {:error, :abort}
        end)

      assert {:error, :abort} = result
      assert {:ok, 0} = Store.latest_revision(doc)
    end
  end

  describe "document set_attr propagation (Task #81)" do
    # When Engine emits a `:set_attr` op against `target_type: :document`,
    # Store.append must mirror the affected attribute(s) onto the
    # `documents` SQL row so dashboard/list queries don't see stale
    # title/type_key/status. The propagation runs inside the same
    # `Repo.transaction/1` as the Change insert.

    alias Contract.Documents

    defp setup_document_row(matter_id, owner_id \\ nil) do
      owner_id = owner_id || Ecto.UUID.generate()
      doc_id = Ecto.UUID.generate()

      {:ok, _matter} =
        %Contract.Matters.Matter{id: matter_id}
        |> Contract.Matters.Matter.changeset(%{
          "name" => "M-#{System.unique_integer([:positive])}",
          "owner_id" => owner_id
        })
        |> Contract.Repo.insert()

      {:ok, _doc} =
        %Contract.Documents.Document{id: doc_id}
        |> Contract.Documents.Document.changeset(%{
          "matter_id" => matter_id,
          "title" => "Initial",
          "type_key" => "nda_v1",
          "status" => "active"
        })
        |> Contract.Repo.insert()

      {doc_id, owner_id}
    end

    defp set_attr_change(doc_id, base_revision, key, value, opts \\ []) do
      %Change{
        matter_id: Ecto.UUID.generate(),
        document_id: doc_id,
        action_kind: "set_attr_doc",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: base_revision,
        applied_revision: nil,
        idempotency_key: Keyword.get(opts, :idempotency_key, "set-#{key}-#{base_revision}"),
        ops: [
          %{
            "op" => "set_attr",
            "target_type" => "document",
            "target_id" => doc_id,
            "args" => %{"key" => Atom.to_string(key), "value" => value}
          }
        ],
        marks: [],
        message: nil,
        affected_refs: [],
        preimage: %{},
        inverse_ops: [],
        status: :active
      }
    end

    test "set_attr :title updates the documents row" do
      matter_id = Ecto.UUID.generate()
      {doc_id, _owner_id} = setup_document_row(matter_id)
      lease = acquire_lease(doc_id)

      change = set_attr_change(doc_id, 0, :title, "Renamed Title")
      assert {:ok, _persisted} = Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      assert row.title == "Renamed Title"
    end

    test "set_attr :type_key updates the documents row" do
      matter_id = Ecto.UUID.generate()
      {doc_id, _owner_id} = setup_document_row(matter_id)
      lease = acquire_lease(doc_id)

      change = set_attr_change(doc_id, 0, :type_key, "service_agreement_v1")
      assert {:ok, _persisted} = Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      assert row.type_key == "service_agreement_v1"
    end

    test "set_attr :status updates the documents row" do
      matter_id = Ecto.UUID.generate()
      {doc_id, _owner_id} = setup_document_row(matter_id)
      lease = acquire_lease(doc_id)

      change = set_attr_change(doc_id, 0, :status, "archived")
      assert {:ok, _persisted} = Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      assert row.status == :archived
    end

    test "multiple set_attr ops in one Change all propagate" do
      matter_id = Ecto.UUID.generate()
      {doc_id, _owner_id} = setup_document_row(matter_id)
      lease = acquire_lease(doc_id)

      change = %Change{
        matter_id: matter_id,
        document_id: doc_id,
        action_kind: "bulk_set_attr",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 0,
        applied_revision: nil,
        idempotency_key: "bulk-#{doc_id}",
        ops: [
          %{
            "op" => "set_attr",
            "target_type" => "document",
            "target_id" => doc_id,
            "args" => %{"key" => "title", "value" => "Bulk Title"}
          },
          %{
            "op" => "set_attr",
            "target_type" => "document",
            "target_id" => doc_id,
            "args" => %{"key" => "type_key", "value" => "msa_v1"}
          },
          %{
            "op" => "set_attr",
            "target_type" => "document",
            "target_id" => doc_id,
            "args" => %{"key" => "status", "value" => "archived"}
          }
        ],
        marks: [],
        message: nil,
        affected_refs: [],
        preimage: %{},
        inverse_ops: [],
        status: :active
      }

      assert {:ok, _} = Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      assert row.title == "Bulk Title"
      assert row.type_key == "msa_v1"
      assert row.status == :archived
    end

    test "non-attr ops (e.g. create_node) leave the documents row untouched" do
      matter_id = Ecto.UUID.generate()
      {doc_id, _owner_id} = setup_document_row(matter_id)
      lease = acquire_lease(doc_id)

      # build_create_change builds a :create_node op, NOT a :set_attr op.
      change = build_create_change(doc_id, matter_id: matter_id, idempotency_key: "create-only")
      assert {:ok, _} = Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      # untouched — title/type_key/status are still the seed values
      assert row.title == "Initial"
      assert row.type_key == "nda_v1"
      assert row.status == :active
    end

    test "Documents.get/2 reflects the propagated title" do
      matter_id = Ecto.UUID.generate()
      {doc_id, owner_id} = setup_document_row(matter_id)
      lease = acquire_lease(doc_id)

      # The seeded matter has tenant_id: nil so any non-nil scope can
      # read it via the ACL gate.
      scope = %Contract.Context{
        user: %Contract.Accounts.User{id: owner_id, email: "owner@x"},
        tenant: nil
      }

      assert {:ok, _} =
               Store.append(
                 doc_id,
                 set_attr_change(doc_id, 0, :title, "After Propagation"),
                 lease.fencing_token
               )

      assert {:ok, %Documents.Document{title: "After Propagation"}} =
               Documents.get(scope, doc_id)
    end
  end

  describe "change_to_input/1" do
    test "decodes string ops back into Operation structs with atom kinds" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, persisted} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      input = Store.change_to_input(persisted)
      assert input.action_kind == :create_document
      assert [%Operation{op: :create_node, target_type: :document}] = input.ops
    end
  end
end
