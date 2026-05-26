defmodule Contract.Session do
  @moduledoc """
  Ephemeral commit coordinator. One GenServer per document. Reconstructable
  from `Contract.Store`. Not truth. See SPEC.md §14, §15.

  ## Lifecycle

    1. `init/1`: acquire lease, hydrate state from `Store.load/1`, subscribe
       to the document's PubSub topic, schedule renew + idle-shutdown
       timers.
    2. `commit/2`: run the Engine pipeline, append via `Store.append/3`
       with the current fencing token, apply the resulting state locally,
       and reply with the persisted change.
    3. `renew/0` (timer): extend the lease every 10s. If the lease has
       been taken over (stale/expired), the GenServer terminates.
    4. `shutdown_if_idle` (timer): if no heartbeat for 5 minutes, release
       the lease and stop normally.

  When the lease is lost (either at renew time or at commit time), the
  Session terminates immediately. The supervisor does *not* auto-restart
  it — a fresh `Runtime.ensure_session/2` will spawn a new Session that
  re-acquires the lease cleanly.
  """

  use GenServer

  require Logger

  alias Contract.Command
  alias Contract.Change
  alias Contract.ChangeInput
  alias Contract.Session.Reducer
  alias Contract.Lease
  alias Contract.Runtime
  alias Contract.Store
  alias Contract.Types, as: T

  @registry Contract.Session.Registry
  @renew_interval_ms 10_000
  @idle_after_ms 5 * 60 * 1000
  @idle_check_interval_ms 60_000

  # ----------------------------------------------------------------------------
  # start_link / via tuple
  # ----------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    document_id = Keyword.fetch!(opts, :document_id)
    name = via(document_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def child_spec(opts) do
    document_id = Keyword.fetch!(opts, :document_id)

    %{
      id: {__MODULE__, document_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Via-tuple for the per-document session in `@registry`."
  @spec via(T.document_id()) :: {:via, Registry, {atom(), T.document_id()}}
  def via(document_id), do: {:via, Registry, {@registry, document_id}}

  @doc "Look up the running session for `document_id`, if any."
  @spec whereis(T.document_id()) :: pid() | nil
  def whereis(document_id) do
    case Registry.lookup(@registry, document_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # ----------------------------------------------------------------------------
  # public API
  # ----------------------------------------------------------------------------

  @spec commit(pid() | T.document_id(), Command.t()) :: T.result(Change.t())
  def commit(target, %Command{} = action) do
    call(target, {:commit, action})
  end

  @spec current(pid() | T.document_id()) :: T.result(Runtime.State.t())
  def current(target), do: call(target, :current)

  @spec sync_since(pid() | T.document_id(), T.revision()) :: T.result([Change.t()])
  def sync_since(target, revision), do: call(target, {:sync_since, revision})

  @spec heartbeat(pid() | T.document_id()) :: :ok
  def heartbeat(target) do
    GenServer.cast(resolve(target), :heartbeat)
    :ok
  end

  @spec shutdown_if_stale(pid() | T.document_id()) :: :ok
  def shutdown_if_stale(target) do
    GenServer.cast(resolve(target), :shutdown_if_stale)
    :ok
  end

  @doc "Test-only inspection of the session's internal state."
  def __get_state__(target), do: call(target, :__get_state__)

  # ----------------------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    document_id = Keyword.fetch!(opts, :document_id)
    owner_ref = Keyword.get(opts, :owner_ref) || default_owner_ref()
    renew_interval = Keyword.get(opts, :renew_interval_ms, @renew_interval_ms)
    idle_after = Keyword.get(opts, :idle_after_ms, @idle_after_ms)
    idle_check_interval = Keyword.get(opts, :idle_check_interval_ms, @idle_check_interval_ms)

    Process.flag(:trap_exit, true)

    with {:ok, lease} <- Lease.acquire(document_id, owner_ref),
         {:ok, state} <- Store.load(document_id) do
      _ = Phoenix.PubSub.subscribe(Contract.PubSub, Store.pubsub_topic(document_id))

      now = DateTime.utc_now()
      schedule_renew(renew_interval)
      schedule_idle_check(idle_check_interval)

      data = %{
        document_id: document_id,
        owner_ref: owner_ref,
        lease: lease,
        state: state,
        last_heartbeat: now,
        renew_interval_ms: renew_interval,
        idle_after_ms: idle_after,
        idle_check_interval_ms: idle_check_interval
      }

      {:ok, data}
    else
      {:error, :held_by_other} -> {:stop, :lease_held}
      {:error, reason} -> {:stop, {:init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:commit, %Command{} = action}, _from, data) do
    case do_commit(action, data) do
      {:ok, change, new_state} ->
        {:reply, {:ok, change}, %{data | state: new_state, last_heartbeat: DateTime.utc_now()}}

      {:fenced_out, reason} ->
        {:stop, {:fenced_out, reason}, {:error, {:fenced_out, reason}}, data}

      {:error, _} = err ->
        {:reply, err, data}
    end
  end

  def handle_call(:current, _from, data) do
    {:reply, {:ok, data.state}, data}
  end

  def handle_call({:sync_since, revision}, _from, data) do
    {:reply, Store.changes_since(data.document_id, revision), data}
  end

  def handle_call(:__get_state__, _from, data) do
    {:reply, data, data}
  end

  @impl true
  def handle_cast(:heartbeat, data) do
    {:noreply, %{data | last_heartbeat: DateTime.utc_now()}}
  end

  def handle_cast(:shutdown_if_stale, data) do
    if idle?(data) do
      _ = Lease.release(data.document_id, data.owner_ref, data.lease.fencing_token)
      {:stop, :normal, data}
    else
      {:noreply, data}
    end
  end

  @impl true
  def handle_info(:renew_lease, data) do
    case Lease.renew(data.document_id, data.owner_ref, data.lease.fencing_token) do
      {:ok, lease} ->
        schedule_renew(data.renew_interval_ms)
        {:noreply, %{data | lease: lease}}

      {:error, reason} when reason in [:stale, :expired, :missing] ->
        broadcast_session_stale(data.document_id)
        {:stop, {:lease_lost, reason}, data}

      {:error, reason} ->
        Logger.warning("Contract.Session: lease renew failed: #{inspect(reason)}")
        schedule_renew(data.renew_interval_ms)
        {:noreply, data}
    end
  end

  def handle_info(:idle_check, data) do
    if idle?(data) do
      _ = Lease.release(data.document_id, data.owner_ref, data.lease.fencing_token)
      {:stop, :normal, data}
    else
      schedule_idle_check(data.idle_check_interval_ms)
      {:noreply, data}
    end
  end

  # PubSub: ignore our own broadcasts (we already applied locally) but
  # accept changes from other writers (shouldn't happen with the lease,
  # but defensive).
  def handle_info({:change_committed, %Change{} = change}, data) do
    if change.result_revision <= data.state.revision do
      {:noreply, data}
    else
      input = Store.change_to_input(change)

      case Reducer.apply(input, data.state) do
        {:ok, new_state} -> {:noreply, %{data | state: new_state}}
        _ -> {:noreply, data}
      end
    end
  end

  def handle_info(_msg, data), do: {:noreply, data}

  @impl true
  def terminate(_reason, _data), do: :ok

  # ----------------------------------------------------------------------------
  # commit internals
  # ----------------------------------------------------------------------------

  defp do_commit(%Command{} = action, %{state: state, document_id: document_id} = data) do
    action = %{action | document_id: action.document_id || document_id}

    # Idempotency short-circuit: a replay of an already-committed action
    # returns the previously persisted Change without re-running the
    # Engine pipeline. SPEC.md §15 invariant 6.
    case action.idempotency_key && Store.previous_result(document_id, action.idempotency_key) do
      {:ok, %Change{} = existing} -> {:ok, existing, state}
      _ -> do_commit_via_engine(action, data)
    end
  end

  defp do_commit_via_engine(%Command{} = action, %{state: state, document_id: document_id} = data) do
    with {:ok, %ChangeInput{} = input} <- Reducer.compile(action, state),
         {:ok, _} <- Reducer.validate(input, state),
         {:ok, preimage} <- Reducer.preimage(input, state),
         {:ok, inverse_ops} <- Reducer.inverse(input, preimage),
         {:ok, affected_refs} <- Reducer.affected_refs(input, state),
         input = %ChangeInput{
           input
           | preimage: preimage,
             inverse_ops: inverse_ops,
             affected_refs: affected_refs
         },
         {:ok, change} <- Reducer.build_change(action, input, state) do
      case Store.append(document_id, change, data.lease.fencing_token) do
        {:ok, persisted} ->
          {:ok, new_state} = Reducer.apply(input, state)
          {:ok, persisted, %{new_state | revision: persisted.result_revision}}

        {:error, {:fenced_out, _, _, _} = reason} ->
          {:fenced_out, reason}

        {:error, _} = err ->
          err
      end
    end
  end

  # ----------------------------------------------------------------------------
  # idle / scheduling
  # ----------------------------------------------------------------------------

  defp idle?(data) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), data.last_heartbeat, :millisecond)
    elapsed_ms > data.idle_after_ms
  end

  defp schedule_renew(interval_ms) do
    Process.send_after(self(), :renew_lease, interval_ms)
  end

  defp schedule_idle_check(interval_ms) do
    Process.send_after(self(), :idle_check, interval_ms)
  end

  defp broadcast_session_stale(document_id) do
    Phoenix.PubSub.broadcast(
      Contract.PubSub,
      Store.pubsub_topic(document_id),
      {:session_stale, document_id}
    )
  end

  # ----------------------------------------------------------------------------
  # target resolution / owner refs
  # ----------------------------------------------------------------------------

  defp call(pid, msg) when is_pid(pid), do: GenServer.call(pid, msg)

  defp call(document_id, msg) when is_binary(document_id),
    do: GenServer.call(via(document_id), msg)

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(document_id) when is_binary(document_id), do: via(document_id)

  defp default_owner_ref do
    hash = :erlang.phash2(self())
    "#{node()}:#{Base.encode16(<<hash::32>>, case: :lower)}"
  end
end
