defmodule Contract.StoreConcurrencyTest do
  @moduledoc """
  Concurrency invariants required by SPEC.md §15:

    * Only one of N concurrent appenders with the same `base_revision`
      may win — the others observe `{:error, {:revision_conflict, _}}`.
    * A fenced-out (stale fencing token) commit cannot land even if it
      races against the live writer.
    * Idempotency dedupes parallel replays of the same `(document_id,
      idempotency_key)` pair.

  These tests use `async: false` plus shared-mode SQL sandbox so that
  background tasks see the same in-test database state. We also set
  `:set_mox_from_context` semantics implicitly by avoiding any IO that
  reaches a mocked driver.
  """
  use ExUnit.Case, async: false

  alias Contract.Change
  alias Contract.IO.R2Stub
  alias Contract.Lease
  alias Contract.Repo
  alias Contract.Store

  setup do
    # Acquire a shared-mode connection so tasks spawned from this test
    # share the same sandbox.
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    R2Stub.setup()
    R2Stub.reset()

    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)

    :ok
  end

  defp build_change(doc, idem, base_revision) do
    %Change{
      document_id: doc,
      action_kind: "rename_document",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: base_revision,
      idempotency_key: idem,
      ops: [
        %{
          "op" => "set_attr",
          "target_type" => "document",
          "target_id" => doc,
          "args" => %{"key" => "title", "value" => "T-#{idem}"}
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

  defp seed!(doc) do
    {:ok, lease} = Lease.acquire(doc, "seed-#{System.unique_integer([:positive])}")

    create = %Change{
      document_id: doc,
      action_kind: "create_document",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: 0,
      idempotency_key: "seed-#{doc}",
      ops: [
        %{
          "op" => "create_node",
          "target_type" => "document",
          "target_id" => doc,
          "args" => %{"title" => "Seed", "type_key" => "nda"}
        }
      ],
      marks: [],
      message: nil,
      affected_refs: [],
      preimage: %{},
      inverse_ops: [],
      status: :active
    }

    {:ok, _} = Store.append(doc, create, lease.fencing_token)
    lease
  end

  describe "concurrent appends with same base_revision" do
    test "exactly one of 50 concurrent appenders wins; others see {:revision_conflict, _}" do
      doc = Ecto.UUID.generate()
      lease = seed!(doc)

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            change = build_change(doc, "concurrent-#{i}", 1)
            Store.append(doc, change, lease.fencing_token)
          end)
        end

      results = Task.await_many(tasks, 15_000)

      successes = Enum.count(results, &match?({:ok, %Change{}}, &1))
      conflicts = Enum.count(results, &match?({:error, {:revision_conflict, _}}, &1))

      assert successes == 1
      assert successes + conflicts == 50
      assert {:ok, 2} = Store.latest_revision(doc)
    end
  end

  describe "fencing protection" do
    test "second session with stale token cannot commit; lease takeover sticks" do
      doc = Ecto.UUID.generate()
      lease_a = seed!(doc)

      # Force expire and let "writer B" take the lease.
      :ok = Lease.force_expire!(doc)
      {:ok, lease_b} = Lease.acquire(doc, "writer-b")

      # Old writer A can no longer commit.
      assert {:error, {:fenced_out, _, _, _}} =
               Store.append(doc, build_change(doc, "from-a", 1), lease_a.fencing_token)

      # New writer B can commit.
      assert {:ok, %Change{applied_revision: 2}} =
               Store.append(doc, build_change(doc, "from-b", 1), lease_b.fencing_token)
    end

    test "lease expiry mid-flight is caught by assert_current!" do
      doc = Ecto.UUID.generate()
      lease = seed!(doc)

      # Expire the lease without taking it over — assert_current! must
      # still reject (TTL elapsed).
      :ok = Lease.force_expire!(doc)

      assert {:error, {:fenced_out, _, _, [reason: :expired]}} =
               Store.append(doc, build_change(doc, "post-expiry", 1), lease.fencing_token)
    end

    test "writer with the old fencing token loses against the newer one" do
      doc = Ecto.UUID.generate()
      lease_a = seed!(doc)

      # Same owner re-acquire after force-expire still bumps the token.
      :ok = Lease.force_expire!(doc)
      {:ok, lease_a2} = Lease.acquire(doc, lease_a.owner_ref)
      assert lease_a2.fencing_token > lease_a.fencing_token

      # The original (older) token must now fence out.
      assert {:error, {:fenced_out, _, _, _}} =
               Store.append(doc, build_change(doc, "old-token", 1), lease_a.fencing_token)

      # New token works.
      assert {:ok, _} =
               Store.append(doc, build_change(doc, "new-token", 1), lease_a2.fencing_token)
    end
  end

  describe "idempotency under parallel replays" do
    test "10 parallel appends with the same idempotency_key all resolve to the same Change" do
      doc = Ecto.UUID.generate()
      lease = seed!(doc)

      change = build_change(doc, "parallel-idem", 1)

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> Store.append(doc, change, lease.fencing_token) end)
        end

      results = Task.await_many(tasks, 15_000)

      ids =
        results
        |> Enum.map(fn
          {:ok, %Change{id: id}} -> id
          other -> other
        end)

      # All ten must produce the same Change id — the unique index +
      # idempotency replay path collapses them.
      [first | _] = ids
      assert Enum.all?(ids, &(&1 == first))
      assert is_binary(first)

      # And revision didn't run away.
      assert {:ok, 2} = Store.latest_revision(doc)
    end
  end

  describe "advisory lock serialization" do
    test "appends to the same document serialize behind pg_advisory_xact_lock" do
      doc = Ecto.UUID.generate()
      lease = seed!(doc)

      # Spawn 20 tasks; the first one to win advances base_revision so the
      # rest see revision_conflict. The cumulative latest_revision after
      # all tasks complete must be exactly 2 (1 from seed + 1 successful
      # append).
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            change = build_change(doc, "ser-#{i}", 1)
            Store.append(doc, change, lease.fencing_token)
          end)
        end

      _ = Task.await_many(tasks, 15_000)

      assert {:ok, 2} = Store.latest_revision(doc)
    end

    test "parallel appends to distinct documents do NOT serialize against each other" do
      docs = for _ <- 1..10, do: Ecto.UUID.generate()
      leases = for d <- docs, do: {d, seed!(d)}

      tasks =
        for {doc, lease} <- leases do
          Task.async(fn ->
            change = build_change(doc, "iso-#{doc}", 1)
            Store.append(doc, change, lease.fencing_token)
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.all?(results, &match?({:ok, %Change{applied_revision: 2}}, &1))
    end
  end

  describe "revision monotonicity" do
    test "applied_revision is strictly monotonic across a serial chain" do
      doc = Ecto.UUID.generate()
      lease = seed!(doc)

      revisions =
        Enum.reduce(1..15, 1, fn i, base ->
          change = build_change(doc, "mono-#{i}", base)
          {:ok, c} = Store.append(doc, change, lease.fencing_token)
          assert c.applied_revision == base + 1
          c.applied_revision
        end)

      assert revisions == 16
      assert {:ok, 16} = Store.latest_revision(doc)
    end
  end
end
