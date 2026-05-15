defmodule Contract.Studio do
  @moduledoc """
  Product façade for the one big LiveView. Orchestrates load, select, submit,
  sync, subscribe. See SPEC.md §8.
  """

  alias Contract.Types, as: T

  @spec load(T.ctx(), T.params()) :: T.result(Contract.Studio.State.t())
  def load(_ctx, _params), do: raise("Contract.Studio.load/2 not implemented")

  @spec reload(T.ctx(), Contract.Studio.State.t()) :: T.result(Contract.Studio.State.t())
  def reload(_ctx, _state), do: raise("Contract.Studio.reload/2 not implemented")

  @spec select_document(T.ctx(), Contract.Studio.State.t(), T.document_id()) ::
          T.result(Contract.Studio.State.t())
  def select_document(_ctx, _state, _document_id),
    do: raise("Contract.Studio.select_document/3 not implemented")

  @spec submit(T.ctx(), Contract.Studio.State.t(), Contract.Action.t()) ::
          T.result(Contract.Studio.State.t())
  def submit(_ctx, _state, _action),
    do: raise("Contract.Studio.submit/3 not implemented")

  @spec sync(T.ctx(), Contract.Studio.State.t(), T.revision()) ::
          T.result(Contract.Studio.State.t())
  def sync(_ctx, _state, _from_revision),
    do: raise("Contract.Studio.sync/3 not implemented")

  @spec subscribe(T.ctx(), Contract.Studio.State.t()) :: T.result(:ok)
  def subscribe(_ctx, _state), do: raise("Contract.Studio.subscribe/2 not implemented")
end
