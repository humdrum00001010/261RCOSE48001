defmodule Contract.MattersTest do
  use Contract.DataCase, async: true

  alias Contract.Context
  alias Contract.Matters
  alias Contract.Matters.Matter

  defp scope(opts \\ []) do
    tenant =
      case Keyword.get(opts, :tenant, :auto) do
        :auto -> Ecto.UUID.generate()
        nil -> nil
        explicit -> explicit
      end

    user_id = Keyword.get(opts, :user_id, Ecto.UUID.generate())

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "u#{System.unique_integer([:positive])}@x"
      },
      tenant: tenant
    }
  end

  describe "create/2" do
    test "creates a matter owned by the scope user" do
      s = scope()

      assert {:ok, %Matter{name: "M1", owner_id: owner, tenant_id: tenant}} =
               Matters.create(s, %{"name" => "M1"})

      assert owner == s.user.id
      assert tenant == s.tenant
    end

    test "without a user is :forbidden" do
      assert {:error, :forbidden} =
               Matters.create(%Context{tenant: "t"}, %{"name" => "x"})
    end

    test "returns changeset on missing required" do
      assert {:error, %Ecto.Changeset{}} = Matters.create(scope(), %{})
    end
  end

  describe "list_for_scope/1" do
    test "returns owner's active matters, filters archived + cross-tenant" do
      a = scope()
      b = scope()

      {:ok, m1} = Matters.create(a, %{"name" => "A"})
      {:ok, m2} = Matters.create(a, %{"name" => "B"})
      {:ok, archived} = Matters.create(a, %{"name" => "to_archive"})
      {:ok, _} = Matters.archive(a, archived.id)
      {:ok, foreign} = Matters.create(b, %{"name" => "B's"})

      a_ids = a |> Matters.list_for_scope() |> Enum.map(& &1.id)

      # Active matters visible.
      assert m1.id in a_ids
      assert m2.id in a_ids
      # Archived filtered out.
      refute archived.id in a_ids
      # Cross-tenant matters invisible.
      refute foreign.id in a_ids
    end

    # SPEC.md Document-primary pivot (2026-05-15): matters with
    # `metadata.hidden_from_user = true` (system-created Workspaces
    # auto-synthesized on Document creation) are filtered out of the
    # default user view. They remain in the table — fetchable via
    # `get/2` and visible via `include_hidden: true` — they just don't
    # surface in casual UI.
    test "excludes system_created matters with hidden_from_user metadata" do
      s = scope()

      {:ok, visible} = Matters.create(s, %{"name" => "User-picked"})

      {:ok, hidden} =
        Matters.create(s, %{
          "name" => "Workspace · auto",
          "metadata" => %{
            "system_created" => true,
            "hidden_from_user" => true,
            "source" => "auto_on_document_create"
          }
        })

      ids = s |> Matters.list_for_scope() |> Enum.map(& &1.id)
      assert visible.id in ids
      refute hidden.id in ids
    end

    test "include_hidden: true returns auto-matters too" do
      s = scope()

      {:ok, hidden} =
        Matters.create(s, %{
          "name" => "Workspace · auto",
          "metadata" => %{
            "system_created" => true,
            "hidden_from_user" => true
          }
        })

      ids = s |> Matters.list_for_scope(include_hidden: true) |> Enum.map(& &1.id)
      assert hidden.id in ids
    end

    test "tenant-nil matters are visible to any scope" do
      a = scope()

      {:ok, m} =
        Matters.create(a, %{"name" => "single-tenant", "tenant_id" => nil})

      # Re-read via Repo to confirm tenant_id is nil
      reloaded = Contract.Repo.get!(Matter, m.id)
      assert reloaded.tenant_id == nil

      b = scope()
      ids_b = b |> Matters.list_for_scope() |> Enum.map(& &1.id)
      assert m.id in ids_b
    end
  end

  describe "get/2" do
    test "fetches owned matter; rejects unknown id, malformed uuid, and cross-tenant" do
      a = scope()
      b = scope()
      {:ok, m} = Matters.create(a, %{"name" => "g"})

      # Owner can fetch.
      assert {:ok, %Matter{id: id}} = Matters.get(a, m.id)
      assert id == m.id

      # Unknown id → :not_found.
      assert {:error, :not_found} = Matters.get(a, Ecto.UUID.generate())

      # Malformed uuid → :not_found.
      assert {:error, :not_found} = Matters.get(a, "not-a-uuid")

      # Cross-tenant → :forbidden.
      assert {:error, :forbidden} = Matters.get(b, m.id)
    end
  end

  describe "archive/2" do
    test "owner can archive" do
      s = scope()
      {:ok, m} = Matters.create(s, %{"name" => "to-arch"})
      assert {:ok, %Matter{status: :archived}} = Matters.archive(s, m.id)
    end

    test "non-owner cannot archive even within tenant" do
      tenant = Ecto.UUID.generate()
      owner = scope(tenant: tenant)
      other = scope(tenant: tenant)
      {:ok, m} = Matters.create(owner, %{"name" => "x"})

      assert {:error, :forbidden} = Matters.archive(other, m.id)
    end
  end
end
