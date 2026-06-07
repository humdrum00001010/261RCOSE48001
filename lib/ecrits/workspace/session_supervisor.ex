defmodule Ecrits.Workspace.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for `Ecrits.Workspace.Session` processes (one per workspace
  path). Durable: a Session survives the workspace LiveView dying / a browser
  refresh, so re-attaching by path returns the same foreground agent.

  Each Session is keyed in `Ecrits.Workspace.SessionRegistry` by its canonical
  path; `Ecrits.Workspace.Session.attach/2` get-or-starts the child here.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
