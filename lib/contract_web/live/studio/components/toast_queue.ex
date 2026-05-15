defmodule ContractWeb.Live.Studio.Components.ToastQueue do
  @moduledoc """
  Stacked transient notification surface for Studio.

  Receives toasts via `@streams.toasts` (parent owns the stream; the parent
  LV calls `stream_insert(:toasts, …)` from `handle_protocol_message/2`).
  Each toast is

      %{id: uuid, level: :info | :warning | :error,
        title: String.t(), body: String.t() | nil,
        link: %{label, navigate} | nil}

  ## Surface

    * Fixed bottom-right on desktop / bottom-center above the bottom-nav on
      mobile (the parent passes `@viewport`; we default to `:desktop`).
    * Each toast: `<div role="alert">` with hairline border, no shadow,
      status-colored left border (`border-l-2 border-l-success` for `:info`,
      `border-l-warning` for `:warning`, `border-l-error` for `:error`).
    * Auto-dismiss after 5 s for `:info`; `:warning` and `:error` persist
      until the user clicks the X.
    * Stacks vertically. We don't try to limit at the server (the parent
      stream has no length API); the colocated hook prunes everything past
      the 5th visible row and surfaces a "+ N 더 보기" link.

  ## Events

    * `dismiss_toast` (targeted at this LC, with `phx-value-toast_id`) —
      fired on X-click and by the auto-dismiss timer. The click handler
      ALSO hides the row via `JS.hide/2` so the user sees an immediate
      response even though this LC cannot delete from the parent's stream.
    * `expand` / `collapse` (targeted at this LC) — local UI toggles for
      the "+ N more" affordance.

  ## Colocated hook `.Toast`

    * On `mounted`/`updated`: for `:info` toasts, schedule a
      `setTimeout(5000)` that pushes `dismiss_toast` to this component and
      fades the row out.
    * On `destroyed`: clear the pending timer.

  Translatable copy via `dgettext("studio", …)`. Korean primary; English
  fallback is the msgid itself per the project's i18n pattern.
  """

  use ContractWeb, :live_component

  alias Phoenix.LiveView.JS

  @max_visible 5

  @impl true
  def update(assigns, socket) do
    list = Map.get(assigns, :toasts)

    # `:streams` is a reserved assign on the LV socket — we can't blindly
    # copy it onto our LC's socket. Pull the toasts stream out and re-key
    # it onto our own `:toasts_stream` assign instead.
    toasts_stream =
      case Map.get(assigns, :streams) do
        %{toasts: ts} -> ts
        _ -> nil
      end

    render_mode =
      cond do
        is_list(list) -> :list
        not is_nil(toasts_stream) -> :stream
        true -> :empty
      end

    visible =
      case list do
        l when is_list(l) -> Enum.take(l, @max_visible)
        _ -> nil
      end

    hidden_count =
      case list do
        l when is_list(l) -> max(0, length(l) - @max_visible)
        _ -> 0
      end

    safe_assigns = Map.drop(assigns, [:streams])

    socket =
      socket
      |> assign(safe_assigns)
      |> assign(:toasts_stream, toasts_stream)
      |> assign(:render_mode, render_mode)
      |> assign(:visible_toasts, visible)
      |> assign(:hidden_count, hidden_count)
      |> assign_new(:expanded?, fn -> false end)

    {:ok, socket}
  end

  # --- handle_event ---------------------------------------------------------

  @impl true
  def handle_event("dismiss_toast", %{"toast_id" => toast_id}, socket) do
    # The parent's stream is the source of truth. The LC can't delete from
    # it directly; we forward a message so a future iteration of the shell
    # can wire `handle_info({:dismiss_toast, _}, …)` to call
    # `stream_delete/3`. In the meantime, the click-side `JS.hide/2` keeps
    # the UI honest.
    send(self(), {:dismiss_toast, toast_id})
    {:noreply, socket}
  end

  def handle_event("expand", _params, socket) do
    {:noreply, assign(socket, :expanded?, true)}
  end

  def handle_event("collapse", _params, socket) do
    {:noreply, assign(socket, :expanded?, false)}
  end

  # --- render ---------------------------------------------------------------

  attr :id, :string, required: true
  attr :streams, :map, required: true
  attr :viewport, :atom, default: :desktop
  # Test/preview override — when present we render this list of toast maps
  # directly (skipping the stream). Lets `render_component/2` exercise
  # rendering without configuring a full LV stream.
  attr :toasts, :list, default: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "fixed z-40 flex flex-col-reverse gap-2 pointer-events-none",
        position_class(@viewport)
      ]}
      data-stub="toast-queue"
      data-role="toast-queue"
      data-viewport={Atom.to_string(@viewport)}
      role="region"
      aria-label={dgettext("studio", "알림")}
    >
      <%= cond do %>
        <% @render_mode == :list -> %>
          <%= for toast <- (if @expanded?, do: (@toasts || []), else: (@visible_toasts || [])) do %>
            <.toast_row id={"toast-#{toast.id}"} toast={toast} myself={@myself} />
          <% end %>
          <.more_link
            :if={@hidden_count > 0 and not @expanded?}
            myself={@myself}
            hidden_count={@hidden_count}
          />
        <% @render_mode == :stream -> %>
          <div
            id={"#{@id}-stream"}
            phx-update="stream"
            class="flex flex-col-reverse gap-2 pointer-events-none"
          >
            <div :for={{dom_id, toast} <- @toasts_stream} id={dom_id} data-toast-id={toast.id}>
              <.toast_row id={"row-#{toast.id}"} toast={toast} myself={@myself} />
            </div>
          </div>
        <% true -> %>
      <% end %>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Toast">
        export default {
          mounted() {
            this.scheduleDismiss()
          },
          updated() {
            this.scheduleDismiss()
          },
          destroyed() {
            if (this.timer) { clearTimeout(this.timer); this.timer = null }
          },
          scheduleDismiss() {
            const level = this.el.dataset.toastLevel
            const id = this.el.dataset.toastId
            if (!id || level !== "info") return
            if (this.timer) clearTimeout(this.timer)
            this.timer = setTimeout(() => {
              this.pushEventTo(this.el, "dismiss_toast", {toast_id: id})
              this.el.classList.add("opacity-0")
              setTimeout(() => { if (this.el && this.el.parentNode) this.el.remove() }, 200)
            }, 5000)
          }
        }
      </script>
    </div>
    """
  end

  # --- function components --------------------------------------------------

  attr :id, :string, required: true
  attr :toast, :map, required: true
  attr :myself, :any, required: true

  defp toast_row(assigns) do
    ~H"""
    <div
      id={@id}
      role="alert"
      phx-hook=".Toast"
      data-toast-id={@toast.id}
      data-toast-level={Atom.to_string(@toast.level)}
      data-role="toast"
      class={[
        "relative pointer-events-auto bg-base-100 text-base-content",
        "border border-base-200/70 rounded-md",
        "px-3 py-2 pr-9 min-w-[260px] max-w-[420px]",
        "transition-opacity duration-200",
        "border-l-2",
        left_border_class(@toast.level)
      ]}
    >
      <div class="flex items-start gap-2">
        <.level_icon level={@toast.level} />
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium leading-tight">{@toast.title}</p>
          <p :if={Map.get(@toast, :body)} class="text-xs text-base-content/70 mt-0.5 break-words">
            {Map.get(@toast, :body)}
          </p>
          <.maybe_link link={Map.get(@toast, :link)} />
        </div>
      </div>
      <button
        type="button"
        class="absolute top-1.5 right-1.5 btn btn-ghost btn-xs btn-circle text-base-content/60 hover:text-base-content"
        phx-click={
          JS.push("dismiss_toast", value: %{toast_id: @toast.id}, target: @myself)
          |> JS.hide(
            to: "##{@id}",
            transition: {"transition-opacity duration-200", "opacity-100", "opacity-0"},
            time: 200
          )
        }
        aria-label={dgettext("studio", "알림 닫기")}
        data-role="toast-dismiss"
      >
        <.icon name="hero-x-mark-mini" class="size-4" />
      </button>
    </div>
    """
  end

  attr :link, :any, default: nil

  defp maybe_link(%{link: nil} = assigns), do: ~H""

  defp maybe_link(%{link: %{}} = assigns) do
    ~H"""
    <.link
      :if={@link[:navigate]}
      navigate={@link[:navigate]}
      class="text-xs link link-primary mt-1 inline-block"
    >
      {@link[:label] || dgettext("studio", "자세히")}
    </.link>
    """
  end

  defp maybe_link(assigns), do: ~H""

  attr :level, :atom, required: true

  defp level_icon(%{level: :info} = assigns) do
    ~H"""
    <.icon name="hero-information-circle-mini" class="size-4 text-success shrink-0 mt-0.5" />
    """
  end

  defp level_icon(%{level: :warning} = assigns) do
    ~H"""
    <.icon name="hero-exclamation-triangle-mini" class="size-4 text-warning shrink-0 mt-0.5" />
    """
  end

  defp level_icon(%{level: :error} = assigns) do
    ~H"""
    <.icon name="hero-exclamation-circle-mini" class="size-4 text-error shrink-0 mt-0.5" />
    """
  end

  defp level_icon(assigns) do
    ~H"""
    <.icon name="hero-information-circle-mini" class="size-4 text-base-content/60 shrink-0 mt-0.5" />
    """
  end

  attr :myself, :any, required: true
  attr :hidden_count, :integer, required: true

  defp more_link(assigns) do
    ~H"""
    <button
      type="button"
      class="pointer-events-auto self-end text-xs link link-hover text-base-content/60"
      phx-click="expand"
      phx-target={@myself}
      data-role="toast-more"
    >
      {dgettext("studio", "+ %{n}개 더 보기", n: @hidden_count)}
    </button>
    """
  end

  # --- private --------------------------------------------------------------

  defp left_border_class(:info), do: "border-l-success"
  defp left_border_class(:warning), do: "border-l-warning"
  defp left_border_class(:error), do: "border-l-error"
  defp left_border_class(_), do: "border-l-base-300"

  defp position_class(:mobile), do: "bottom-20 left-4 right-4 items-center"
  defp position_class(_desktop), do: "bottom-4 right-4 items-end"

  @doc false
  def max_visible, do: @max_visible
end
