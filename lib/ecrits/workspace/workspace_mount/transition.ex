defmodule Ecrits.WorkspaceMount.Transition do
  @moduledoc false

  alias Ecrits.WorkspaceMount

  def start_picker(%WorkspaceMount{picker_busy?: true} = state), do: state

  def start_picker(%WorkspaceMount{} = state) do
    transition(state, %{picker_busy?: true, error: nil})
  end

  def picker_selected(%WorkspaceMount{} = state, path) do
    transition(state, %{picker_busy?: false, path: path, error: nil})
  end

  def picker_failed(%WorkspaceMount{} = state, reason) do
    transition(state, %{
      picker_busy?: false,
      error: error_message(reason)
    })
  end

  def submit(%WorkspaceMount{} = state, path) do
    transition(state, %{path: path, error: nil})
  end

  def put_error(%WorkspaceMount{} = state, reason) do
    transition(state, %{error: error_message(reason)})
  end

  defp transition(state, attrs) do
    changeset = WorkspaceMount.changeset(state, attrs)
    if changeset.valid?, do: Ecto.Changeset.apply_changes(changeset), else: state
  end

  defp error_message({:invalid_path, message}) when is_binary(message), do: message
  defp error_message({:error, message}) when is_binary(message), do: message
  defp error_message(:cancelled), do: "Folder selection canceled."

  defp error_message({:native_picker_unavailable, message}) when is_binary(message),
    do: message

  defp error_message({:substrate_unavailable, message}) when is_binary(message),
    do: message

  defp error_message(message) when is_binary(message), do: message

  # The workspace RUNTIME is a separate failure from the doc VFS mount, and
  # collapsing both into "could not be mounted" sent debugging at the FUSE layer
  # while the real cause was a dead `Workspace.Session` — the mount itself was
  # healthy (`ensure/1` -> `{:ok, :already}`, `mounted?/1` -> true) the whole
  # time. Name what actually failed.
  defp error_message({:session_unavailable, _reason}),
    do: "The workspace runtime is not responding. The folder is fine — reopen it to restart."

  defp error_message(:no_workspace),
    do: "The workspace runtime is not running for this folder. Reopen it to restart."

  defp error_message({:agent_unavailable, _reason}),
    do: "The agent session is not responding. The workspace is fine — try again."

  defp error_message(:agent_timeout),
    do: "The agent session did not respond in time. The workspace is fine — try again."

  defp error_message({:error, reason}), do: error_message(reason)

  # Never swallow an unrecognised reason: the generic sentence is what made this
  # class of failure unreadable from the outside.
  defp error_message(reason),
    do: "Workspace could not be mounted (#{inspect(reason)})."
end
