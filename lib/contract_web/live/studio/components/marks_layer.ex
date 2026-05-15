defmodule ContractWeb.Live.Studio.Components.MarksLayer do
  @moduledoc """
  Desktop-only overlay rendered absolutely over the Canvas component.

  Iterates `@projection.marks` and renders one visual indicator per mark
  attached to a node (`target_type: :node`). Indicators are anchored to
  the node's DOM element (`id="node-${node_id}"`) by the colocated JS
  hook, which reads `data-marks` (a JSON-encoded list of
  `%{mark_id, node_id, intent}`) on mount + window resize, computes each
  anchor's bounding rect, and positions a pin in the right margin.

  Intent palette (Wave 3C1 contract):

      :ask     → emerald underline + "?" pin
      :flag    → amber   underline + "!" pin
      :explain → slate dotted underline (subtle)
      :label   → slate text-only badge below the node
      :link    → slate icon-link pin

  Mobile: the layer's `update/2` early-returns an empty render — marks
  live in the preview-overlay's marks tab on mobile. Clicking a pin pushes
  a `set_node_focus` event with the `node_id`, which the StudioLive
  handles by updating `studio_state.selected_node_id` and (downstream)
  opening the marks panel for that node.

  This component depends on the contract that `Canvas.{Briefing, Editor,
  Review}` render nodes with `id="node-${node_id}"` DOM ids.
  """
  use ContractWeb, :live_component

  attr :id, :string, required: true
  attr :projection, :map, required: true
  attr :studio_state, :map, required: true
  attr :viewport, :atom, default: :desktop

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:viewport, :desktop)
     |> assign(:projection, %{marks: %{}})
     |> assign(:studio_state, nil)
     |> assign(:node_marks, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, Map.get(assigns, :id, "marks-layer"))
      |> assign(:viewport, Map.get(assigns, :viewport, :desktop))
      |> assign(:projection, Map.get(assigns, :projection, %{marks: %{}}))
      |> assign(:studio_state, Map.get(assigns, :studio_state))

    node_marks =
      case socket.assigns.viewport do
        :mobile -> []
        _ -> mark_list(socket.assigns.projection)
      end

    {:ok, assign(socket, :node_marks, node_marks)}
  end

  @impl true
  def render(%{viewport: :mobile} = assigns) do
    ~H"""
    <div id={@id} class="hidden" data-role="marks-layer-mobile-hidden"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".MarksLayer"
      data-marks={Jason.encode!(@node_marks)}
      data-role="marks-layer"
      class="pointer-events-none absolute inset-0 z-10"
      aria-hidden={if @node_marks == [], do: "true", else: "false"}
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".MarksLayer">
        export default {
          mounted() {
            this.positionAll = () => {
              const raw = this.el.dataset.marks || "[]"
              let marks = []
              try { marks = JSON.parse(raw) } catch (_e) { marks = [] }
              // Clear previously rendered pins.
              this.el.querySelectorAll("[data-role='marks-pin']").forEach((n) => n.remove())
              const layerRect = this.el.getBoundingClientRect()
              for (const m of marks) {
                const anchor = document.getElementById("node-" + m.node_id)
                if (!anchor) continue
                const r = anchor.getBoundingClientRect()
                const pin = document.createElement("button")
                pin.type = "button"
                pin.dataset.role = "marks-pin"
                pin.dataset.intent = m.intent
                pin.dataset.markId = m.mark_id
                pin.dataset.nodeId = m.node_id
                pin.setAttribute("phx-click", "set_node_focus")
                pin.setAttribute("phx-value-node_id", m.node_id)
                pin.setAttribute("phx-value-mark_id", m.mark_id)
                pin.setAttribute("aria-label", "Open mark for node " + m.node_id)
                pin.className = this.classFor(m.intent)
                pin.textContent = this.glyphFor(m.intent)
                // Position pin in the right margin, vertically centered on the node.
                pin.style.position = "absolute"
                pin.style.top = (r.top - layerRect.top + Math.max(0, (r.height - 20) / 2)) + "px"
                pin.style.right = "8px"
                pin.style.pointerEvents = "auto"
                this.el.appendChild(pin)
              }
            }
            this.classFor = (intent) => {
              const base = "inline-flex items-center justify-center rounded-full w-6 h-6 text-xs font-mono shadow-sm border "
              switch (intent) {
                case "ask":     return base + "bg-emerald-50 text-emerald-700 border-emerald-300"
                case "flag":    return base + "bg-amber-50 text-amber-700 border-amber-300"
                case "explain": return base + "bg-slate-50 text-slate-600 border-slate-300 border-dotted"
                case "label":   return base + "bg-slate-50 text-slate-700 border-slate-200"
                case "link":    return base + "bg-slate-50 text-slate-700 border-slate-300"
                default:        return base + "bg-slate-50 text-slate-600 border-slate-200"
              }
            }
            this.glyphFor = (intent) => {
              switch (intent) {
                case "ask":     return "?"
                case "flag":    return "!"
                case "explain": return "i"
                case "label":   return "#"
                case "link":    return "→"
                default:        return "•"
              }
            }
            this.handler = () => {
              if (this.t) clearTimeout(this.t)
              this.t = setTimeout(this.positionAll, 100)
            }
            // First paint after the canvas has had a chance to render.
            requestAnimationFrame(this.positionAll)
            window.addEventListener("resize", this.handler)
          },
          updated() {
            requestAnimationFrame(this.positionAll)
          },
          destroyed() {
            window.removeEventListener("resize", this.handler)
            if (this.t) clearTimeout(this.t)
          }
        }
      </script>

      <%!--
      Server-side fallback markup for tests + no-JS — one element per mark
      so we can assert intent colors, click bindings, and counts in
      LiveViewTest without booting a real browser. The JS hook above
      replaces these with absolutely-positioned pins on mount.
      --%>
      <ul class="sr-only" data-role="marks-fallback-list">
        <li :for={m <- @node_marks} data-role="marks-fallback-item">
          <button
            type="button"
            phx-click="set_node_focus"
            phx-value-node_id={m.node_id}
            phx-value-mark_id={m.mark_id}
            data-role="marks-pin-fallback"
            data-intent={m.intent}
            data-node-id={m.node_id}
            data-mark-id={m.mark_id}
            class={pin_class(m.intent)}
            aria-label={dgettext("studio", "Open mark for node %{node_id}", node_id: m.node_id)}
          >
            {glyph_for(m.intent)}
            <span class="sr-only">{intent_label(m.intent)}</span>
          </button>
        </li>
      </ul>

      <p :if={@node_marks == []} class="sr-only" data-role="marks-layer-empty">
        {dgettext("studio", "표시된 메모 없음")}
      </p>
    </div>
    """
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  @doc false
  @spec mark_list(map()) :: [map()]
  def mark_list(%{marks: marks}) when is_map(marks) do
    marks
    |> Enum.flat_map(&extract_node_mark/1)
    # Stable order for deterministic rendering / tests.
    |> Enum.sort_by(& &1.mark_id)
  end

  def mark_list(_), do: []

  defp extract_node_mark({mark_id, %{intent: intent, target_type: :node, target_id: node_id}})
       when is_binary(node_id) and is_atom(intent) do
    [%{mark_id: to_string(mark_id), node_id: node_id, intent: Atom.to_string(intent)}]
  end

  # Some projections may not carry an explicit target_type; fall back to
  # data.node_id if present (the older shape used by the briefing canvas).
  defp extract_node_mark({mark_id, %{intent: intent, data: %{node_id: node_id}}})
       when is_binary(node_id) and is_atom(intent) do
    [%{mark_id: to_string(mark_id), node_id: node_id, intent: Atom.to_string(intent)}]
  end

  defp extract_node_mark(_), do: []

  @doc false
  def pin_class(intent) do
    base = "inline-flex items-center justify-center rounded-full w-6 h-6 text-xs font-mono "

    case intent_atom(intent) do
      :ask -> base <> "bg-emerald-50 text-emerald-700 border border-emerald-300"
      :flag -> base <> "bg-amber-50 text-amber-700 border border-amber-300"
      :explain -> base <> "bg-slate-50 text-slate-600 border border-dotted border-slate-300"
      :label -> base <> "bg-slate-50 text-slate-700 border border-slate-200"
      :link -> base <> "bg-slate-50 text-slate-700 border border-slate-300"
      _ -> base <> "bg-slate-50 text-slate-600 border border-slate-200"
    end
  end

  defp glyph_for(intent) do
    case intent_atom(intent) do
      :ask -> "?"
      :flag -> "!"
      :explain -> "i"
      :label -> "#"
      :link -> "→"
      _ -> "•"
    end
  end

  defp intent_label(intent) do
    case intent_atom(intent) do
      :ask -> dgettext("studio", "질문")
      :flag -> dgettext("studio", "주의")
      :explain -> dgettext("studio", "설명")
      :label -> dgettext("studio", "라벨")
      :link -> dgettext("studio", "링크")
      _ -> dgettext("studio", "메모")
    end
  end

  defp intent_atom(intent) when is_atom(intent), do: intent

  defp intent_atom(intent) when is_binary(intent) do
    case intent do
      "ask" -> :ask
      "flag" -> :flag
      "explain" -> :explain
      "label" -> :label
      "link" -> :link
      _ -> :unknown
    end
  end

  defp intent_atom(_), do: :unknown
end
