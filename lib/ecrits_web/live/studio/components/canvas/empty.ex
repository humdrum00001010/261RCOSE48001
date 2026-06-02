defmodule EcritsWeb.Live.Studio.Components.Canvas.Empty do
  @moduledoc """
  Compatibility stub for the no-document canvas.

  The active `/studio` empty surface is owned by `EcritsWeb.DocumentLive`,
  which renders upload/type selection and routes new documents to
  `/studio/:document_id`. This component remains as a minimal contract
  for callers that still mount `Canvas.Empty`.
  """

  use EcritsWeb, :live_component

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :projection, :map, required: true
  attr :current_scope, :map, required: true
  attr :document_upload, :any, default: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="min-h-0"
      data-stub="canvas-empty"
      data-role="canvas-empty"
    >
    </div>
    """
  end
end
