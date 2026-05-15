defmodule Contract.Lease do
  @moduledoc """
  Current live-writer guard. Prevents duplicated Session processes from
  committing. See SPEC.md §15.

  Track A1 (feat/engine) implements this — `Contract.Lease.Record` lands with
  it. The `leases` migration is already in place.
  """

  alias Contract.Types, as: T

  @type record :: term()

  @spec acquire(T.document_id(), owner_ref :: String.t()) :: T.result(record())
  def acquire(_document_id, _owner_ref),
    do: raise("Contract.Lease.acquire/2 not implemented")

  @spec renew(T.document_id(), owner_ref :: String.t(), fencing_token :: integer()) ::
          T.result(record())
  def renew(_document_id, _owner_ref, _fencing_token),
    do: raise("Contract.Lease.renew/3 not implemented")

  @spec release(T.document_id(), owner_ref :: String.t(), fencing_token :: integer()) ::
          T.result(:ok)
  def release(_document_id, _owner_ref, _fencing_token),
    do: raise("Contract.Lease.release/3 not implemented")

  @spec assert_current!(T.document_id(), fencing_token :: integer()) :: :ok | no_return()
  def assert_current!(_document_id, _fencing_token),
    do: raise("Contract.Lease.assert_current!/2 not implemented")
end
