defmodule Contract.Agent.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for in-flight `Contract.Agent.RunServer` processes.

  Each agent run is one short-lived GenServer; this supervisor allows
  them to start/stop independently while sharing the same crash boundary.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts a `Contract.Agent.RunServer` under this supervisor."
  def start_run(args) do
    DynamicSupervisor.start_child(__MODULE__, {Contract.Agent.RunServer, args})
  end
end
