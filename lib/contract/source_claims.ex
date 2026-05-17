defmodule Contract.SourceClaims do
  @moduledoc """
  Owner-scoped supervision commands for source claims.
  """

  import Ecto.Query

  alias Contract.{
    Command,
    Context,
    Lease,
    Repo,
    Runtime,
    Session,
    SourceClaim,
    SourceDocument,
    Store
  }

  alias Contract.Types, as: T

  @claim_kinds [
    :source_claim_confirm,
    :source_claim_correct,
    :source_claim_reject,
    :source_claim_link_to_document,
    :source_claim_unlink_from_document
  ]

  @spec get(Context.t(), T.source_claim_id()) :: T.result(SourceClaim.t())
  def get(%Context{} = ctx, source_claim_id) when is_binary(source_claim_id) do
    claim = Repo.get(SourceClaim, source_claim_id)

    case claim do
      nil -> {:error, :not_found}
      %SourceClaim{} = claim -> authorize_claim(ctx, claim)
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get(_ctx, _source_claim_id), do: {:error, :not_found}

  @spec list_for_source_document(Context.t(), T.source_document_id()) :: [SourceClaim.t()]
  def list_for_source_document(%Context{} = ctx, source_document_id)
      when is_binary(source_document_id) do
    with {:ok, %SourceDocument{}} <- Contract.SourceDocuments.get(ctx, source_document_id) do
      Repo.all(
        from sc in SourceClaim,
          where: sc.source_document_id == ^source_document_id,
          order_by: [asc: sc.inserted_at]
      )
    else
      _ -> []
    end
  end

  def list_for_source_document(_ctx, _source_document_id), do: []

  @spec apply_command(Context.t(), Command.t()) :: T.result(SourceClaim.t())
  def apply_command(%Context{} = ctx, %Command{kind: kind} = command) when kind in @claim_kinds do
    with {:ok, %SourceClaim{} = claim} <- get(ctx, command.source_claim_id),
         {:ok, %SourceClaim{} = updated} <- update_claim_for_command(claim, command),
         :ok <- maybe_append_change(ctx, updated, command) do
      {:ok, updated}
    end
  end

  def apply_command(_ctx, %Command{kind: kind}),
    do: {:error, {:unsupported_source_claim_kind, kind}}

  defp update_claim_for_command(%SourceClaim{} = claim, %Command{kind: :source_claim_confirm}) do
    claim
    |> SourceClaim.changeset(%{status: "confirmed", user_value: claim.proposed_value})
    |> Repo.update()
  end

  defp update_claim_for_command(
         %SourceClaim{} = claim,
         %Command{kind: :source_claim_correct} = command
       ) do
    value =
      payload_value(command, :value) || payload_value(command, :user_value) ||
        payload_value(command, :corrected_value)

    claim
    |> SourceClaim.changeset(%{status: "corrected", user_value: value})
    |> Repo.update()
  end

  defp update_claim_for_command(%SourceClaim{} = claim, %Command{kind: :source_claim_reject}) do
    claim
    |> SourceClaim.changeset(%{status: "rejected"})
    |> Repo.update()
  end

  defp update_claim_for_command(
         %SourceClaim{} = claim,
         %Command{kind: :source_claim_link_to_document} = command
       ) do
    document_id = command.document_id || payload_value(command, :document_id)
    node_id = payload_value(command, :node_id) || payload_value(command, :linked_node_id)

    claim
    |> SourceClaim.changeset(%{
      status: "linked",
      linked_document_id: document_id,
      linked_node_id: node_id
    })
    |> Repo.update()
  end

  defp update_claim_for_command(%SourceClaim{} = claim, %Command{
         kind: :source_claim_unlink_from_document
       }) do
    claim
    |> SourceClaim.changeset(%{
      status: "unlinked",
      linked_document_id: nil,
      linked_node_id: nil
    })
    |> Repo.update()
  end

  defp maybe_append_change(_ctx, _claim, %Command{document_id: nil}), do: :ok

  defp maybe_append_change(ctx, claim, %Command{} = command) do
    document_id = command.document_id

    with :ok <- Runtime.authorize_document(ctx, document_id),
         {:ok, %Runtime.State{} = state} <- Store.load(document_id),
         {:ok, input} <- Session.Reducer.compile(enrich_command(command, claim), state),
         {:ok, :ok} <- Session.Reducer.validate(input, state),
         {:ok, preimage} <- Session.Reducer.preimage(input, state),
         {:ok, inverse_ops} <- Session.Reducer.inverse(input, preimage),
         {:ok, affected_refs} <- Session.Reducer.affected_refs(input, state),
         input = %{
           input
           | preimage: preimage,
             inverse_ops: inverse_ops,
             affected_refs: affected_refs
         },
         {:ok, change} <-
           Session.Reducer.build_change(enrich_command(command, claim), input, state),
         {:ok, lease} <- Lease.acquire(document_id, "source-claim:#{claim.id}"),
         {:ok, _persisted} <- Store.append(document_id, change, lease.fencing_token) do
      _ = Lease.release(document_id, "source-claim:#{claim.id}", lease.fencing_token)
      :ok
    else
      {:error, _} = err -> err
    end
  end

  defp enrich_command(%Command{} = command, %SourceClaim{} = claim) do
    payload = command.payload || %{}

    payload =
      payload
      |> Map.put_new("value", claim.user_value || claim.proposed_value)
      |> Map.put_new("field_id", claim.proposed_kind)
      |> Map.put_new("proposed_value", claim.proposed_value)
      |> Map.put_new("status", claim.status)

    %Command{
      command
      | source_document_id: command.source_document_id || claim.source_document_id,
        payload: payload
    }
  end

  defp authorize_claim(%Context{user: %{id: owner_id}}, %SourceClaim{} = claim) do
    source_document = Repo.get(SourceDocument, claim.source_document_id)

    case source_document do
      %SourceDocument{owner_id: ^owner_id} -> {:ok, claim}
      %SourceDocument{} -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  defp authorize_claim(%Context{}, %SourceClaim{}), do: {:error, :forbidden}

  defp payload_value(%Command{payload: payload}, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end
end
