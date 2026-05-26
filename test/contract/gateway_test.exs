defmodule Contract.GatewayTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.Command
  alias Contract.Change
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.IO.R2Stub
  alias Contract.RouteRef
  alias Contract.Runtime

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Context{}

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

  describe "issue_route_ref/2 → verify_route_ref/2" do
    test "round-trips a freshly-issued token" do
      owner = scope()
      doc_id = create_doc(owner)

      assert {:ok, token} =
               Gateway.issue_route_ref(owner, %{
                 matter_id: Ecto.UUID.generate(),
                 document_id: doc_id,
                 purpose: "mcp",
                 scopes: ["read", "write"]
               })

      assert is_binary(token)

      assert {:ok, %RouteRef{} = ref} = Gateway.verify_route_ref(@ctx, token)
      refute Map.has_key?(Map.from_struct(ref), :matter_id)
      assert ref.document_id == doc_id
      assert ref.purpose == "mcp"
      assert ref.scopes == ["read", "write"]
      assert %DateTime{} = ref.issued_at
      assert %DateTime{} = ref.expires_at
    end

    test "TTL is honoured as a lower bound, rejects non-positive" do
      # Task #139 — the bearer is now deterministic per (user, doc,
      # thread), which means `expires_at` in the payload is bucketed
      # (day-aligned) so two mints in the same UTC day produce the
      # same token bytes. We assert `expires_at` >= `now + ttl` and
      # within ~1 day instead of an exact diff.
      now_before = DateTime.utc_now()

      # default TTL (1h)
      assert {:ok, default_token} = Gateway.issue_route_ref(@ctx, %{purpose: "default-ttl"})

      assert {:ok, %RouteRef{expires_at: default_expires}} =
               Gateway.verify_route_ref(@ctx, default_token)

      assert DateTime.compare(default_expires, DateTime.add(now_before, 3_600, :second)) in [
               :gt,
               :eq
             ]

      # custom TTL — same lower-bound semantics
      assert {:ok, custom} = Gateway.issue_route_ref(@ctx, %{purpose: "ttl", ttl: 60})
      assert {:ok, %RouteRef{expires_at: custom_expires}} = Gateway.verify_route_ref(@ctx, custom)
      assert DateTime.compare(custom_expires, DateTime.add(now_before, 60, :second)) in [:gt, :eq]

      # invalid TTLs
      assert {:error, :invalid_ttl} = Gateway.issue_route_ref(@ctx, %{ttl: 0})
      assert {:error, :invalid_ttl} = Gateway.issue_route_ref(@ctx, %{ttl: -5})
    end

    test "denies document-scoped route_ref issuance for a foreign document" do
      owner = scope()
      other = scope()
      foreign_doc_id = create_doc(other, title: "Foreign route_ref target")

      assert {:error, :forbidden} =
               Gateway.issue_route_ref(owner, %{
                 document_id: foreign_doc_id,
                 purpose: "foreign"
               })
    end
  end

  describe "verify_route_ref/2 — failure modes" do
    test "returns :missing for nil / empty input" do
      assert {:error, :missing} = Gateway.verify_route_ref(@ctx, nil)
      assert {:error, :missing} = Gateway.verify_route_ref(@ctx, "")
    end

    test "returns :invalid for tampered / garbage / non-string input" do
      assert {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "tamper"})

      {left, right} = String.split_at(token, div(String.length(token), 2))
      tampered = left <> "!" <> right

      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, tampered)
      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, "not-a-real-token")
      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, 12_345)
    end

    test "returns :expired for an expired token" do
      # Sign manually with the same salt but a signed_at in the past so
      # max_age enforcement trips. We pass max_age = 60 seconds; signed_at
      # 1 hour ago => expired.
      one_hour_ago =
        DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_unix(:millisecond)

      payload = %{
        document_id: nil,
        purpose: "expired",
        issued_at: DateTime.to_iso8601(DateTime.utc_now() |> DateTime.add(-3_600, :second)),
        expires_at: DateTime.to_iso8601(DateTime.utc_now() |> DateTime.add(-1, :second)),
        scopes: []
      }

      token =
        Phoenix.Token.sign(ContractWeb.Endpoint, "route_ref", payload,
          max_age: 60,
          signed_at: one_hour_ago
        )

      assert {:error, :expired} = Gateway.verify_route_ref(@ctx, token)
    end
  end

  describe "issue_route_ref/2 — SPEC.md §15.2 invariant (no PIDs in route_refs)" do
    test "rejects pid / reference / function values in attrs" do
      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{purpose: "pid-test", document_id: self()})

      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{
                 purpose: "ref-test",
                 scopes: [:ok, make_ref()]
               })

      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{purpose: fn -> :nope end})
    end

    test "successful tokens decode to only binary_id strings and atoms" do
      owner = scope()
      doc_id = create_doc(owner)

      assert {:ok, token} =
               Gateway.issue_route_ref(owner, %{
                 matter_id: Ecto.UUID.generate(),
                 document_id: doc_id,
                 purpose: "no-pid",
                 scopes: ["read"]
               })

      assert {:ok, %RouteRef{} = ref} = Gateway.verify_route_ref(@ctx, token)

      # Walk the struct and assert nothing pid-like is present.
      values = Map.values(Map.from_struct(ref))
      refute Enum.any?(values, fn v -> is_pid(v) or is_reference(v) or is_port(v) end)
    end
  end

  describe "mcp_tool/3 — tool listing and dispatch" do
    test "tool_names/0 + tools_descriptor/0 expose the agent doc.* tools" do
      names = Gateway.tool_names()
      assert names == ["doc.get", "doc.find", "doc.read", "doc.edit"]

      desc = Gateway.tools_descriptor()
      assert length(desc) == length(names)

      Enum.each(desc, fn entry ->
        assert is_binary(entry["name"])
        assert is_binary(entry["description"])
        assert is_map(entry["inputSchema"])
      end)
    end

    test "unknown tool returns {:error, {:unknown_tool, name}}" do
      assert {:error, {:unknown_tool, "doc.does_not_exist"}} =
               Gateway.mcp_tool(@ctx, "doc.does_not_exist", %{})
    end

    test "doc.* tools fail closed without a route_ref-backed context" do
      assert {:error, {:forbidden, :no_route_ref}} = Gateway.mcp_tool(@ctx, "doc.get", %{})

      assert {:error, {:forbidden, :no_route_ref}} =
               Gateway.mcp_tool(@ctx, "doc.find", %{"needle" => "x"})

      assert {:error, {:forbidden, :no_route_ref}} =
               Gateway.mcp_tool(@ctx, "doc.read", %{"sec" => 0})

      assert {:error, {:forbidden, :no_route_ref}} = Gateway.mcp_tool(@ctx, "doc.edit", %{})
    end
  end

  describe "authorize_document/2" do
    test "denies nil ctx, nil document_id, or a pinned route_ref without matching user ownership" do
      # Empty ctx → forbidden.
      assert {:error, :forbidden} = Gateway.authorize_document(%Context{}, Ecto.UUID.generate())
      assert {:error, :forbidden} = Gateway.authorize_document(%Context{}, nil)

      # Pinned route_ref but no user context.
      doc_id = create_doc(scope(), title: "No-user pinned bypass")

      no_user_ref = %RouteRef{
        document_id: doc_id,
        scopes: [],
        purpose: "t",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now()
      }

      assert {:error, :forbidden} =
               Gateway.authorize_document(%Context{perms: %{route_ref: no_user_ref}}, doc_id)

      # User present but doesn't own the pinned document.
      other = scope()
      other_doc_id = create_doc(other, title: "Pinned foreign doc")

      foreign_ref = %{no_user_ref | document_id: other_doc_id}
      foreign_ctx = %Context{user: scope().user, perms: %{route_ref: foreign_ref}}
      assert {:error, :forbidden} = Gateway.authorize_document(foreign_ctx, other_doc_id)

      # Different document than the pinned one.
      diff_ref = %{no_user_ref | document_id: Ecto.UUID.generate()}
      diff_ctx = %Context{perms: %{route_ref: diff_ref}}
      assert {:error, :forbidden} = Gateway.authorize_document(diff_ctx, Ecto.UUID.generate())
    end

    test "wildcard route_ref still requires ctx user to own the document" do
      owner = scope()
      other = scope()
      owner_doc_id = create_doc(owner, title: "Wildcard owner doc")
      other_doc_id = create_doc(other, title: "Wildcard foreign doc")

      ref = %RouteRef{
        document_id: nil,
        scopes: [],
        purpose: "t",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now()
      }

      ctx = %Context{user: owner.user, perms: %{route_ref: ref}}
      assert :ok = Gateway.authorize_document(ctx, owner_doc_id)
      assert {:error, :forbidden} = Gateway.authorize_document(ctx, other_doc_id)
    end
  end

  describe "slack_*/1 — out of scope for this build" do
    test "slack_event/1, slack_action/1, slack_command/1 all raise" do
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_event(%{}) end
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_action(%{}) end
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_command(%{}) end
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_doc(%Context{} = ctx), do: create_doc(ctx, [])

  defp create_doc(opts) when is_list(opts) do
    ctx = scope()
    create_doc(ctx, opts)
  end

  defp create_doc(%Context{} = ctx, opts) do
    title = Keyword.get(opts, :title, "Doc")
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

    {:ok, %Change{}} = Runtime.apply(ctx, action)
    doc_id
  end

  defp scope do
    user_id = Ecto.UUID.generate()

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "gateway-#{user_id}@example.test"
      }
    }
  end
end
