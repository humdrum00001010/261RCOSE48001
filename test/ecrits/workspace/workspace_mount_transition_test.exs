defmodule Ecrits.WorkspaceMountTransitionTest do
  @moduledoc """
  A dead `Workspace.Session` used to surface as "Workspace could not be mounted."
  while the doc VFS mount was demonstrably healthy (`DocMount.ensure/1` returned
  `{:ok, :already}` and `mounted?/1` was true). The catch-all message sent
  debugging to the FUSE layer for a runtime failure, so every reason now names
  what actually failed and nothing is swallowed.
  """
  use ExUnit.Case, async: true

  alias Ecrits.WorkspaceMount
  alias Ecrits.WorkspaceMount.Transition

  defp message(reason) do
    WorkspaceMount.new() |> Transition.put_error(reason) |> Map.fetch!(:error)
  end

  test "a dead workspace runtime does not claim the mount failed" do
    for reason <- [:no_workspace, {:session_unavailable, :timeout}] do
      msg = message(reason)
      assert msg =~ "workspace runtime"
      refute msg =~ "could not be mounted"
    end
  end

  test "an unresponsive agent is reported as the agent, not the workspace" do
    for reason <- [:agent_timeout, {:agent_unavailable, {:timeout, {GenServer, :call, []}}}] do
      msg = message(reason)
      assert msg =~ "agent session"
      refute msg =~ "could not be mounted"
    end
  end

  test "an unrecognised reason is still shown, never swallowed" do
    msg = message({:something_new, 42})
    assert msg =~ "could not be mounted"
    assert msg =~ "something_new", "the real reason must survive into the message"
  end

  test "explicit strings and known reasons are passed through unchanged" do
    assert message({:invalid_path, "Not a folder."}) == "Not a folder."
    assert message("Custom failure.") == "Custom failure."
    assert message(:cancelled) == "Folder selection canceled."
  end

  test "a wrapped error unwraps to the inner reason's message" do
    assert message({:error, :no_workspace}) == message(:no_workspace)
  end
end
