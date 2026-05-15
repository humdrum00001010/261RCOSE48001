defmodule ContractWeb.StudioLive do
  @moduledoc """
  Disposable UI process. Does NOT own document truth.

  See SPEC.md §10–§11. Track A1/A2 wire this up to `Contract.Studio` once
  Engine/IO are ready.
  """

  use ContractWeb, :live_view

  alias Contract.Types, as: T

  @impl true
  @spec mount(T.params(), map(), T.socket()) :: {:ok, T.socket()}
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-2xl font-semibold">Contract Studio</h1>
      <p class="text-sm opacity-70">Placeholder — wired up by Track A1/A2.</p>
    </div>
    """
  end
end
