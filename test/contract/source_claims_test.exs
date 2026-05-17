defmodule Contract.SourceClaimsTest do
  use Contract.DataCase, async: false

  import Contract.AccountsFixtures

  alias Contract.{Command, Repo, SourceClaim, SourceClaims, SourceDocument}

  setup do
    user = user_fixture()
    scope = Contract.Context.for_user(user)

    {:ok, document} = Contract.Documents.create(scope, %{title: "Working draft"})

    {:ok, source_document} =
      %SourceDocument{}
      |> SourceDocument.changeset(%{
        owner_id: user.id,
        document_id: document.id,
        blob_ref_id: Ecto.UUID.generate(),
        status: "ready"
      })
      |> Repo.insert()

    {:ok, claim} =
      %SourceClaim{}
      |> SourceClaim.changeset(%{
        source_document_id: source_document.id,
        region_id: "r-effective-date",
        proposed_kind: "effective_date",
        proposed_value: "2026-01-01",
        confidence: Decimal.new("0.91")
      })
      |> Repo.insert()

    %{
      user: user,
      scope: scope,
      document: document,
      source_document: source_document,
      claim: claim
    }
  end

  test "confirm updates claim state and appends a durable source-claim Change", ctx do
    command = source_command(:source_claim_confirm, ctx, %{"field_id" => "effective_date"})

    assert {:ok, %SourceClaim{} = updated} = SourceClaims.apply_command(ctx.scope, command)
    assert updated.status == "confirmed"
    assert updated.user_value == "2026-01-01"

    {:ok, changes} = Contract.Store.changes_since(ctx.document.id, 0)

    assert [%Contract.Change{command_kind: "source_claim_confirm", source_claim_id: claim_id}] =
             Enum.filter(changes, &(&1.command_kind == "source_claim_confirm"))

    assert claim_id == ctx.claim.id
  end

  test "correct stores the user value and appends a field update Change", ctx do
    command =
      source_command(:source_claim_correct, ctx, %{
        "field_id" => "effective_date",
        "value" => "2026-02-01"
      })

    assert {:ok, updated} = SourceClaims.apply_command(ctx.scope, command)
    assert updated.status == "corrected"
    assert updated.user_value == "2026-02-01"

    {:ok, changes} = Contract.Store.changes_since(ctx.document.id, 0)
    change = Enum.find(changes, &(&1.command_kind == "source_claim_correct"))
    assert change.source_claim_id == ctx.claim.id
    assert [%{"op" => "set_field", "target_id" => "effective_date"}] = change.payload
  end

  test "reject updates claim state without requiring a linked document change", ctx do
    command = source_command(:source_claim_reject, %{ctx | document: nil}, %{"reason" => "wrong"})

    assert {:ok, updated} = SourceClaims.apply_command(ctx.scope, command)
    assert updated.status == "rejected"
    assert updated.user_value == nil
  end

  test "link_to_document links the claim and records a durable reference Change", ctx do
    command =
      source_command(:source_claim_link_to_document, ctx, %{
        "node_id" => "node-effective-date",
        "field_id" => "effective_date"
      })

    assert {:ok, updated} = SourceClaims.apply_command(ctx.scope, command)
    assert updated.status == "linked"
    assert updated.linked_document_id == ctx.document.id
    assert updated.linked_node_id == "node-effective-date"

    {:ok, changes} = Contract.Store.changes_since(ctx.document.id, 0)
    change = Enum.find(changes, &(&1.command_kind == "source_claim_link_to_document"))
    assert change.source_document_id == ctx.source_document.id
    assert change.source_claim_id == ctx.claim.id
    assert [%{"op" => "bind_ref"}] = change.payload
  end

  test "unlink clears linked document state and records the updated claim status", ctx do
    {:ok, linked} =
      ctx.claim
      |> SourceClaim.changeset(%{
        status: "linked",
        linked_document_id: ctx.document.id,
        linked_node_id: "node-effective-date"
      })
      |> Repo.update()

    ctx = %{ctx | claim: linked}
    command = source_command(:source_claim_unlink_from_document, ctx, %{})

    assert {:ok, updated} = SourceClaims.apply_command(ctx.scope, command)
    assert updated.status == "unlinked"
    assert updated.linked_document_id == nil
    assert updated.linked_node_id == nil

    assert Repo.get!(SourceClaim, ctx.claim.id).status == "unlinked"
  end

  test "owner cannot access another owner source claim", ctx do
    other = user_fixture()

    assert {:ok, %SourceClaim{id: claim_id}} = SourceClaims.get(ctx.scope, ctx.claim.id)
    assert claim_id == ctx.claim.id

    assert {:error, :forbidden} =
             SourceClaims.get(Contract.Context.for_user(other), ctx.claim.id)
  end

  defp source_command(kind, ctx, payload) do
    %Command{
      kind: kind,
      actor_type: :user,
      actor_id: ctx.user.id,
      document_id: ctx.document && ctx.document.id,
      source_document_id: ctx.source_document.id,
      source_claim_id: ctx.claim.id,
      base_revision: 0,
      idempotency_key: "claim-#{kind}-#{System.unique_integer([:positive])}",
      payload: payload
    }
  end
end
