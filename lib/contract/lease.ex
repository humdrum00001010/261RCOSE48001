defmodule Contract.Lease do
  @moduledoc """
  Current live-writer guard. Prevents duplicated `Contract.Session` processes
  from committing. See SPEC.md §15.

  ## Model

  Each document has at most one row in the `leases` table. The row carries:

    * `:document_id` — primary key.
    * `:owner_ref` — opaque string identifying the holder (typically
      `"<node>:<phash>"`).
    * `:fencing_token` — `bigserial` issued by Postgres. Monotonically
      increases on every successful acquire/renew that bumps the token.
    * `:expires_at` — wall-clock TTL. After this passes, another acquirer
      may take the lease.

  Sessions renew every `@renew_interval_ms`. The current TTL is
  `@ttl_seconds` seconds. `assert_current!/2` is the cheap server-side
  check that `Contract.Store.append/3` performs inside the commit
  transaction.

  ## Errors

  `assert_current!/2` raises `Contract.Lease.FencedOut` when the supplied
  fencing token is stale or the lease has expired. Callers (the Store)
  catch this inside their transaction and turn it into a structured
  `{:error, {:fenced_out, current, supplied}}`.
  """

  import Ecto.Query, only: [from: 2]

  alias Contract.Lease.Record
  alias Contract.Repo
  alias Contract.Types, as: T

  @ttl_seconds 30

  defmodule FencedOut do
    @moduledoc """
    Raised by `Contract.Lease.assert_current!/2` when the supplied fencing
    token is stale or the lease has expired. Callers should catch this
    inside a Repo transaction to roll back any pending write.
    """
    defexception [:document_id, :supplied_token, :current_token, :expires_at, :reason]

    @impl true
    def message(%{document_id: doc_id, reason: :stale, supplied_token: s, current_token: c}) do
      "lease for document #{inspect(doc_id)} is held by a newer writer " <>
        "(supplied token=#{inspect(s)}, current token=#{inspect(c)})"
    end

    def message(%{document_id: doc_id, reason: :expired, expires_at: exp}) do
      "lease for document #{inspect(doc_id)} expired at #{inspect(exp)}"
    end

    def message(%{document_id: doc_id, reason: :missing}) do
      "no lease exists for document #{inspect(doc_id)}"
    end
  end

  @doc "TTL applied to fresh acquires/renews, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  # ----------------------------------------------------------------------------
  # acquire/2
  # ----------------------------------------------------------------------------

  @doc """
  Try to acquire the lease for `document_id` under `owner_ref`.

  Succeeds when:
    * no lease exists yet — a fresh row is inserted, or
    * the existing lease has expired (`expires_at < now()`) — the row is
      taken over with a new owner_ref and a bumped fencing_token, or
    * the existing lease is held by the *same* `owner_ref` — the row is
      refreshed (this makes `acquire/2` idempotent for the current holder).

  Returns `{:error, :held_by_other}` when an unexpired lease is held by a
  different `owner_ref`.
  """
  @spec acquire(T.document_id(), String.t()) :: T.result(Record.t())
  def acquire(document_id, owner_ref) when is_binary(owner_ref) do
    sql = """
    INSERT INTO leases (document_id, owner_ref, expires_at)
    VALUES ($1::uuid, $2, now() + ($3 || ' seconds')::interval)
    ON CONFLICT (document_id) DO UPDATE
      SET owner_ref     = EXCLUDED.owner_ref,
          fencing_token = nextval('leases_fencing_token_seq'),
          expires_at    = EXCLUDED.expires_at
      WHERE leases.expires_at < now()
         OR leases.owner_ref = EXCLUDED.owner_ref
    RETURNING document_id, owner_ref, fencing_token, expires_at
    """

    case Repo.query(sql, [
           Ecto.UUID.dump!(document_id),
           owner_ref,
           Integer.to_string(@ttl_seconds)
         ]) do
      {:ok, %{rows: [row], num_rows: 1}} ->
        {:ok, row_to_record(row)}

      {:ok, %{num_rows: 0}} ->
        {:error, :held_by_other}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ----------------------------------------------------------------------------
  # renew/3
  # ----------------------------------------------------------------------------

  @doc """
  Extend the lease for `document_id` if and only if the row still has the
  supplied `fencing_token` and `owner_ref`. Does *not* bump the fencing
  token — renew is the heartbeat path, not a takeover.

  Returns `{:error, :stale}` if the token no longer matches (someone else
  took the lease) or `{:error, :expired}` if the lease has already lapsed
  past its TTL.
  """
  @spec renew(T.document_id(), String.t(), integer()) :: T.result(Record.t())
  def renew(document_id, owner_ref, fencing_token)
      when is_binary(owner_ref) and is_integer(fencing_token) do
    sql = """
    UPDATE leases
       SET expires_at = now() + ($4 || ' seconds')::interval
     WHERE document_id = $1::uuid
       AND owner_ref = $2
       AND fencing_token = $3
       AND expires_at >= now()
    RETURNING document_id, owner_ref, fencing_token, expires_at
    """

    case Repo.query(sql, [
           Ecto.UUID.dump!(document_id),
           owner_ref,
           fencing_token,
           Integer.to_string(@ttl_seconds)
         ]) do
      {:ok, %{rows: [row], num_rows: 1}} ->
        {:ok, row_to_record(row)}

      {:ok, %{num_rows: 0}} ->
        diagnose_renew_failure(document_id, owner_ref, fencing_token)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp diagnose_renew_failure(document_id, owner_ref, fencing_token) do
    case Repo.get(Record, document_id) do
      nil ->
        {:error, :missing}

      %Record{} = rec ->
        cond do
          rec.fencing_token != fencing_token -> {:error, :stale}
          rec.owner_ref != owner_ref -> {:error, :stale}
          DateTime.compare(rec.expires_at, DateTime.utc_now()) == :lt -> {:error, :expired}
          true -> {:error, :unknown}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # release/3
  # ----------------------------------------------------------------------------

  @doc """
  Release the lease iff it is currently held by `owner_ref` with the given
  fencing token. The row is deleted on success. Returns `:ok` even when
  the lease no longer matches (idempotent release — caller is shutting
  down anyway).
  """
  @spec release(T.document_id(), String.t(), integer()) :: T.result(:ok)
  def release(document_id, owner_ref, fencing_token)
      when is_binary(owner_ref) and is_integer(fencing_token) do
    sql = """
    DELETE FROM leases
     WHERE document_id = $1::uuid
       AND owner_ref = $2
       AND fencing_token = $3
    """

    case Repo.query(sql, [Ecto.UUID.dump!(document_id), owner_ref, fencing_token]) do
      {:ok, _} -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
    end
  end

  # ----------------------------------------------------------------------------
  # assert_current!/2
  # ----------------------------------------------------------------------------

  @doc """
  Raise `Contract.Lease.FencedOut` unless the lease row for `document_id`
  matches the supplied `fencing_token` and is still in its TTL.

  Designed to be called *inside* a `Contract.Store.append/3` transaction,
  immediately after taking the advisory lock — so that any takeover
  between session-state inspection and commit causes the entire commit to
  roll back.
  """
  @spec assert_current!(T.document_id(), integer()) :: :ok | no_return()
  def assert_current!(document_id, fencing_token) when is_integer(fencing_token) do
    query =
      from l in Record,
        where: l.document_id == ^document_id,
        select: %{
          fencing_token: l.fencing_token,
          expires_at: l.expires_at,
          owner_ref: l.owner_ref
        }

    case Repo.one(query) do
      nil ->
        raise FencedOut,
          document_id: document_id,
          supplied_token: fencing_token,
          current_token: nil,
          reason: :missing

      %{fencing_token: current, expires_at: expires_at} ->
        cond do
          current != fencing_token ->
            raise FencedOut,
              document_id: document_id,
              supplied_token: fencing_token,
              current_token: current,
              reason: :stale

          DateTime.compare(expires_at, DateTime.utc_now()) == :lt ->
            raise FencedOut,
              document_id: document_id,
              supplied_token: fencing_token,
              current_token: current,
              expires_at: expires_at,
              reason: :expired

          true ->
            :ok
        end
    end
  end

  # ----------------------------------------------------------------------------
  # helpers
  # ----------------------------------------------------------------------------

  @doc """
  Look up the current lease record for a document. Returns `nil` if none
  exists. Used by tests and by `Session` for diagnostic logging.
  """
  @spec get(T.document_id()) :: Record.t() | nil
  def get(document_id) do
    Repo.get(Record, document_id)
  end

  @doc """
  Forcefully expire a lease row (test helper). Sets `expires_at` to one
  second ago. Used by lease-loss concurrency tests; production code never
  calls this.
  """
  @spec force_expire!(T.document_id()) :: :ok
  def force_expire!(document_id) do
    sql = """
    UPDATE leases
       SET expires_at = now() - interval '1 second'
     WHERE document_id = $1::uuid
    """

    {:ok, _} = Repo.query(sql, [Ecto.UUID.dump!(document_id)])
    :ok
  end

  defp row_to_record([doc_id_bin, owner_ref, fencing_token, expires_at])
       when is_binary(doc_id_bin) do
    {:ok, doc_id} = Ecto.UUID.cast(doc_id_bin)

    %Record{
      document_id: doc_id,
      owner_ref: owner_ref,
      fencing_token: fencing_token,
      expires_at: normalize_dt(expires_at)
    }
  end

  defp normalize_dt(%DateTime{} = dt), do: dt

  defp normalize_dt(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end
end
