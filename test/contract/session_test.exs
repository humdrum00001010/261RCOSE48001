defmodule Contract.SessionTest do
  # Session tests start a real GenServer that subscribes to PubSub and is
  # registered in a global registry, so they must run synchronously.
  use Contract.DataCase, async: false

  alias Contract.Command
  alias Contract.Change
  alias Contract.IO.R2Stub
  alias Contract.Lease
  alias Contract.Session
  alias Contract.Store

  setup do
    R2Stub.setup()
    R2Stub.reset()

    original_drivers = Application.get_env(:contract, :io_drivers, [])

    Application.put_env(
      :contract,
      :io_drivers,
      Keyword.put(original_drivers, :r2, R2Stub)
    )

    on_exit(fn -> Application.put_env(:contract, :io_drivers, original_drivers) end)
    :ok
  end

  defp start_session!(opts) do
    document_id = Keyword.get(opts, :document_id) || Ecto.UUID.generate()

    {:ok, pid} =
      Session.start_link(
        Keyword.merge(
          [
            document_id: document_id,
            renew_interval_ms: Keyword.get(opts, :renew_interval_ms, 60_000),
            idle_after_ms: Keyword.get(opts, :idle_after_ms, 5 * 60_000),
            idle_check_interval_ms: Keyword.get(opts, :idle_check_interval_ms, 60_000)
          ],
          opts
        )
      )

    # Unlink so the test process doesn't die when the Session terminates
    # abnormally (lease-lost / fenced-out paths). We monitor explicitly
    # in the tests that need to observe the death.
    Process.unlink(pid)

    {pid, document_id}
  end

  defp seed_document!(document_id) do
    {:ok, lease} = Lease.acquire(document_id, "seed-owner-#{System.unique_integer([:positive])}")

    change = %Change{
      document_id: document_id,
      command_kind: "create_document",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: 0,
      idempotency_key: "seed-#{document_id}",
      payload: [
        %{
          "op" => "create_node",
          "target_type" => "document",
          "target_id" => document_id,
          "args" => %{"title" => "Seed", "type_key" => "nda"}
        }
      ]
    }

    {:ok, _} = Store.append(document_id, change, lease.fencing_token)
    {:ok, :ok} = Lease.release(document_id, lease.owner_ref, lease.fencing_token)
    :ok
  end

  describe "start_link/1" do
    test "starts, registers under document_id, and acquires a lease" do
      doc = Ecto.UUID.generate()
      {pid, ^doc} = start_session!(document_id: doc)

      assert is_pid(pid)
      assert Session.whereis(doc) == pid
      assert %Lease.Record{document_id: ^doc} = Lease.get(doc)
    end

    test "init hydrates state from the Store" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)
      {pid, ^doc} = start_session!(document_id: doc)

      assert {:ok, state} = Session.current(pid)
      assert state.revision == 1
      assert state.projection.title == "Seed"
    end

    test "second start_link for the same doc is rejected by the registry" do
      doc = Ecto.UUID.generate()
      {_pid1, ^doc} = start_session!(document_id: doc)

      # Same registry name → already_started.
      assert {:error, {:already_started, _pid}} =
               Session.start_link(document_id: doc, renew_interval_ms: 60_000)
    end

    test "init returns {:stop, :lease_held} when another holder has the lease" do
      doc = Ecto.UUID.generate()
      {:ok, _} = Lease.acquire(doc, "external-holder")

      # Call init/1 directly to simulate a session that fails before
      # the registry registration ever happens.
      assert {:stop, :lease_held} =
               Session.init(
                 document_id: doc,
                 owner_ref: "would-be-holder-#{System.unique_integer([:positive])}"
               )
    end
  end

  describe "commit/2" do
    test "creates a Change and advances the projection" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)
      {pid, ^doc} = start_session!(document_id: doc)

      action = %Command{
        kind: :rename_document,
        document_id: doc,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 1,
        idempotency_key: "rn-1",
        payload: %{"title" => "New Title"}
      }

      assert {:ok, %Change{result_revision: 2}} = Session.commit(pid, action)
      assert {:ok, state} = Session.current(pid)
      assert state.revision == 2
      assert state.projection.title == "New Title"
    end

    test "returns {:error, {:revision_conflict, _}} on stale base_revision" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)
      {pid, ^doc} = start_session!(document_id: doc)

      action = %Command{
        kind: :rename_document,
        document_id: doc,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 99,
        idempotency_key: "rn-bad",
        payload: %{"title" => "X"}
      }

      assert {:error, {:revision_conflict, _}} = Session.commit(pid, action)
    end

    test "idempotency: replaying the same action returns the same Change" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)
      {pid, ^doc} = start_session!(document_id: doc)

      action = %Command{
        kind: :rename_document,
        document_id: doc,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 1,
        idempotency_key: "rn-idem",
        payload: %{"title" => "X"}
      }

      assert {:ok, %Change{id: id1}} = Session.commit(pid, action)
      assert {:ok, %Change{id: ^id1}} = Session.commit(pid, action)
    end

    test "fills out the document_id from the session when missing on the action" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)
      {pid, ^doc} = start_session!(document_id: doc)

      action = %Command{
        kind: :rename_document,
        document_id: nil,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 1,
        idempotency_key: "rn-2",
        payload: %{"title" => "Y"}
      }

      assert {:ok, %Change{document_id: ^doc}} = Session.commit(pid, action)
    end
  end

  describe "sync_since/2" do
    test "returns changes after a given revision" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)
      {pid, ^doc} = start_session!(document_id: doc)

      action = %Command{
        kind: :rename_document,
        document_id: doc,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 1,
        idempotency_key: "rn-sync",
        payload: %{"title" => "S"}
      }

      {:ok, _} = Session.commit(pid, action)

      assert {:ok, [%Change{result_revision: 2}]} = Session.sync_since(pid, 1)

      assert {:ok, [%Change{result_revision: 1}, %Change{result_revision: 2}]} =
               Session.sync_since(pid, 0)
    end
  end

  describe "heartbeat/1" do
    test "advances last_heartbeat" do
      doc = Ecto.UUID.generate()
      {pid, ^doc} = start_session!(document_id: doc)
      data1 = Session.__get_state__(pid)
      Process.sleep(10)
      :ok = Session.heartbeat(pid)
      # Cast is async — wait for it to land.
      Process.sleep(20)
      data2 = Session.__get_state__(pid)
      assert DateTime.compare(data2.last_heartbeat, data1.last_heartbeat) == :gt
    end
  end

  describe "shutdown_if_stale/1" do
    test "stops idle sessions past the threshold; recent heartbeat keeps it alive" do
      # Stale: idle_after_ms=0 → immediately stops.
      stale_doc = Ecto.UUID.generate()
      {stale_pid, ^stale_doc} = start_session!(document_id: stale_doc, idle_after_ms: 0)
      ref = Process.monitor(stale_pid)
      Process.sleep(20)
      :ok = Session.shutdown_if_stale(stale_pid)
      assert_receive {:DOWN, ^ref, :process, ^stale_pid, :normal}, 1_000

      # Active: recent heartbeat keeps the session alive.
      live_doc = Ecto.UUID.generate()
      {live_pid, ^live_doc} = start_session!(document_id: live_doc, idle_after_ms: 60_000)
      :ok = Session.heartbeat(live_pid)
      Process.sleep(20)
      :ok = Session.shutdown_if_stale(live_pid)
      Process.sleep(20)
      assert Process.alive?(live_pid)
    end
  end

  describe "lease loss" do
    test "session terminates when its lease is taken over" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)

      {pid, ^doc} = start_session!(document_id: doc, renew_interval_ms: 50)
      ref = Process.monitor(pid)

      # Force-expire and let another writer take the lease.
      :ok = Lease.force_expire!(doc)
      {:ok, _newer} = Lease.acquire(doc, "thief")

      assert_receive {:DOWN, ^ref, :process, ^pid, {:lease_lost, _}}, 2_000
    end

    test "commit through a fenced-out session returns {:error, {:fenced_out, _}}" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)

      # Start a session with a very slow renew so the takeover happens
      # before the next renew tick.
      {pid, ^doc} = start_session!(document_id: doc, renew_interval_ms: 60_000)
      ref = Process.monitor(pid)

      :ok = Lease.force_expire!(doc)
      {:ok, _newer} = Lease.acquire(doc, "thief")

      action = %Command{
        kind: :rename_document,
        document_id: doc,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 1,
        idempotency_key: "rn-fenced",
        payload: %{"title" => "Doomed"}
      }

      assert {:error, {:fenced_out, _}} = Session.commit(pid, action)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:fenced_out, _}}, 1_000
    end
  end

  describe "current/1" do
    test "returns the current Runtime.State" do
      doc = Ecto.UUID.generate()
      :ok = seed_document!(doc)
      {pid, ^doc} = start_session!(document_id: doc)

      assert {:ok, state} = Session.current(pid)
      assert state.document_id == doc
      assert state.revision == 1
    end
  end
end
