defmodule Contract.EvidenceSnapshots do
  @moduledoc """
  Owner-scoped persistence for immutable legal evidence snapshots.
  """

  import Ecto.Query

  alias Contract.{Context, EvidenceSnapshot, Repo}

  @type capture_result :: {:ok, EvidenceSnapshot.t() | nil} | {:error, term()}

  @spec capture(Context.t() | nil, String.t(), map(), term(), keyword()) :: capture_result()
  def capture(%Context{user: %{id: owner_id}} = ctx, provider, query, result, opts)
      when is_binary(provider) and is_map(query) do
    result = normalize_result(result)
    result_hash = result_hash(provider, query, result)

    attrs = %{
      owner_id: owner_id,
      provider: provider,
      query: query,
      result: result,
      result_hash: result_hash,
      captured_at: captured_at(ctx),
      chat_thread_id: Keyword.get(opts, :chat_thread_id),
      document_id: Keyword.get(opts, :document_id),
      source_document_id: Keyword.get(opts, :source_document_id)
    }

    changeset = EvidenceSnapshot.changeset(%EvidenceSnapshot{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:result_hash, :owner_id]
         ) do
      {:ok, %EvidenceSnapshot{id: nil}} ->
        {:ok, Repo.get_by(EvidenceSnapshot, owner_id: owner_id, result_hash: result_hash)}

      {:ok, %EvidenceSnapshot{} = snapshot} ->
        {:ok, snapshot}

      {:error, _} = error ->
        error
    end
  end

  def capture(_ctx, _provider, _query, _result, _opts), do: {:ok, nil}

  @spec get(Context.t(), Ecto.UUID.t()) ::
          {:ok, EvidenceSnapshot.t()} | {:error, :not_found | :forbidden}
  def get(%Context{user: %{id: owner_id}}, id) when is_binary(id) do
    case Repo.get(EvidenceSnapshot, id) do
      nil -> {:error, :not_found}
      %EvidenceSnapshot{owner_id: ^owner_id} = snapshot -> {:ok, snapshot}
      %EvidenceSnapshot{} -> {:error, :forbidden}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get(_ctx, _id), do: {:error, :forbidden}

  @spec list_for_document(Context.t(), Ecto.UUID.t()) :: [EvidenceSnapshot.t()]
  def list_for_document(%Context{user: %{id: owner_id}}, document_id)
      when is_binary(document_id) do
    from(e in EvidenceSnapshot,
      where: e.owner_id == ^owner_id and e.document_id == ^document_id,
      order_by: [desc: e.captured_at, desc: e.inserted_at]
    )
    |> Repo.all()
  end

  def list_for_document(_ctx, _document_id), do: []

  defp normalize_result(items) when is_list(items), do: %{"items" => items}
  defp normalize_result(result) when is_map(result), do: result
  defp normalize_result(result), do: %{"value" => result}

  defp result_hash(provider, query, result) do
    :crypto.hash(:sha256, :erlang.term_to_binary({provider, query, result}))
    |> Base.encode16(case: :lower)
  end

  defp captured_at(%Context{now: %DateTime{} = now}), do: DateTime.truncate(now, :second)
  defp captured_at(_ctx), do: DateTime.utc_now() |> DateTime.truncate(:second)
end
