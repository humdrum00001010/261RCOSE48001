defmodule Ecrits.Fuse.OpenDocsTurnRefreshTest do
  @moduledoc """
  `doc.open_doc` pins the opening turn onto the mount registration and
  `Projection.write_back/3` fences a write against the session's live turn. An
  agent that opens a document in one turn and edits it in a LATER turn had its
  first write of every subsequent turn rejected as `:turn_invalidated` (measured
  with `:dbg`: same agent_id and instance_id, different turn_id). The session now
  advances the pin at turn launch — for that agent+instance only.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Fuse.OpenDocs

  @agent "agent-a"
  @instance "instance-1"
  @opened_turn "turn-opened"
  @live_turn "turn-live"

  setup do
    root = Path.join(System.tmp_dir!(), "open-docs-turn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp open!(root, name, agent, instance, turn) do
    OpenDocs.open(root, name,
      agent_id: agent,
      instance_id: instance,
      turn_id: turn
    )
  end

  test "advances the pinned turn for the owning agent", %{root: root} do
    open!(root, "a.doclang.xml", @agent, @instance, @opened_turn)
    on_exit(fn -> OpenDocs.close(root, "a.doclang.xml") end)

    assert OpenDocs.owner_turn_id(root, "a.doclang.xml") == @opened_turn

    assert OpenDocs.refresh_agent_turn(@agent, @instance, @live_turn) == 1
    assert OpenDocs.owner_turn_id(root, "a.doclang.xml") == @live_turn
  end

  test "leaves registrations owned by a different agent or instance alone", %{root: root} do
    open!(root, "mine.doclang.xml", @agent, @instance, @opened_turn)
    open!(root, "other-agent.doclang.xml", "agent-b", @instance, @opened_turn)
    open!(root, "other-instance.doclang.xml", @agent, "instance-2", @opened_turn)

    on_exit(fn ->
      for n <- ~w(mine.doclang.xml other-agent.doclang.xml other-instance.doclang.xml),
          do: OpenDocs.close(root, n)
    end)

    assert OpenDocs.refresh_agent_turn(@agent, @instance, @live_turn) == 1

    assert OpenDocs.owner_turn_id(root, "mine.doclang.xml") == @live_turn
    assert OpenDocs.owner_turn_id(root, "other-agent.doclang.xml") == @opened_turn
    assert OpenDocs.owner_turn_id(root, "other-instance.doclang.xml") == @opened_turn
  end

  test "is idempotent and reports nothing to advance", %{root: root} do
    open!(root, "b.doclang.xml", @agent, @instance, @live_turn)
    on_exit(fn -> OpenDocs.close(root, "b.doclang.xml") end)

    assert OpenDocs.refresh_agent_turn(@agent, @instance, @live_turn) == 0
    assert OpenDocs.owner_turn_id(root, "b.doclang.xml") == @live_turn
  end

  test "ignores blank identities rather than re-pinning everything", %{root: root} do
    open!(root, "c.doclang.xml", @agent, @instance, @opened_turn)
    on_exit(fn -> OpenDocs.close(root, "c.doclang.xml") end)

    assert OpenDocs.refresh_agent_turn("", @instance, @live_turn) == 0
    assert OpenDocs.refresh_agent_turn(@agent, @instance, "") == 0
    assert OpenDocs.owner_turn_id(root, "c.doclang.xml") == @opened_turn
  end
end
