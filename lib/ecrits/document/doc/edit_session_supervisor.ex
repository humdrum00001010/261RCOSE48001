defmodule Ecrits.Doc.EditSessionSupervisor do
  @moduledoc """
  DynamicSupervisor for `Ecrits.Doc.EditSession` — one child per in-flight
  document patch, keyed in `Ecrits.Doc.EditSessionRegistry` by `edit_id`.

  Patch workers are `:temporary`: their whole value is accumulated in-memory
  partial state, so a crashed worker has nothing left to restart into. The patch
  card in the chat rail is a stream entry the LiveView owns; it does not depend
  on this process staying up.
  """

  use DynamicSupervisor

  alias Ecrits.Doc.EditSession

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start the worker for one patch. Prefer `Ecrits.Doc.EditSession.start_patch/2`,
  which folds `{:already_started, pid}` back into `{:ok, pid}`.
  """
  def start_patch(opts) when is_list(opts) do
    DynamicSupervisor.start_child(__MODULE__, {EditSession, opts})
  end
end
