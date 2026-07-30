defmodule Ecrits.Workspace.TurnTerminalFinalizationTest do
  use ExUnit.Case, async: false

  alias Ecrits.AcpAgent
  alias Ecrits.Workspace.Session

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "ecrits_terminal_finalization_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    on_exit(fn ->
      base
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.each(fn path ->
        case Session.whereis(path) do
          pid when is_pid(pid) ->
            DynamicSupervisor.terminate_child(Ecrits.Workspace.SessionSupervisor, pid)

          nil ->
            :ok
        end
      end)

      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "completed and provider-failed turns finalize without a LiveView", %{base: base} do
    completed = attach_terminal_workspace(base, "completed", script: [{:text_delta, "done"}])
    failed = attach_terminal_workspace(base, "failed", fail_with: "provider failed")

    assert {:ok, %{id: completed_turn}} = Session.send_turn(completed.ws, "complete")
    assert_terminal_finalized(completed, completed_turn)

    assert {:ok, %{id: failed_turn}} = Session.send_turn(failed.ws, "fail")
    assert_terminal_finalized(failed, failed_turn)
  end

  test "explicit cancel and queue-flush cancel each finalize once", %{base: base} do
    terminal =
      attach_terminal_workspace(base, "cancelled",
        wait_for: :release_prompt,
        test_pid: self(),
        script: [{:text_delta, "late"}]
      )

    assert {:ok, %{id: cancelled_turn, status: :running}} =
             Session.send_turn(terminal.ws, "cancel me")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: ^cancelled_turn, status: :cancelled}} =
             Session.cancel(terminal.ws, cancelled_turn)

    assert_terminal_finalized(terminal, cancelled_turn)

    assert {:ok, %{id: flushed_turn, status: :running}} =
             Session.send_turn(terminal.ws, "flush me")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000
    assert {:ok, %{id: queued_turn, status: :queued}} = Session.send_turn(terminal.ws, "next")
    assert {:ok, %{id: ^queued_turn, status: :queued}} = Session.flush_queue(terminal.ws)
    assert_terminal_finalized(terminal, flushed_turn)

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: ^queued_turn, status: :cancelled}} =
             Session.cancel(terminal.ws, queued_turn)

    assert_terminal_finalized(terminal, queued_turn)
  end

  test "an abnormal per-turn task exit finalizes once", %{base: base} do
    terminal =
      attach_terminal_workspace(base, "crashed",
        wait_for: :release_prompt,
        test_pid: self(),
        script: [{:text_delta, "unreachable"}]
      )

    assert {:ok, %{id: turn_id, status: :running}} = Session.send_turn(terminal.ws, "crash")
    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    agent_pid = Ecrits.AcpAgent.Session.whereis(terminal.ws.agent_id)
    %{current: %{task_pid: task_pid, turn_id: ^turn_id}} = :sys.get_state(agent_pid)
    Process.exit(task_pid, :terminal_test_crash)

    assert_terminal_finalized(terminal, turn_id)
  end

  test "an externally killed current turn finalizes once", %{base: base} do
    terminal =
      attach_terminal_workspace(base, "killed",
        wait_for: :release_prompt,
        test_pid: self(),
        script: [{:text_delta, "unreachable"}]
      )

    assert {:ok, %{id: turn_id, status: :running}} = Session.send_turn(terminal.ws, "kill")
    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: queued_turn, status: :queued}} =
             Session.send_turn(terminal.ws, "after kill")

    agent_pid = Ecrits.AcpAgent.Session.whereis(terminal.ws.agent_id)
    open_docs_pid = Process.whereis(Ecrits.Fuse.OpenDocs)

    %{
      acp_client: old_client,
      current: %{task_pid: task_pid, turn_id: ^turn_id}
    } = :sys.get_state(agent_pid)

    assert is_pid(old_client)
    :ok = :sys.suspend(open_docs_pid)

    try do
      Process.exit(task_pid, :kill)

      assert_receive {:agent_event, %{type: :turn_failed, turn_id: ^turn_id, reason: ":killed"}},
                     2_000

      assert %{
               acp_client: nil,
               current: nil,
               terminal_finalization: %{
                 key: {agent_id, instance_id, ^turn_id},
                 mode: :drain
               },
               queue: [%{turn_id: ^queued_turn}]
             } =
               await_agent_state(agent_pid, fn state ->
                 match?(
                   %{
                     acp_client: nil,
                     current: nil,
                     terminal_transition: nil,
                     terminal_finalization: %{
                       key: {_, _, ^turn_id},
                       mode: :drain
                     },
                     queue: [%{turn_id: ^queued_turn}]
                   },
                   state
                 )
               end)

      assert agent_id == terminal.ws.agent_id
      assert instance_id == terminal.instance_id
      refute Process.alive?(old_client)
      refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 100
    after
      :ok = :sys.resume(open_docs_pid)
    end

    assert_terminal_finalized(terminal, turn_id)

    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 2_000
    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: ^queued_turn, status: :cancelled}} =
             Session.cancel(terminal.ws, queued_turn)

    assert_terminal_finalized(terminal, queued_turn)
  end

  test "unsuccessful finalizers keep queued work behind the exact ack until success", %{
    base: base
  } do
    terminal =
      attach_terminal_workspace(base, "completion-barrier", script: [{:text_delta, "done"}])

    agent_pid = Ecrits.AcpAgent.Session.whereis(terminal.ws.agent_id)
    session_pid = Session.whereis(terminal.path)
    open_docs_pid = Process.whereis(Ecrits.Fuse.OpenDocs)
    :ok = :sys.suspend(open_docs_pid)

    {first_turn, queued_turn} =
      try do
        assert {:ok, %{id: first_turn, status: :running}} =
                 Session.send_turn(terminal.ws, "first")

        assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^first_turn}},
                       2_000

        assert {:ok, %{id: queued_turn, status: :queued}} =
                 Session.send_turn(terminal.ws, "queued while finalizing")

        assert %{
                 current: nil,
                 terminal_finalization: %{
                   key: {agent_id, instance_id, ^first_turn},
                   mode: :drain
                 },
                 queue: [%{turn_id: ^queued_turn}]
               } =
                 await_agent_state(agent_pid, fn state ->
                   match?(
                     %{
                       terminal_finalization: %{
                         key: {_agent_id, _instance_id, ^first_turn},
                         mode: :drain
                       },
                       queue: [%{turn_id: ^queued_turn}]
                     },
                     state
                   )
                 end)

        assert agent_id == terminal.ws.agent_id
        assert instance_id == terminal.instance_id

        key = {agent_id, instance_id, first_turn}

        assert %{
                 turn_finalization_state: %{
                   active: %{key: ^key, pid: first_pid, attempts: 1}
                 }
               } =
                 :sys.get_state(session_pid)

        failed_result = %{
          saved: [],
          failed: [{terminal.path, :transient_failure}],
          staged: %{committed: [], pending: []},
          canonical: %{published: [], pending: []}
        }

        pending_result = %{
          saved: [],
          failed: [],
          staged: %{committed: [], pending: [{"contract.hwp", :temporarily_busy}]},
          canonical: %{published: [], pending: [{"contract.hwp", :echo_pending}]}
        }

        successful_result = %{
          saved: [],
          failed: [],
          staged: %{committed: [], pending: []},
          canonical: %{published: [], pending: []}
        }

        send(
          session_pid,
          {:workspace_turn_finalization_finished, key, first_pid, failed_result}
        )

        assert %{
                 turn_finalization_state: %{
                   active: %{key: ^key, pid: second_pid, attempts: 2}
                 }
               } =
                 await_finalizer_attempt(session_pid, key, first_pid, 2)

        assert :pending =
                 Session.notify_turn_terminal(
                   terminal.path,
                   %{agent_id: agent_id, instance_id: instance_id, turn_id: first_turn},
                   self()
                 )

        send(
          session_pid,
          {:workspace_turn_finalization_finished, key, second_pid, pending_result}
        )

        assert %{
                 turn_finalization_state: %{
                   active: nil,
                   finalizations: %{
                     ^key => %{status: :queued, attempts: 2, retry_token: retry_token}
                   },
                   waiters: %{^key => waiters}
                 }
               } = :sys.get_state(session_pid)

        assert MapSet.member?(waiters, agent_pid)
        assert MapSet.member?(waiters, self())

        assert {:ok, :queued} =
                 Session.finalize_turn(terminal.ws, first_turn, instance_id: instance_id)

        refute_receive {:workspace_turn_finalized, %{turn_id: ^first_turn}}, 20
        refute_receive {:workspace_turn_finalization_ack, ^key, _summary}, 20

        assert %{
                 current: nil,
                 terminal_finalization: %{key: ^key, mode: :drain},
                 queue: [%{turn_id: ^queued_turn}]
               } = :sys.get_state(agent_pid)

        refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}},
                       20

        send(session_pid, {:retry_workspace_turn_finalization, key, retry_token})

        assert %{
                 turn_finalization_state: %{
                   active: %{key: ^key, pid: third_pid, attempts: 3}
                 }
               } =
                 await_finalizer_attempt(session_pid, key, second_pid, 3)

        send(
          session_pid,
          {:workspace_turn_finalization_finished, key, third_pid, successful_result}
        )

        assert_receive {:workspace_turn_finalized,
                        %{
                          agent_id: ^agent_id,
                          instance_id: ^instance_id,
                          turn_id: ^first_turn,
                          summary: %{successful?: true} = summary
                        }},
                       2_000

        assert_receive {:workspace_turn_finalization_ack, ^key, ^summary}, 2_000
        assert_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 2_000

        {first_turn, queued_turn}
      after
        :ok = :sys.resume(open_docs_pid)
      end

    assert {:ok, {:completed, %{successful?: true}}} =
             Session.finalize_turn(terminal.ws, first_turn, instance_id: terminal.instance_id)

    refute_receive {:workspace_turn_finalized, %{turn_id: ^first_turn}}, 50
    assert_terminal_finalized(terminal, queued_turn)
  end

  test "normal cancel keeps its queue idle after finalization until an explicit flush", %{
    base: base
  } do
    terminal =
      attach_terminal_workspace(base, "cancel-holds-queue",
        wait_for: :release_prompt,
        test_pid: self(),
        script: [{:text_delta, "late"}]
      )

    assert {:ok, %{id: cancelled_turn, status: :running}} =
             Session.send_turn(terminal.ws, "cancel")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: queued_turn, status: :queued}} =
             Session.send_turn(terminal.ws, "keep queued")

    assert {:ok, %{id: ^cancelled_turn, status: :cancelled}} =
             Session.cancel(terminal.ws, cancelled_turn)

    assert_terminal_finalized(terminal, cancelled_turn)

    agent_pid = Ecrits.AcpAgent.Session.whereis(terminal.ws.agent_id)

    assert %{current: nil, terminal_finalization: nil, queue: [%{turn_id: ^queued_turn}]} =
             :sys.get_state(agent_pid)

    refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 100

    assert {:ok, %{id: ^queued_turn, status: :running}} = Session.flush_queue(terminal.ws)
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 2_000
    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: ^queued_turn, status: :cancelled}} =
             Session.cancel(terminal.ws, queued_turn)

    assert_terminal_finalized(terminal, queued_turn)
  end

  test "normal cancel waits for the exact old task DOWN before finalizing or releasing its queue",
       %{base: base} do
    terminal =
      attach_terminal_workspace(base, "cancel-task-fence",
        wait_for: :release_prompt,
        test_pid: self(),
        script: [{:text_delta, "late"}]
      )

    assert {:ok, %{id: cancelled_turn, status: :running}} =
             Session.send_turn(terminal.ws, "cancel")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: queued_turn, status: :queued}} =
             Session.send_turn(terminal.ws, "keep queued")

    agent_pid = Ecrits.AcpAgent.Session.whereis(terminal.ws.agent_id)
    open_docs_pid = Process.whereis(Ecrits.Fuse.OpenDocs)

    %{current: %{task_pid: old_task_pid, task_ref: old_task_ref}} =
      :sys.get_state(agent_pid)

    :erlang.suspend_process(old_task_pid)
    :ok = :sys.suspend(open_docs_pid)

    timeout_token =
      try do
        assert {:ok, %{id: ^cancelled_turn, status: :cancelled}} =
                 Session.cancel(terminal.ws, cancelled_turn)

        assert %{
                 current: nil,
                 cancellation_fence: %{
                   token: token,
                   task_pid: ^old_task_pid,
                   task_ref: ^old_task_ref,
                   turn_id: ^cancelled_turn,
                   mode: :hold
                 },
                 terminal_finalization: nil,
                 queue: [%{turn_id: ^queued_turn}]
               } = :sys.get_state(agent_pid)

        assert {:ok, %{status: :queued}} = Session.send_turn(terminal.ws, "also queued")
        refute_receive {:workspace_turn_finalized, %{turn_id: ^cancelled_turn}}, 100
        refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 100

        old_task_monitor = Process.monitor(old_task_pid)
        Process.exit(old_task_pid, :kill)
        assert_receive {:DOWN, ^old_task_monitor, :process, ^old_task_pid, :killed}, 2_000

        assert %{
                 cancellation_fence: nil,
                 terminal_finalization: %{
                   key: {agent_id, instance_id, ^cancelled_turn},
                   mode: :hold
                 }
               } =
                 await_agent_state(agent_pid, fn state ->
                   match?(
                     %{
                       cancellation_fence: nil,
                       terminal_finalization: %{key: {_, _, ^cancelled_turn}, mode: :hold}
                     },
                     state
                   )
                 end)

        send(
          agent_pid,
          {:workspace_turn_finalization_ack, {agent_id, instance_id, Ecto.UUID.generate()},
           %{successful?: true}}
        )

        assert %{terminal_finalization: %{key: {^agent_id, ^instance_id, ^cancelled_turn}}} =
                 :sys.get_state(agent_pid)

        refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 100
        token
      after
        if Process.alive?(old_task_pid), do: :erlang.resume_process(old_task_pid)
        :ok = :sys.resume(open_docs_pid)
      end

    assert_terminal_finalized(terminal, cancelled_turn)
    refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 100

    assert {:ok, %{id: ^queued_turn, status: :running}} = Session.flush_queue(terminal.ws)
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 2_000
    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    %{acp_client: new_client} = :sys.get_state(agent_pid)
    assert is_pid(new_client) and Process.alive?(new_client)

    send(agent_pid, {:force_kill_turn, timeout_token, old_task_pid})
    _ = :sys.get_state(agent_pid)

    assert %{acp_client: ^new_client, current: %{turn_id: ^queued_turn}} =
             :sys.get_state(agent_pid)

    assert Process.alive?(new_client)

    assert {:ok, %{id: ^queued_turn, status: :cancelled}} =
             Session.cancel(terminal.ws, queued_turn)

    assert_terminal_finalized(terminal, queued_turn)
  end

  test "flush cancel keeps the queue behind task death and the exact finalization ack", %{
    base: base
  } do
    terminal =
      attach_terminal_workspace(base, "flush-task-fence",
        wait_for: :release_prompt,
        test_pid: self(),
        script: [{:text_delta, "late"}]
      )

    assert {:ok, %{id: cancelled_turn, status: :running}} =
             Session.send_turn(terminal.ws, "cancel")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: queued_turn, status: :queued}} =
             Session.send_turn(terminal.ws, "run after cancellation")

    agent_pid = Ecrits.AcpAgent.Session.whereis(terminal.ws.agent_id)
    open_docs_pid = Process.whereis(Ecrits.Fuse.OpenDocs)
    %{current: %{task_pid: old_task_pid}} = :sys.get_state(agent_pid)

    :erlang.suspend_process(old_task_pid)
    :ok = :sys.suspend(open_docs_pid)

    timeout_token =
      try do
        assert {:ok, %{id: ^queued_turn, status: :queued}} = Session.flush_queue(terminal.ws)

        assert %{
                 current: nil,
                 cancellation_fence: %{
                   token: token,
                   task_pid: ^old_task_pid,
                   turn_id: ^cancelled_turn,
                   mode: :drain
                 },
                 terminal_finalization: nil,
                 queue: [%{turn_id: ^queued_turn}]
               } = :sys.get_state(agent_pid)

        refute_receive {:workspace_turn_finalized, %{turn_id: ^cancelled_turn}}, 100
        refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 100

        old_task_monitor = Process.monitor(old_task_pid)
        Process.exit(old_task_pid, :kill)
        assert_receive {:DOWN, ^old_task_monitor, :process, ^old_task_pid, :killed}, 2_000

        assert %{
                 cancellation_fence: nil,
                 terminal_finalization: %{
                   key: {agent_id, instance_id, ^cancelled_turn},
                   mode: :drain
                 }
               } =
                 await_agent_state(agent_pid, fn state ->
                   match?(
                     %{
                       cancellation_fence: nil,
                       terminal_finalization: %{key: {_, _, ^cancelled_turn}, mode: :drain}
                     },
                     state
                   )
                 end)

        send(
          agent_pid,
          {:workspace_turn_finalization_ack, {agent_id, instance_id, Ecto.UUID.generate()},
           %{successful?: true}}
        )

        assert %{terminal_finalization: %{key: {^agent_id, ^instance_id, ^cancelled_turn}}} =
                 :sys.get_state(agent_pid)

        refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 100
        token
      after
        if Process.alive?(old_task_pid), do: :erlang.resume_process(old_task_pid)
        :ok = :sys.resume(open_docs_pid)
      end

    assert_terminal_finalized(terminal, cancelled_turn)
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn}}, 2_000
    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    %{acp_client: new_client} = :sys.get_state(agent_pid)
    assert is_pid(new_client) and Process.alive?(new_client)

    send(agent_pid, {:force_kill_turn, timeout_token, old_task_pid})
    _ = :sys.get_state(agent_pid)

    assert %{acp_client: ^new_client, current: %{turn_id: ^queued_turn}} =
             :sys.get_state(agent_pid)

    assert Process.alive?(new_client)

    assert {:ok, %{id: ^queued_turn, status: :cancelled}} =
             Session.cancel(terminal.ws, queued_turn)

    assert_terminal_finalized(terminal, queued_turn)
  end

  defp attach_terminal_workspace(base, suffix, adapter_opts) do
    path = Path.join(base, suffix)
    File.mkdir_p!(path)

    {:ok, ws} =
      Session.attach(path,
        provider: "codex",
        adapter_opts:
          [exmcp_adapter: EcritsWeb.FakeAcpAdapter]
          |> Keyword.merge(adapter_opts),
        workspace_root: path
      )

    :ok = Session.subscribe_events(path)
    :ok = Session.subscribe_agent(ws.agent_id)

    %{path: path, ws: ws, instance_id: AcpAgent.agent_snapshot(ws.agent_id).instance_id}
  end

  defp assert_terminal_finalized(terminal, turn_id) do
    path = terminal.path
    agent_id = terminal.ws.agent_id
    instance_id = terminal.instance_id

    assert_receive {:workspace_turn_finalized,
                    %{
                      workspace_path: ^path,
                      agent_id: ^agent_id,
                      instance_id: ^instance_id,
                      turn_id: ^turn_id,
                      summary: %{successful?: true} = summary
                    }},
                   2_000

    assert {:ok, {:completed, ^summary}} =
             Session.finalize_turn(terminal.ws, turn_id, instance_id: instance_id)

    refute_receive {:workspace_turn_finalized, %{turn_id: ^turn_id}}, 50
  end

  defp await_finalizer_attempt(session_pid, key, previous_pid, attempts, remaining \\ 50)

  defp await_finalizer_attempt(_session_pid, _key, _previous_pid, _attempts, 0) do
    flunk("workspace session did not start the expected finalizer attempt")
  end

  defp await_finalizer_attempt(session_pid, key, previous_pid, attempts, remaining) do
    state = :sys.get_state(session_pid)

    case state.turn_finalization_state.active do
      %{key: ^key, pid: pid, attempts: ^attempts} when pid != previous_pid ->
        state

      _other ->
        receive do
        after
          5 ->
            await_finalizer_attempt(session_pid, key, previous_pid, attempts, remaining - 1)
        end
    end
  end

  defp await_agent_state(agent_pid, predicate, attempts \\ 200)

  defp await_agent_state(agent_pid, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(agent_pid)

    if predicate.(state) do
      state
    else
      receive do
      after
        10 -> await_agent_state(agent_pid, predicate, attempts - 1)
      end
    end
  end

  defp await_agent_state(agent_pid, _predicate, 0) do
    flunk(
      "agent state did not reach cancellation terminal barrier: #{inspect(:sys.get_state(agent_pid))}"
    )
  end
end
