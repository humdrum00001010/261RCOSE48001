defmodule Ecrits.Workspace.TurnFinalizerTest do
  use ExUnit.Case, async: false

  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.Workspace.Session
  alias Ecrits.Workspace.TurnFinalizer

  setup do
    previous_runtime = Application.get_env(:ehwp, :runtime)

    base =
      Path.join(
        System.tmp_dir!(),
        "ecrits_turn_finalizer_#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(base, "workspace")
    other_workspace = Path.join(base, "other")
    File.mkdir_p!(workspace)
    File.mkdir_p!(other_workspace)

    on_exit(fn ->
      if previous_runtime do
        Application.put_env(:ehwp, :runtime, previous_runtime)
      else
        Application.delete_env(:ehwp, :runtime)
      end

      File.rm_rf(base)
    end)

    {:ok, workspace: workspace, other_workspace: other_workspace}
  end

  test "Session serializes distinct terminals and retains bounded summaries only", %{
    workspace: workspace
  } do
    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    # Suspending OpenDocs parks the finalizer inside its canonical flush
    # (`reclaim_dead_canonical_echoes` is an unconditional call into it), which
    # is how these tests observe a finalization that is still RUNNING.
    open_docs_pid = Process.whereis(OpenDocs)
    instance_id = Session.snapshot(ws).instance_id
    assert is_pid(session_pid)
    assert is_pid(open_docs_pid)
    :ok = Session.subscribe_events(workspace)

    on_exit(fn ->
      if Process.alive?(session_pid) do
        DynamicSupervisor.terminate_child(Ecrits.Workspace.SessionSupervisor, session_pid)
      end
    end)

    :ok = :sys.suspend(open_docs_pid)

    try do
      assert {:ok, :started} =
               Session.finalize_turn(ws, "terminal-a", instance_id: instance_id)

      assert {:ok, :running} =
               Session.finalize_turn(ws, "terminal-a", instance_id: instance_id)

      assert {:ok, :queued} =
               Session.finalize_turn(ws, "terminal-b", instance_id: instance_id)

      state = :sys.get_state(session_pid)

      assert %{
               key: {agent_id, ^instance_id, "terminal-a"},
               pid: active_pid,
               ref: active_ref
             } = state.turn_finalization_state.active

      assert agent_id == ws.agent_id
      assert is_pid(active_pid)
      assert is_reference(active_ref)

      assert state.turn_finalization_state.queue == [
               {ws.agent_id, instance_id, "terminal-b"}
             ]

      assert %{status: :running} =
               state.turn_finalization_state.finalizations[
                 {ws.agent_id, instance_id, "terminal-a"}
               ]

      assert %{status: :queued} =
               state.turn_finalization_state.finalizations[
                 {ws.agent_id, instance_id, "terminal-b"}
               ]
    after
      :ok = :sys.resume(open_docs_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: agent_id,
                      instance_id: ^instance_id,
                      turn_id: "terminal-a",
                      summary: summary_a
                    }},
                   2_000

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^agent_id,
                      instance_id: ^instance_id,
                      turn_id: "terminal-b",
                      summary: summary_b
                    }},
                   2_000

    assert agent_id == ws.agent_id
    assert summary_a.successful?
    assert summary_b.successful?

    state = :sys.get_state(session_pid)
    assert state.turn_finalization_state.active == nil
    assert state.turn_finalization_state.queue == []

    assert %{status: :completed, summary: ^summary_a} =
             state.turn_finalization_state.finalizations[{agent_id, instance_id, "terminal-a"}]

    assert %{status: :completed, summary: ^summary_b} =
             state.turn_finalization_state.finalizations[{agent_id, instance_id, "terminal-b"}]

    refute Map.has_key?(
             state.turn_finalization_state.finalizations[
               {agent_id, instance_id, "terminal-a"}
             ],
             :result
           )

    refute Map.has_key?(
             state.turn_finalization_state.finalizations[
               {agent_id, instance_id, "terminal-b"}
             ],
             :result
           )

    assert {:ok, {:completed, ^summary_a}} =
             Session.finalize_turn(ws, "terminal-a", instance_id: instance_id)

    assert {:ok, {:completed, ^summary_b}} =
             Session.finalize_turn(ws, "terminal-b", instance_id: instance_id)

    assert {:error, :unknown_agent} =
             Session.finalize_turn(%{ws | agent_id: "unknown-agent"}, "terminal-c",
               instance_id: instance_id
             )

    refute_receive {:workspace_turn_finalized, %{agent_id: ^agent_id}}, 100
  end

  test "Session retries an uncatchably killed finalizer before completing the turn", %{
    workspace: workspace
  } do
    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    open_docs_pid = Process.whereis(OpenDocs)
    instance_id = Session.snapshot(ws).instance_id
    agent_id = ws.agent_id
    :ok = Session.subscribe_events(workspace)

    on_exit(fn ->
      if Process.alive?(session_pid) do
        DynamicSupervisor.terminate_child(Ecrits.Workspace.SessionSupervisor, session_pid)
      end
    end)

    :ok = :sys.suspend(open_docs_pid)

    try do
      assert {:ok, :started} =
               Session.finalize_turn(ws, "retry-killed", instance_id: instance_id)

      assert %{turn_finalization_state: %{active: %{pid: first_pid, attempts: 1}}} =
               :sys.get_state(session_pid)

      monitor_ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^first_pid, :killed}

      assert %{
               turn_finalization_state: %{
                 active: %{pid: second_pid, attempts: 2},
                 finalizations: %{
                   {^agent_id, ^instance_id, "retry-killed"} => %{
                     status: :running,
                     attempts: 2
                   }
                 }
               }
             } = await_retried_finalizer(session_pid, first_pid)

      refute second_pid == first_pid
    after
      :ok = :sys.resume(open_docs_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      instance_id: ^instance_id,
                      turn_id: "retry-killed",
                      summary: %{successful?: true}
                    }},
                   2_000

    refute_receive {:workspace_turn_finalized, %{turn_id: "retry-killed"}}, 100
  end

  test "Session keeps an unsuccessful result fenced until a later attempt succeeds", %{
    workspace: workspace
  } do
    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    open_docs_pid = Process.whereis(OpenDocs)
    instance_id = Session.snapshot(ws).instance_id
    agent_id = ws.agent_id
    key = {agent_id, instance_id, "retry-result"}
    :ok = Session.subscribe_events(workspace)

    failed_result = %{
      saved: [],
      failed: [{workspace, :transient_failure}],
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

    :ok = :sys.suspend(open_docs_pid)

    try do
      assert {:ok, :started} =
               Session.finalize_turn(ws, "retry-result", instance_id: instance_id)

      assert %{turn_finalization_state: %{active: %{pid: first_pid, attempts: 1}}} =
               :sys.get_state(session_pid)

      send(
        session_pid,
        {:workspace_turn_finalization_finished, key, first_pid, failed_result}
      )

      assert %{
               turn_finalization_state: %{
                 active: %{pid: second_pid, attempts: 2},
                 finalizations: %{
                   ^key => %{status: :running, attempts: 2}
                 }
               }
             } = await_retried_finalizer(session_pid, first_pid)

      refute second_pid == first_pid
      refute_receive {:workspace_turn_finalized, %{turn_id: "retry-result"}}, 100

      send(
        session_pid,
        {:workspace_turn_finalization_finished, key, second_pid, pending_result}
      )

      assert %{
               turn_finalization_state: %{
                 active: nil,
                 finalizations: %{
                   ^key => %{
                     status: :queued,
                     attempts: 2,
                     retry_token: retry_token
                   }
                 }
               }
             } = :sys.get_state(session_pid)

      assert is_reference(retry_token)

      assert {:ok, :queued} =
               Session.finalize_turn(ws, "retry-result", instance_id: instance_id)

      refute_receive {:workspace_turn_finalized, %{turn_id: "retry-result"}}, 20

      send(session_pid, {:retry_workspace_turn_finalization, key, retry_token})

      assert %{
               turn_finalization_state: %{
                 active: %{pid: third_pid, attempts: 3},
                 finalizations: %{
                   ^key => %{status: :running, attempts: 3}
                 }
               }
             } = await_retried_finalizer(session_pid, second_pid, 3)

      send(
        session_pid,
        {:workspace_turn_finalization_finished, key, third_pid, successful_result}
      )

      assert_receive {:workspace_turn_finalized,
                      %{
                        agent_id: ^agent_id,
                        instance_id: ^instance_id,
                        turn_id: "retry-result",
                        summary: %{successful?: true}
                      }},
                     2_000

      assert %{
               turn_finalization_state: %{
                 active: nil,
                 finalizations: %{
                   ^key => %{status: :completed, summary: %{successful?: true}}
                 }
               }
             } = :sys.get_state(session_pid)
    after
      :ok = :sys.resume(open_docs_pid)
    end

    refute_receive {:workspace_turn_finalized, %{turn_id: "retry-result"}}, 100
  end

  test "Session discards unsafe legacy pair-key finalization state on hot reload", %{
    workspace: workspace
  } do
    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    open_docs_pid = Process.whereis(OpenDocs)
    instance_id = Session.snapshot(ws).instance_id
    agent_id = ws.agent_id
    :ok = Session.subscribe_events(workspace)
    legacy_key = {agent_id, "legacy-turn"}
    new_key = {agent_id, instance_id, "post-upgrade-turn"}

    legacy_worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    legacy_monitor = Process.monitor(legacy_worker)

    :sys.replace_state(session_pid, fn state ->
      state
      |> Map.delete(:turn_finalization_state)
      |> Map.put(:turn_finalizations, %{legacy_key => %{status: :running, attempts: 1}})
      |> Map.put(:turn_finalization_order, [legacy_key])
      |> Map.put(:turn_finalization_queue, [legacy_key])
      |> Map.put(:turn_finalization_waiters, %{legacy_key => MapSet.new([self()])})
      |> Map.put(:turn_finalization_active, %{
        key: legacy_key,
        pid: legacy_worker,
        ref: make_ref(),
        attempts: 1
      })
    end)

    :ok = :sys.suspend(open_docs_pid)

    try do
      assert {:ok, :started} =
               Session.finalize_turn(ws, "post-upgrade-turn", instance_id: instance_id)

      assert_receive {:DOWN, ^legacy_monitor, :process, ^legacy_worker, :killed}, 2_000

      state = :sys.get_state(session_pid)
      refute Map.has_key?(state.turn_finalization_state.finalizations, legacy_key)
      refute Map.has_key?(state.turn_finalization_state.waiters, legacy_key)
      refute legacy_key in state.turn_finalization_state.order
      refute legacy_key in state.turn_finalization_state.queue
      assert %{key: ^new_key, attempts: 1} = state.turn_finalization_state.active
    after
      :ok = :sys.resume(open_docs_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^agent_id,
                      instance_id: ^instance_id,
                      turn_id: "post-upgrade-turn",
                      summary: %{successful?: true}
                    }},
                   2_000
  end

  defp await_retried_finalizer(
         session_pid,
         previous_pid,
         expected_attempts \\ 2,
         remaining \\ 50
       )

  defp await_retried_finalizer(_session_pid, _previous_pid, _expected_attempts, 0),
    do: flunk("workspace session did not start the finalizer retry")

  defp await_retried_finalizer(session_pid, previous_pid, expected_attempts, remaining) do
    state = :sys.get_state(session_pid)

    case state.turn_finalization_state.active do
      %{pid: pid, attempts: ^expected_attempts} when pid != previous_pid ->
        state

      _other ->
        receive do
        after
          5 ->
            await_retried_finalizer(
              session_pid,
              previous_pid,
              expected_attempts,
              remaining - 1
            )
        end
    end
  end

  test "a turn with nothing staged finalizes successfully and saves nothing", %{
    workspace: workspace
  } do
    # `saved` is structurally empty now: native saving was the server-Editor arm,
    # and a document's unsaved edits live in the viewer.
    assert %{
             saved: [],
             failed: [],
             staged: %{committed: [], rejected: [], pending: []},
             canonical: %{published: [], pending: []}
           } = TurnFinalizer.run(workspace, agent_id: "a", instance_id: "i", turn_id: "t")
  end
end
