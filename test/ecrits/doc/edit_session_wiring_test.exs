defmodule Ecrits.Doc.EditSessionWiringTest do
  @moduledoc """
  The live wiring of Layer 1.5 (`docs/plans/2026-07-26-doclang-engine-migration.md`).

  `Ecrits.Doc.EditSessionTest` covers the worker in isolation, driving it by
  broadcasting onto the agent topic by hand. THIS file covers the thing that
  makes it real: `Ecrits.AcpAgent.Session.emit/2` starting the worker itself, on
  the first event carrying an unseen `edit_id`, before the event is broadcast.

  The ordering is the whole point — a worker started after the broadcast would
  miss the first delta of every patch.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Ecrits.AcpAgent.Session
  alias Ecrits.Doc.EditSession

  setup do
    id = "patch-wiring-" <> Ecto.UUID.generate()

    start_supervised!(
      {Session,
       [
         id: id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [exmcp_adapter: EcritsWeb.FakeAcpAdapter, test_pid: self()],
         workspace_root: File.cwd!(),
         mcp_servers: []
       ]}
    )

    :ok = Ecrits.AcpAgent.subscribe(id)
    pid = Session.whereis(id)
    edit_id = "edit-" <> Ecto.UUID.generate()

    on_exit(fn -> EditSession.stop(edit_id) end)

    {:ok, session_id: id, session: pid, edit_id: edit_id}
  end

  # The exfuse broadcast the Session normalizes into an `Ecrits.Agent.Event`.
  defp vfs_edit(context, attrs) do
    Map.merge(
      %{
        agent_id: context.session_id,
        turn_id: "turn-1",
        edit_id: context.edit_id,
        document_id: "d_hwp_wiring",
        path: Path.join(File.cwd!(), "report.hwpx"),
        phase: :candidate
      },
      attrs
    )
  end

  defp send_vfs_edit(context, attrs) do
    send(context.session, {:vfs_doc_edited, vfs_edit(context, attrs)})
  end

  # The Session is a GenServer: once an event it emitted has come back to this
  # (subscribed) test process, the emit that started the worker has run.
  defp await_event(context) do
    edit_id = context.edit_id
    assert_receive {:agent_event, %{type: :doc_edited, edit_id: ^edit_id}}, 2_000
  end

  defp await_stop(edit_id, tries \\ 100) do
    cond do
      EditSession.whereis(edit_id) == nil -> :ok
      tries == 0 -> flunk("#{edit_id} worker never stopped")
      true -> Process.sleep(10) && await_stop(edit_id, tries - 1)
    end
  end

  test "the session starts a patch worker on the first event naming the patch", context do
    refute EditSession.whereis(context.edit_id)

    send_vfs_edit(context, %{delta: "first"})
    await_event(context)

    assert is_pid(EditSession.whereis(context.edit_id))

    # Started BEFORE the broadcast, so the very first delta is accumulated and
    # not lost — this is what a view-side start could not guarantee.
    assert {:ok, snapshot} = EditSession.snapshot(context.edit_id)
    assert snapshot.delta == "first"
    assert snapshot.event_count == 1
    assert snapshot.status == :accumulating

    # Seeded from the session, so a rail that mounts later can render the card
    # without having seen a single event.
    assert snapshot.session_id == context.session_id
    assert snapshot.document_id == "d_hwp_wiring"
    assert snapshot.turn_id == "turn-1"
  end

  test "one worker per edit_id, accumulating across deltas", context do
    send_vfs_edit(context, %{delta: "one "})
    await_event(context)
    pid = EditSession.whereis(context.edit_id)

    send_vfs_edit(context, %{delta: "two "})
    await_event(context)
    send_vfs_edit(context, %{delta: "three"})
    await_event(context)

    assert EditSession.whereis(context.edit_id) == pid
    assert {:ok, %{delta: "one two three", event_count: 3}} = EditSession.snapshot(context.edit_id)
  end

  test "a follower sees every delta on the patch topic", context do
    send_vfs_edit(context, %{delta: "a"})
    await_event(context)

    # A rail attaching mid-patch: subscribe, then recover with snapshot/1 —
    # never a replay.
    :ok = EditSession.subscribe(context.edit_id)
    assert {:ok, %{delta: "a"}} = EditSession.snapshot(context.edit_id)

    send_vfs_edit(context, %{delta: "b"})
    assert_receive {:doc_edit_patch, %{delta: "ab", status: :accumulating}}, 2_000

    send_vfs_edit(context, %{delta: "c", phase: :committed})
    assert_receive {:doc_edit_patch, %{delta: "abc", status: :committed}}, 2_000
  end

  test "the patch settles and stops on its terminal event", context do
    send_vfs_edit(context, %{delta: "x"})
    await_event(context)
    assert is_pid(EditSession.whereis(context.edit_id))

    send_vfs_edit(context, %{phase: :committed})
    await_event(context)

    await_stop(context.edit_id)
    assert EditSession.snapshot(context.edit_id) == {:error, :not_found}
  end

  test "a trailing :snapshot_ready does not resurrect a settled patch", context do
    send_vfs_edit(context, %{delta: "x"})
    await_event(context)

    send_vfs_edit(context, %{phase: :committed})
    await_event(context)
    await_stop(context.edit_id)

    # `:snapshot_ready` is published AFTER `:committed`; without the session's
    # started-patch guard it would start a second worker for a finished patch,
    # which would then sit until its idle timeout reaped it.
    send_vfs_edit(context, %{phase: :snapshot_ready})
    await_event(context)

    refute EditSession.whereis(context.edit_id)
  end

  test "an edit that names no patch starts nothing", context do
    send(context.session, {:vfs_doc_edited, %{agent_id: context.session_id, path: "/tmp/x.md"}})
    assert_receive {:agent_event, %{type: :doc_edited}}, 2_000

    assert EditSession.snapshots_for_session(context.session_id) == []
  end

  # An ownerless edit (a user's own save, a `doc.save`) is still emitted so an
  # open viewer resyncs, but it belongs to no conversation.
  test "an unowned edit is emitted without starting a patch", context do
    send(context.session, {:vfs_doc_edited, Map.delete(vfs_edit(context, %{}), :agent_id)})
    await_event(context)

    refute EditSession.whereis(context.edit_id)
    assert EditSession.snapshots_for_session(context.session_id) == []
  end

  test "snapshots_for_session lists only this session's live patches", context do
    other = "other-" <> Ecto.UUID.generate()
    on_exit(fn -> EditSession.stop(other) end)
    {:ok, _pid} = EditSession.start_patch(other, session_id: "someone-else")

    send_vfs_edit(context, %{delta: "mine"})
    await_event(context)

    edit_id = context.edit_id
    assert [%{edit_id: ^edit_id, delta: "mine"}] =
             EditSession.snapshots_for_session(context.session_id)

    assert [%{edit_id: ^other}] = EditSession.snapshots_for_session("someone-else")
  end
end
