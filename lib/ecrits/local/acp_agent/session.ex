defmodule Ecrits.Local.AcpAgent.Session do
  @moduledoc """
  One local chat-agent session, driven directly by `ExMCP.ACP.Client`.

  This is the *sole* chat-agent producer: there is no bespoke provider driver or
  safety-net fallback. The GenServer owns one ACP client per turn, selecting the
  concrete ex_mcp ACP adapter per provider (`ExMCP.ACP.Adapters.Codex` /
  `Claude`), translates the agent's streamed `session/update` notifications into
  the normalized chat-rail events, and broadcasts them on
  `local_agent:<session_id>` (the contract the workspace LiveView consumes).

  The session passes the `doc.*` MCP server to `new_session(..., mcp_servers:)`
  so the agent (codex AND claude, over ACP) discovers and calls those tools; the
  resulting `tool_call` / `tool_call_update` updates render in the chat-rail
  tool_call block.

  ## Per-turn lifecycle

      start ExMCP.ACP.Client -> new_session(cwd, mcp_servers)
        -> prompt (async, blocking on the client) -> session/update* (streamed)
        -> prompt result (stopReason) -> disconnect client

  Cancellation kills the streaming task; its `Stream.resource` cleanup issues the
  ACP cancel (`turn/interrupt` for codex) and disconnects the client, which
  terminates the agent subprocess.
  """

  use GenServer

  require Logger

  alias Ecrits.Context
  alias Ecrits.Local.AcpAgent.AcpStream

  @registry Ecrits.Local.AcpAgent.SessionRegistry
  @pubsub Ecrits.PubSub

  # ── public API ────────────────────────────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def via(id), do: {:via, Registry, {@registry, id}}

  def whereis(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def whereis(_id), do: nil

  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def send_turn(pid, ctx, input, opts \\ []), do: GenServer.call(pid, {:send_turn, ctx, input, opts})
  def cancel(pid, ctx, turn_id \\ nil), do: GenServer.call(pid, {:cancel, ctx, turn_id})

  @doc """
  Updates this live session's turn parameters (access/approval mode, reasoning
  effort, same-provider model) WITHOUT recreating the session, so the chat
  conversation is preserved. The merged `adapter_opts` (and `mcp_servers`) are
  picked up by the next turn.

  This is the in-process equivalent of issuing `session/set_mode` /
  `session/set_config_option` on the ACP client: the ACP session + client are
  created fresh per turn (see `AcpStream`), so a "live" change is just the
  stored per-turn options the next turn starts from — which is exactly what the
  Codex/Claude ACP adapters do with those requests ("stored for next turn").
  """
  def update_options(pid, adapter_opts) when is_list(adapter_opts) do
    GenServer.call(pid, {:update_options, adapter_opts})
  end

  def topic(id), do: "local_agent:" <> id

  # ── GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       owner_id: owner_id(Keyword.get(opts, :ctx)),
       provider: Keyword.get(opts, :provider),
       exmcp_adapter: Keyword.fetch!(opts, :exmcp_adapter),
       adapter_opts: Keyword.get(opts, :adapter_opts, []),
       workspace_root: Keyword.get(opts, :workspace_root),
       document_id: Keyword.get(opts, :document_id),
       mcp_servers: Keyword.get(opts, :mcp_servers, []),
       current: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, public_snapshot(state)}, state}
  end

  def handle_call({:update_options, new_opts}, _from, state) do
    merged = Keyword.merge(state.adapter_opts, new_opts)
    {:reply, :ok, %{state | adapter_opts: merged}}
  end

  def handle_call({:send_turn, ctx, input, _opts}, _from, state) do
    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      state.current != nil ->
        {:reply, {:error, :turn_in_progress}, state}

      true ->
        turn_id = Ecto.UUID.generate()
        parent = self()

        task =
          Task.async(fn ->
            run_turn(parent, turn_id, input, state)
          end)

        Process.unlink(task.pid)

        state = %{state | current: %{turn_id: turn_id, task_ref: task.ref, task_pid: task.pid, text: ""}}
        state = emit(state, %{type: :turn_started, turn_id: turn_id, input: input})

        {:reply, {:ok, %{id: turn_id, session_id: state.id, status: :running}}, state}
    end
  end

  def handle_call({:cancel, ctx, turn_id}, _from, state) do
    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      state.current == nil ->
        {:reply, {:error, :no_current_turn}, state}

      not is_nil(turn_id) and state.current.turn_id != turn_id ->
        {:reply, {:error, :not_found}, state}

      true ->
        if state.current.task_pid, do: Process.exit(state.current.task_pid, :kill)
        cancelled_turn_id = state.current.turn_id

        state =
          state
          |> emit(%{type: :turn_cancelled, turn_id: cancelled_turn_id})
          |> Map.put(:current, nil)

        {:reply, {:ok, %{id: cancelled_turn_id, session_id: state.id, status: :cancelled}}, state}
    end
  end

  @impl true
  def handle_info({:turn_event, turn_id, event}, state) do
    with %{turn_id: ^turn_id} <- state.current do
      {:noreply, handle_turn_event(state, turn_id, event)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:turn_done, turn_id}, state) do
    with %{turn_id: ^turn_id} = current <- state.current do
      state =
        state
        |> emit(%{type: :turn_completed, turn_id: turn_id, text: current.text})
        |> Map.put(:current, nil)

      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:turn_failed, turn_id, reason}, state) do
    with %{turn_id: ^turn_id} <- state.current do
      state =
        state
        |> emit(%{type: :turn_failed, turn_id: turn_id, reason: inspect(reason)})
        |> Map.put(:current, nil)

      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current: %{task_ref: ref, turn_id: turn_id}} = state)
      when reason not in [:normal, :killed] do
    state =
      state
      |> emit(%{type: :turn_failed, turn_id: turn_id, reason: inspect(reason)})
      |> Map.put(:current, nil)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── turn streaming (in a Task) ─────────────────────────────────────

  defp run_turn(parent, turn_id, input, state) do
    stream =
      AcpStream.turn_stream(
        state.exmcp_adapter,
        %{
          input: input,
          workspace_root: state.workspace_root,
          document_id: state.document_id
        },
        Keyword.put(state.adapter_opts, :mcp_servers, state.mcp_servers)
      )

    Enum.each(stream, fn event -> send(parent, {:turn_event, turn_id, event}) end)
    send(parent, {:turn_done, turn_id})
  rescue
    e -> send(parent, {:turn_failed, turn_id, {:exception, Exception.message(e)}})
  end

  # ── event mapping -> chat-rail events ──────────────────────────────

  defp handle_turn_event(state, turn_id, %{type: :text_delta, delta: delta}) when is_binary(delta) do
    current = %{state.current | text: (state.current.text || "") <> delta}

    state
    |> Map.put(:current, current)
    |> emit(%{type: :text_delta, turn_id: turn_id, delta: delta})
  end

  defp handle_turn_event(state, turn_id, %{type: :reasoning_delta, delta: delta}) when is_binary(delta) do
    emit(state, %{type: :reasoning_delta, turn_id: turn_id, delta: delta})
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_started} = event) do
    emit(state, %{
      type: :tool_call_started,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      arguments: Map.get(event, :arguments, %{})
    })
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_completed} = event) do
    emit(state, %{
      type: :tool_call_completed,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      result: Map.get(event, :result, %{})
    })
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_failed} = event) do
    emit(state, %{
      type: :tool_call_failed,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      reason: Map.get(event, :reason, "")
    })
  end

  defp handle_turn_event(state, _turn_id, _event), do: state

  # ── helpers ────────────────────────────────────────────────────────

  defp public_snapshot(state) do
    %{
      id: state.id,
      owner_id: state.owner_id,
      provider: state.provider,
      document_id: state.document_id,
      workspace_root: state.workspace_root,
      current_turn: state.current && %{id: state.current.turn_id, status: :running}
    }
  end

  defp emit(state, event) do
    event =
      event
      |> Map.put(:session_id, state.id)
      |> Map.put(:at, DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601())

    Phoenix.PubSub.broadcast(@pubsub, topic(state.id), {:local_agent_event, event})
    state
  end

  defp authorized?(ctx, %{owner_id: nil}), do: is_nil(owner_id(ctx))
  defp authorized?(ctx, %{owner_id: owner_id}), do: owner_id(ctx) == owner_id

  defp owner_id(%Context{user: %{id: id}}) when is_binary(id), do: id
  defp owner_id(_ctx), do: nil
end
