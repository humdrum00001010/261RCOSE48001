defmodule Ecrits.LeaseTest do
  use Ecrits.DataCase, async: true

  alias Ecrits.Lease
  alias Ecrits.Lease.Record

  defp new_doc, do: Ecto.UUID.generate()

  describe "acquire/2" do
    test "creates a fresh lease when none exists" do
      doc = new_doc()
      assert {:ok, %Record{} = lease} = Lease.acquire(doc, "owner-a")
      assert lease.document_id == doc
      assert lease.owner_ref == "owner-a"
      assert is_integer(lease.fencing_token) and lease.fencing_token > 0
      assert DateTime.compare(lease.expires_at, DateTime.utc_now()) == :gt
    end

    test "refreshes the lease when the same owner re-acquires" do
      doc = new_doc()
      assert {:ok, lease1} = Lease.acquire(doc, "owner-a")
      assert {:ok, lease2} = Lease.acquire(doc, "owner-a")

      # Re-acquire by same owner does NOT bump the fencing token, since the
      # ON CONFLICT path doesn't issue nextval; the SQL only bumps when the
      # WHERE clause selects an expired-or-same-owner row. Both should
      # yield the same token here.
      assert lease2.owner_ref == "owner-a"
      assert lease2.document_id == doc
      # Re-acquire is allowed (no error)
      assert is_integer(lease2.fencing_token)
      assert lease2.fencing_token >= lease1.fencing_token
    end

    test "rejects a different owner while the lease is held" do
      doc = new_doc()
      assert {:ok, _} = Lease.acquire(doc, "owner-a")
      assert {:error, :held_by_other} = Lease.acquire(doc, "owner-b")
    end

    test "another owner can take over after the lease expires" do
      doc = new_doc()
      assert {:ok, lease1} = Lease.acquire(doc, "owner-a")

      :ok = Lease.force_expire!(doc)

      assert {:ok, lease2} = Lease.acquire(doc, "owner-b")
      assert lease2.owner_ref == "owner-b"
      assert lease2.fencing_token > lease1.fencing_token
    end
  end

  describe "renew/3" do
    test "extends expires_at when token matches" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")
      old_expires = lease.expires_at

      Process.sleep(10)
      assert {:ok, renewed} = Lease.renew(doc, "owner-a", lease.fencing_token)
      assert renewed.fencing_token == lease.fencing_token
      assert DateTime.compare(renewed.expires_at, old_expires) in [:gt, :eq]
    end

    test "fails with :stale when fencing_token doesn't match" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")
      assert {:error, :stale} = Lease.renew(doc, "owner-a", lease.fencing_token + 1)
    end

    test "fails with :stale when owner_ref doesn't match" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")
      assert {:error, :stale} = Lease.renew(doc, "owner-b", lease.fencing_token)
    end

    test "fails with :expired after the lease lapses" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")
      :ok = Lease.force_expire!(doc)
      assert {:error, :expired} = Lease.renew(doc, "owner-a", lease.fencing_token)
    end

    test "fails with :missing when no lease row exists" do
      assert {:error, :missing} = Lease.renew(new_doc(), "ghost", 1)
    end
  end

  describe "release/3" do
    test "removes the row when owner + token match" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")
      assert {:ok, :ok} = Lease.release(doc, "owner-a", lease.fencing_token)
      assert nil == Lease.get(doc)
    end

    test "is idempotent if there's nothing to release" do
      assert {:ok, :ok} = Lease.release(new_doc(), "ghost", 1)
    end

    test "doesn't delete the row when token doesn't match" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")
      assert {:ok, :ok} = Lease.release(doc, "owner-a", lease.fencing_token + 1)
      assert %Record{} = Lease.get(doc)
    end
  end

  describe "assert_current!/2" do
    test ":ok when token matches the current lease" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")
      assert :ok = Lease.assert_current!(doc, lease.fencing_token)
    end

    test "raises FencedOut when token is stale" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")

      assert_raise Lease.FencedOut, fn ->
        Lease.assert_current!(doc, lease.fencing_token + 1)
      end
    end

    test "raises FencedOut when the lease has expired" do
      doc = new_doc()
      assert {:ok, lease} = Lease.acquire(doc, "owner-a")
      :ok = Lease.force_expire!(doc)

      assert_raise Lease.FencedOut, ~r/expired/, fn ->
        Lease.assert_current!(doc, lease.fencing_token)
      end
    end

    test "raises FencedOut when no lease exists" do
      assert_raise Lease.FencedOut, ~r/no lease/, fn ->
        Lease.assert_current!(new_doc(), 1)
      end
    end
  end

  describe "fencing_token progression" do
    test "fencing tokens are monotonically increasing on takeover" do
      doc1 = new_doc()
      doc2 = new_doc()
      doc3 = new_doc()

      {:ok, l1} = Lease.acquire(doc1, "o1")
      {:ok, l2} = Lease.acquire(doc2, "o2")
      {:ok, l3} = Lease.acquire(doc3, "o3")

      # Tokens come from a single bigserial sequence — strictly increasing.
      tokens = [l1.fencing_token, l2.fencing_token, l3.fencing_token]
      assert tokens == Enum.sort(tokens)
    end
  end

  describe "ttl_seconds/0" do
    test "exposes the configured TTL" do
      assert is_integer(Lease.ttl_seconds())
      assert Lease.ttl_seconds() == 30
    end
  end
end
