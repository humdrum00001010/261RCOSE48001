defmodule Ecrits.Doc.EditSessionTest do
  use ExUnit.Case, async: true

  # The leak guards log a warning when they reap a patch; that is the point of
  # those tests, not output noise.
  @moduletag :capture_log

  alias Ecrits.Doc.EditSession

  @pubsub Ecrits.PubSub

  setup do
    unique = System.unique_integer([:positive])
    edit_id = "edit-#{unique}"
    session_id = "session-#{unique}"

    on_exit(fn -> EditSession.stop(edit_id) end)

    {:ok, edit_id: edit_id, session_id: session_id}
  end

  defp start_patch!(context, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:session_id, context.session_id)
      |> Keyword.put_new(:document_id, "doc-" <> context.edit_id)

    {:ok, pid} = EditSession.start_patch(context.edit_id, opts)
    :ok = EditSession.subscribe(context.edit_id)
    pid
  end

  defp emit(session_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, "agent:" <> session_id, {:agent_event, event})
  end

  defp delta(edit_id, text, extra \\ %{}) do
    Map.merge(%{type: :edit_delta, edit_id: edit_id, delta: text}, extra)
  end

  # `Registry` drops the key when IT processes the worker's DOWN, which races
  # the DOWN this test process received.
  defp assert_unregistered(edit_id, tries \\ 50) do
    cond do
      EditSession.whereis(edit_id) == nil -> :ok
      tries == 0 -> flunk("#{edit_id} stayed registered after its worker stopped")
      true -> Process.sleep(10) && assert_unregistered(edit_id, tries - 1)
    end
  end

  test "starts on the first delta and is idempotent for later observers", context do
    pid = start_patch!(context)

    assert EditSession.whereis(context.edit_id) == pid
    # A second tab (or a re-mount after refresh) observes the SAME process.
    assert {:ok, ^pid} = EditSession.start_patch(context.edit_id, session_id: context.session_id)

    assert {:ok, snapshot} = EditSession.snapshot(context.edit_id)
    assert snapshot.edit_id == context.edit_id
    assert snapshot.status == :accumulating
    assert snapshot.delta == ""
    assert snapshot.event_count == 0
  end

  test "keeps only the events carrying its own edit_id", context do
    start_patch!(context)

    emit(context.session_id, delta("some-other-edit", "FOREIGN"))
    emit(context.session_id, %{type: :text_delta, turn_id: "t1", delta: "narration"})
    emit(context.session_id, delta(context.edit_id, "MINE"))

    # Delivery is FIFO from this process, so if either foreign event had been
    # retained it would already be in the buffer by the time ours lands.
    assert_receive {:doc_edit_patch, snapshot}, 1_000
    assert snapshot.delta == "MINE"
    assert snapshot.event_count == 1
  end

  test "accumulates partial state across deltas", context do
    start_patch!(context)

    emit(context.session_id, delta(context.edit_id, "안녕", %{path: "/ws/.ecrits/mount/a.hwp"}))
    emit(context.session_id, delta(context.edit_id, "하세", %{turn_id: "turn-1"}))
    emit(context.session_id, delta(context.edit_id, "요", %{seq: 7, revision: "rev-2"}))

    assert_receive {:doc_edit_patch, %{event_count: 3} = snapshot}, 1_000
    assert snapshot.delta == "안녕하세요"
    assert snapshot.path == "/ws/.ecrits/mount/a.hwp"
    assert snapshot.turn_id == "turn-1"
    assert snapshot.last_seq == 7
    assert snapshot.revision == "rev-2"
    assert snapshot.status == :accumulating

    assert {:ok, ^snapshot} = EditSession.snapshot(context.edit_id)
  end

  test "terminates on the patch's terminal event", context do
    for terminal <- [:edit_committed, :edit_failed, :edit_rolled_back] do
      edit_id = "#{context.edit_id}-#{terminal}"
      pid = start_patch!(%{context | edit_id: edit_id})
      ref = Process.monitor(pid)

      emit(context.session_id, delta(edit_id, "partial"))
      emit(context.session_id, %{type: terminal, edit_id: edit_id, revision: "rev-final"})

      expected_status = terminal |> Atom.to_string() |> String.replace_prefix("edit_", "")

      assert_receive {:doc_edit_patch, %{status: status, revision: "rev-final"}}, 1_000
      assert Atom.to_string(status) == expected_status

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert_unregistered(edit_id)
      assert EditSession.snapshot(edit_id) == {:error, :not_found}
    end
  end

  test "terminates on a lifecycle phase carried in the payload", context do
    pid = start_patch!(context)
    ref = Process.monitor(pid)

    emit(context.session_id, %{
      type: :vfs_doc_edited,
      edit_id: context.edit_id,
      payload: %{phase: :rejected}
    })

    assert_receive {:doc_edit_patch, %{status: :rejected}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "does not leak when the terminal event never arrives", context do
    pid = start_patch!(context, idle_timeout: 60)
    ref = Process.monitor(pid)

    emit(context.session_id, delta(context.edit_id, "partial"))
    assert_receive {:doc_edit_patch, %{event_count: 1}}, 1_000

    # No terminal event ever comes: the idle guard reaps the worker.
    assert_receive {:doc_edit_patch, %{status: :expired}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert_unregistered(context.edit_id)
  end

  test "does not leak when deltas keep arriving forever", context do
    pid = start_patch!(context, idle_timeout: 10_000, max_lifetime: 60)
    ref = Process.monitor(pid)

    # Chatty enough to keep resetting the idle timer; the absolute ceiling still
    # settles the patch.
    for _ <- 1..5 do
      emit(context.session_id, delta(context.edit_id, "."))
      Process.sleep(20)
    end

    assert_receive {:doc_edit_patch, %{status: :expired}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "a foreign edit_id does not reset the idle guard", context do
    pid = start_patch!(context, idle_timeout: 120)
    ref = Process.monitor(pid)

    for _ <- 1..6 do
      emit(context.session_id, delta("some-other-edit", "FOREIGN"))
      Process.sleep(30)
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  # Coordination: `Ecrits.Agent.Event` is landing on another branch. The worker
  # matches it by struct name, so this asserts the typed path as soon as the
  # struct exists and stays green (as a no-op) until then.
  test "accepts the typed Ecrits.Agent.Event struct", context do
    if Code.ensure_loaded?(Ecrits.Agent.Event) do
      start_patch!(context)

      event =
        struct(Ecrits.Agent.Event,
          type: :edit_delta,
          edit_id: context.edit_id,
          payload: %{delta: "typed"}
        )

      # Both envelopes: the bare struct and today's {:agent_event, _} wrapper.
      Phoenix.PubSub.broadcast(@pubsub, "agent:" <> context.session_id, event)
      emit(context.session_id, event)

      assert_receive {:doc_edit_patch, %{event_count: 2}}, 1_000
    else
      assert EditSession.whereis(context.edit_id) == nil
    end
  end
end
