defmodule ContractWeb.Live.Studio.Components.Canvas.Empty do
  @moduledoc """
  Canvas empty state — shown when `@studio_state.mode == :no_document`.

  Owned by Wave 3C1 / canvas-empty. Renders a centered illustration with
  a heading and subtitle, plus two inline action links:

    * "+ 새 문서" → emits `open_modal` (modal: `new_document`)
    * "PDF 가져오기" → emits `open_modal` (modal: `upload`)

  Persona gating: a `:viewer` (whose perms list does NOT include `:write`)
  sees the illustration + copy but neither action link. Every other persona
  sees both. Both events bubble up to `ContractWeb.StudioLive`, which maps
  `open_modal` to a `:local` UI action.
  """

  use ContractWeb, :live_component

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :projection, :map, required: true
  attr :current_scope, :map, required: true

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :can_write?, can_write?(assigns.current_scope))

    ~H"""
    <div
      id={@id}
      class="overflow-auto flex items-center justify-center"
      data-stub="canvas-empty"
      data-role="canvas-empty"
    >
      <div class="max-w-md mx-auto py-24 text-center">
        <img
          src={~p"/images/landing/dashboard-empty.png"}
          alt={dgettext("studio", "An empty folder line drawing — no document selected.")}
          class="mx-auto w-32 sm:w-40 h-auto object-contain opacity-90"
          width="1024"
          height="1024"
          loading="lazy"
        />

        <h2 class="mt-6 text-lg font-semibold tracking-tight text-base-content">
          {dgettext("studio", "문서를 선택하거나 새로 만드세요")}
        </h2>
        <p class="mt-2 text-sm text-base-content/60">
          {dgettext("studio", "왼쪽에서 안건의 문서를 고르거나, 새 계약서를 시작합니다.")}
        </p>

        <div
          :if={@can_write?}
          class="mt-6 flex flex-wrap items-center justify-center gap-x-4 gap-y-2 text-sm"
          data-role="canvas-empty-actions"
        >
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="new_document"
            class="link link-primary link-hover font-medium"
            data-role="canvas-empty-new-document"
          >
            {dgettext("studio", "+ 새 문서")}
          </button>
          <span class="text-base-content/30" aria-hidden="true">·</span>
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="upload"
            class="link link-primary link-hover font-medium"
            data-role="canvas-empty-upload"
          >
            {dgettext("studio", "PDF 가져오기")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Persona perm check
  #
  # The :viewer persona has perms `[:read]`. Every other persona
  # (:lawyer, :paralegal, :agent_supervised, :admin) carries `:write`. So
  # "can use the inline create/import actions" maps to "has :write".
  # ---------------------------------------------------------------------------

  defp can_write?(%{perms: perms}) when is_list(perms), do: :write in perms
  defp can_write?(_), do: false
end
