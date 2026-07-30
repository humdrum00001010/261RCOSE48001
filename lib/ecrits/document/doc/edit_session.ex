defmodule Ecrits.Doc.EditSession do
  @moduledoc """
  One supervised process per in-flight document patch (`edit_id`).

  Layer 1.5 of the DocLang migration plan
  (`docs/plans/2026-07-26-doclang-engine-migration.md`). It owns a single patch's
  accumulated partial state so that neither the chat LiveView nor
  `Ecrits.AcpAgent.Session` has to carry per-patch buffers.

  This is a domain process, **not** a nested LiveView. Its lifetime is bound to
  the PATCH, not to a socket: it survives a browser refresh, and N tabs observe
  the same process instead of each spawning their own. A LiveView reads the
  current state with `snapshot/1` on mount and follows `subscribe/1` after that.

  It persists nothing. `Ecrits.AcpAgent.Session` already persisted the event
  before broadcasting it; this process is a pure in-memory accumulator.

  ## Lifecycle

    * started on the first delta for an `edit_id` (`start_patch/2`, idempotent);
    * subscribes to the agent topic `"agent:" <> session_id` and keeps ONLY the
      events whose `edit_id` is its own — foreign events are dropped without
      even resetting the idle timer;
    * stops on the patch's terminal event (committed / failed / rejected /
      rolled back / cancelled);
    * stops anyway on an idle or absolute-lifetime timeout, so a patch whose
      terminal event never arrives cannot leak a process.

  Restart is `:temporary`. A crashed patch worker has lost the only copy of its
  partial state and cannot rebuild it, so restarting it would only resurrect an
  empty process for a patch nobody is feeding any more.
  """

  import Ecrits.Guards

  use GenServer, restart: :temporary

  require Logger

  @registry Ecrits.Doc.EditSessionRegistry
  @pubsub Ecrits.PubSub

  # The typed event both the ACP and VFS streams normalize into. Held as a bare
  # module atom (matched via `__struct__`) rather than a `%Ecrits.Agent.Event{}`
  # struct pattern, so this module compiles and runs while that struct is still
  # landing and while untyped event maps are still on the wire.
  @event_struct Ecrits.Agent.Event

  # Terminal patch outcomes. `type` names may carry an `edit_`/`patch_` prefix
  # (`:edit_committed`) or arrive as the lifecycle `phase` on the payload.
  @terminal_statuses [:committed, :failed, :rejected, :rolled_back, :cancelled]

  # Mirrors the ACP turn budget (idle-based, with an absolute ceiling): a long
  # active patch keeps living, a silent one is reaped.
  @idle_timeout :timer.minutes(5)
  @max_lifetime :timer.minutes(20)

  @type snapshot :: %{
          edit_id: String.t(),
          session_id: String.t() | nil,
          document_id: String.t() | nil,
          turn_id: String.t() | nil,
          path: String.t() | nil,
          status: atom(),
          delta: String.t(),
          payload: term(),
          last_event_type: term(),
          event_count: non_neg_integer(),
          last_seq: term(),
          base_revision: term(),
          revision: term(),
          started_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  ## Client API

  @doc """
  Get-or-start the worker for `edit_id`. Call this on the first delta.

  Idempotent by design: several observers may race on the same first delta, and
  a re-attaching browser must find the process that is already running.

  Options:

    * `:session_id` — agent session whose topic to follow (required to receive
      anything over PubSub; `nil` leaves the worker unsubscribed);
    * `:document_id`, `:turn_id`, `:path` — patch metadata seeds;
    * `:idle_timeout` / `:max_lifetime` — leak guards, in milliseconds;
    * `:terminal_types` — extra event types to treat as terminal;
    * `:pubsub` — PubSub server (defaults to `Ecrits.PubSub`).
  """
  @spec start_patch(String.t(), keyword() | String.t() | nil) ::
          {:ok, pid()} | {:error, term()}
  def start_patch(edit_id, opts \\ [])

  def start_patch(edit_id, document_id) when is_binary(document_id),
    do: start_patch(edit_id, document_id: document_id)

  def start_patch(edit_id, nil), do: start_patch(edit_id, [])

  def start_patch(edit_id, opts) when is_present(edit_id) and is_list(opts) do
    case Ecrits.Doc.EditSessionSupervisor.start_patch(Keyword.put(opts, :edit_id, edit_id)) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  catch
    # The DynamicSupervisor is a recent addition to the supervision tree; a
    # long-running node that has not been restarted since does not have it.
    # A missing patch worker degrades the card, it must never take down the
    # agent session that was only trying to start one.
    :exit, reason -> {:error, {:supervisor_unavailable, reason}}
  end

  def start_patch(_edit_id, _opts), do: {:error, :invalid_edit_id}

  @doc "Pid of the worker owning `edit_id`, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(edit_id) when is_binary(edit_id) do
    case Registry.lookup(@registry, edit_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  rescue
    # Same "node predates this part of the supervision tree" case `start_patch/2`
    # guards below — but a missing Registry *raises* out of `Registry.lookup/2`
    # rather than exiting, so `catch :exit` does not cover it. This is called
    # from `Session.ensure_patch_worker/2` while handling `:vfs_doc_edited`, so
    # an uncaught raise here kills the agent session mid-turn and the edit that
    # triggered it is lost to `:turn_invalidated`. Absent registry == no worker.
    ArgumentError -> nil
  end

  @doc "Current accumulated state of the patch, for a (re)mounting view."
  @spec snapshot(String.t() | pid()) :: {:ok, snapshot()} | {:error, :not_found}
  def snapshot(edit_id) when is_binary(edit_id) do
    case whereis(edit_id) do
      nil -> {:error, :not_found}
      pid -> snapshot(pid)
    end
  end

  def snapshot(pid) when is_pid(pid) do
    {:ok, GenServer.call(pid, :snapshot)}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @doc """
  Current state of every live patch worker, oldest patch first.

  This is the RECOVERY read, not a replay: a browser refresh replaces the socket
  but not the patch, so a (re)mounting rail asks the live processes what the
  state IS rather than reconstructing it from the events that produced it.
  """
  @spec snapshots() :: [snapshot()]
  def snapshots do
    @registry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn pid ->
      case snapshot(pid) do
        {:ok, snapshot} -> [snapshot]
        {:error, :not_found} -> []
      end
    end)
    |> Enum.sort_by(& &1.started_at, DateTime)
  rescue
    # Registry not started (node predates this supervision-tree child).
    ArgumentError -> []
  end

  @doc "Live patch snapshots belonging to one agent session, oldest first."
  @spec snapshots_for_session(String.t() | nil) :: [snapshot()]
  def snapshots_for_session(session_id) when is_present(session_id),
    do: Enum.filter(snapshots(), &(&1.session_id == session_id))

  def snapshots_for_session(_session_id), do: []

  @doc "PubSub topic this patch broadcasts its accumulated state on."
  @spec topic(String.t()) :: String.t()
  def topic(edit_id) when is_binary(edit_id), do: "doc_edit:" <> edit_id

  @doc "Follow a patch. Delivers `{:doc_edit_patch, snapshot}` on every update."
  @spec subscribe(String.t(), atom()) :: :ok | {:error, term()}
  def subscribe(edit_id, pubsub \\ @pubsub),
    do: Phoenix.PubSub.subscribe(pubsub, topic(edit_id))

  @spec unsubscribe(String.t(), atom()) :: :ok
  def unsubscribe(edit_id, pubsub \\ @pubsub),
    do: Phoenix.PubSub.unsubscribe(pubsub, topic(edit_id))

  @doc "Stop a patch worker early (e.g. the owning turn was cancelled)."
  @spec stop(String.t() | pid()) :: :ok
  def stop(edit_id) when is_binary(edit_id) do
    case whereis(edit_id) do
      nil -> :ok
      pid -> stop(pid)
    end
  end

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  def start_link(opts) do
    edit_id = Keyword.fetch!(opts, :edit_id)
    GenServer.start_link(__MODULE__, opts, name: via(edit_id))
  end

  @doc false
  def via(edit_id), do: {:via, Registry, {@registry, edit_id}}

  ## Server

  @impl true
  def init(opts) do
    now = DateTime.utc_now()
    pubsub = Keyword.get(opts, :pubsub, @pubsub)
    session_id = Keyword.get(opts, :session_id)

    # The producer side of this topic is `Ecrits.AcpAgent.Session.emit/2`. The
    # literal is duplicated rather than called so this worker does not compile
    # against a module the agent layer is actively reshaping.
    if is_present(session_id) do
      Phoenix.PubSub.subscribe(pubsub, "agent:" <> session_id)
    end

    state = %{
      edit_id: Keyword.fetch!(opts, :edit_id),
      session_id: session_id,
      document_id: Keyword.get(opts, :document_id),
      turn_id: Keyword.get(opts, :turn_id),
      path: Keyword.get(opts, :path),
      pubsub: pubsub,
      status: :accumulating,
      delta: "",
      payload: nil,
      last_event_type: nil,
      event_count: 0,
      last_seq: nil,
      base_revision: nil,
      revision: nil,
      started_at: now,
      updated_at: now,
      idle_timeout: Keyword.get(opts, :idle_timeout, @idle_timeout),
      idle_timer: nil,
      idle_epoch: 0,
      terminal_types: opts |> Keyword.get(:terminal_types, []) |> MapSet.new()
    }

    Process.send_after(self(), {:edit_session_expired, :max_lifetime}, max_lifetime(opts))

    {:ok, arm_idle_timer(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  @impl true
  def handle_info({:edit_session_idle, epoch}, %{idle_epoch: epoch} = state),
    do: expire(state, :idle_timeout)

  def handle_info({:edit_session_idle, _stale_epoch}, state), do: {:noreply, state}

  def handle_info({:edit_session_expired, reason}, state), do: expire(state, reason)

  def handle_info(message, state) do
    with {:ok, event} <- normalize(message),
         true <- mine?(event, state.edit_id) do
      state |> apply_event(event) |> publish() |> continue_or_stop(event)
    else
      # Not an agent event, or another patch's event. Dropped WITHOUT touching
      # the idle timer: a chatty session must not keep a dead patch alive.
      _other -> {:noreply, state}
    end
  end

  ## Event intake

  # The wire may be a bare struct, or `{:agent_event, event}` as
  # `Ecrits.AcpAgent.Session.emit/2` broadcasts it today.
  defp normalize({:agent_event, event}), do: normalize(event)
  defp normalize(%{__struct__: @event_struct} = event), do: {:ok, event}

  defp normalize(%{} = event) do
    # Untyped legacy maps and other lifecycle structs: keep anything that can
    # name a patch at all, and let `mine?/2` do the filtering.
    if is_nil(field(event, :edit_id)), do: :error, else: {:ok, event}
  end

  defp normalize(_message), do: :error

  defp mine?(event, edit_id), do: field(event, :edit_id) == edit_id

  defp apply_event(state, event) do
    state
    |> Map.merge(%{
      document_id: field(event, :document_id) || state.document_id,
      turn_id: field(event, :turn_id) || state.turn_id,
      path: field(event, :path) || state.path,
      base_revision: field(event, :base_revision) || state.base_revision,
      revision: field(event, :revision) || state.revision,
      last_seq: field(event, :seq) || field(event, :event_seq) || state.last_seq,
      last_event_type: field(event, :type) || state.last_event_type,
      payload: field(event, :payload) || state.payload,
      delta: state.delta <> delta_of(event),
      status: status_of(state, event),
      event_count: state.event_count + 1,
      updated_at: DateTime.utc_now()
    })
    |> arm_idle_timer()
  end

  # `Ecrits.Agent.Event` carries the chunk on `payload`; the untyped ACP maps
  # put it at the top level.
  defp delta_of(event) do
    case field(event, :delta) || event |> field(:payload) |> field(:delta) do
      delta when is_binary(delta) -> delta
      _other -> ""
    end
  end

  defp status_of(state, event), do: outcome(event) || state.status

  defp continue_or_stop(state, event) do
    cond do
      state.status in @terminal_statuses -> {:stop, :normal, state}
      MapSet.member?(state.terminal_types, field(event, :type)) -> {:stop, :normal, state}
      true -> {:noreply, state}
    end
  end

  # A terminal outcome may ride the event `type` (`:edit_committed`), a
  # lifecycle `phase` (`Ecrits.Doc.EditLifecycleEvent`), or the typed event's
  # `payload.phase`. Any of the three settles the patch.
  defp outcome(event) do
    Enum.find_value(
      [
        field(event, :type),
        field(event, :phase),
        event |> field(:payload) |> field(:phase),
        event |> field(:payload) |> field(:status)
      ],
      &terminal_status/1
    )
  end

  defp terminal_status(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> terminal_status()

  defp terminal_status(value) when is_binary(value) do
    normalized =
      value
      |> String.replace_prefix("edit_", "")
      |> String.replace_prefix("patch_", "")

    Enum.find(@terminal_statuses, &(Atom.to_string(&1) == normalized))
  end

  defp terminal_status(_value), do: nil

  defp field(nil, _key), do: nil

  defp field(%{} = map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil

  ## Output

  defp publish(state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      topic(state.edit_id),
      {:doc_edit_patch, snapshot_of(state)}
    )

    state
  end

  defp snapshot_of(state) do
    Map.take(state, [
      :edit_id,
      :session_id,
      :document_id,
      :turn_id,
      :path,
      :status,
      :delta,
      :payload,
      :last_event_type,
      :event_count,
      :last_seq,
      :base_revision,
      :revision,
      :started_at,
      :updated_at
    ])
  end

  ## Leak guards

  defp expire(state, reason) do
    Logger.warning(
      "doc edit patch #{inspect(state.edit_id)} expired (#{reason}) after " <>
        "#{state.event_count} event(s) without a terminal event"
    )

    state = %{state | status: :expired, updated_at: DateTime.utc_now()}
    {:stop, :normal, publish(state)}
  end

  # Epoch-tagged so a timer message already in flight when the patch moved on is
  # recognised as stale (`cancel_timer` cannot recall a delivered message).
  defp arm_idle_timer(%{idle_timeout: timeout} = state) when is_integer(timeout) do
    if is_reference(state.idle_timer), do: Process.cancel_timer(state.idle_timer)
    epoch = state.idle_epoch + 1
    timer = Process.send_after(self(), {:edit_session_idle, epoch}, timeout)
    %{state | idle_timer: timer, idle_epoch: epoch}
  end

  defp arm_idle_timer(state), do: state

  defp max_lifetime(opts) do
    case Keyword.get(opts, :max_lifetime, @max_lifetime) do
      lifetime when is_integer(lifetime) and lifetime > 0 -> lifetime
      _other -> @max_lifetime
    end
  end
end
