defmodule Contract.Store do
  @moduledoc """
  Durable truth. Commit order lives here — not in LiveView, not in Agent,
  not in Session alone. See SPEC.md §16.
  """

  alias Contract.Types, as: T

  @spec load(T.document_id()) :: T.result(Contract.Runtime.State.t())
  def load(_document_id), do: raise("Contract.Store.load/1 not implemented")

  @spec snapshot(T.document_id(), T.revision()) :: T.result(Contract.Runtime.State.t())
  def snapshot(_document_id, _revision),
    do: raise("Contract.Store.snapshot/2 not implemented")

  @spec append(T.document_id(), Contract.Change.t(), fencing_token :: integer()) ::
          T.result(Contract.Change.t())
  def append(_document_id, _change, _fencing_token),
    do: raise("Contract.Store.append/3 not implemented")

  @spec changes_since(T.document_id(), T.revision()) :: T.result([Contract.Change.t()])
  def changes_since(_document_id, _revision),
    do: raise("Contract.Store.changes_since/2 not implemented")

  @spec latest_revision(T.document_id()) :: T.result(T.revision())
  def latest_revision(_document_id),
    do: raise("Contract.Store.latest_revision/1 not implemented")

  @spec idempotency_seen?(T.document_id(), T.idempotency_key()) :: boolean()
  def idempotency_seen?(_document_id, _idempotency_key),
    do: raise("Contract.Store.idempotency_seen?/2 not implemented")

  @spec previous_result(T.document_id(), T.idempotency_key()) :: T.result(Contract.Change.t())
  def previous_result(_document_id, _idempotency_key),
    do: raise("Contract.Store.previous_result/2 not implemented")

  @spec transaction((-> T.result(term()))) :: T.result(term())
  def transaction(_fun), do: raise("Contract.Store.transaction/1 not implemented")
end
