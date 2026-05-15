defmodule Contract.Runtime do
  @moduledoc """
  Routes Actions into the correct execution path
  (Engine/Store, IO import/export, Agent, Session). See SPEC.md §12.
  """

  alias Contract.Types, as: T

  # Opaque until Track A2 lands `Contract.Agent.Run` and `Contract.Export.Job`.
  @type apply_result :: Contract.Change.t() | term()
  @type revoke_result :: Contract.Change.t() | term()

  @spec load(T.ctx(), T.document_id()) :: T.result(Contract.Runtime.State.t())
  def load(_ctx, _document_id), do: raise("Contract.Runtime.load/2 not implemented")

  @spec sync_since(T.ctx(), T.document_id(), T.revision()) ::
          T.result([Contract.Change.t()])
  def sync_since(_ctx, _document_id, _revision),
    do: raise("Contract.Runtime.sync_since/3 not implemented")

  @spec apply(T.ctx(), Contract.Action.t()) :: T.result(apply_result())
  def apply(_ctx, _action), do: raise("Contract.Runtime.apply/2 not implemented")

  @spec revoke(T.ctx(), Contract.Action.t()) :: T.result(revoke_result())
  def revoke(_ctx, _action), do: raise("Contract.Runtime.revoke/2 not implemented")

  @spec subscribe(T.ctx(), T.document_id()) :: T.result(:ok)
  def subscribe(_ctx, _document_id),
    do: raise("Contract.Runtime.subscribe/2 not implemented")

  @spec ensure_session(T.ctx(), T.document_id()) :: T.result(pid())
  def ensure_session(_ctx, _document_id),
    do: raise("Contract.Runtime.ensure_session/2 not implemented")
end
