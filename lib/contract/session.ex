defmodule Contract.Session do
  @moduledoc """
  Ephemeral coordinator. Reconstructable. Not truth. See SPEC.md §14.

  Track A1 (feat/engine) implements the full session flow (acquire lease,
  hydrate from Store, renew, accept fenced commits, broadcast, shutdown if
  stale). For now this is a minimal `GenServer` skeleton that only stores
  `:document_id` so `Contract.Runtime.ensure_session/2` has something to
  return a pid for.
  """

  use GenServer

  alias Contract.Types, as: T

  @spec start_link(document_id: T.document_id()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %{document_id: Keyword.fetch!(opts, :document_id)}
    {:ok, state}
  end

  @spec commit(pid() | T.document_id(), Contract.Action.t()) ::
          T.result(Contract.Change.t())
  def commit(_session_or_document_id, _action),
    do: raise("Contract.Session.commit/2 not implemented")

  @spec revoke(pid() | T.document_id(), Contract.Action.t()) ::
          T.result(Contract.Change.t() | term())
  def revoke(_session_or_document_id, _action),
    do: raise("Contract.Session.revoke/2 not implemented")

  @spec current(pid() | T.document_id()) :: T.result(Contract.Runtime.State.t())
  def current(_session_or_document_id),
    do: raise("Contract.Session.current/1 not implemented")

  @spec sync_since(pid() | T.document_id(), T.revision()) ::
          T.result([Contract.Change.t()])
  def sync_since(_session_or_document_id, _revision),
    do: raise("Contract.Session.sync_since/2 not implemented")

  @spec heartbeat(pid()) :: T.result(:ok)
  def heartbeat(_pid), do: raise("Contract.Session.heartbeat/1 not implemented")

  @spec shutdown_if_stale(pid()) :: T.result(:ok)
  def shutdown_if_stale(_pid),
    do: raise("Contract.Session.shutdown_if_stale/1 not implemented")
end
