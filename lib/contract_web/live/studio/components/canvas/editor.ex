defmodule ContractWeb.Live.Studio.Components.Canvas.Editor do
  @moduledoc """
  Canvas pane shown when `@studio_state.mode == :editing` — the inline
  contract editor.

  ## Responsibilities

    * Iterates `@projection.node_order` and renders each node by `:kind`
      (`:paragraph`, `:heading`, `:list`, `:list_item`, `:table`, etc.).
    * Renders editable nodes (`:paragraph` / `:heading` / `:list_item`) as
      `contenteditable` when the persona has `:write` perms. Viewers get
      plain text — no `contenteditable`, no event emission.
    * The colocated JS hook `.Editable` debounces user edits by 300 ms and
      pushes `edit_document` (untargeted, hits StudioLive). It also handles
      keyboard shortcuts: Cmd+Enter commits immediately, Cmd+Z fires
      `revoke_change` for the focused node's last change (gated on the
      `:revoke` perm via `data-can-revoke`).
    * On click/focus, the hook emits `set_node_focus` so the LV can route
      Cmd+Z to the right `last_change_for_node`.

  ## DOM contract with `MarksLayer`

  Every editable / displayable node carries `id="node-NODE_ID"` so the
  marks layer can absolutely position highlights/underlines on top of them.
  See sibling `MarksLayer` component.

  ## Persona-perm gating

      :write   contenteditable on, `edit_document` emitted
      :read    plain markup, no events, no Cmd+Z
      :revoke  additionally enables Cmd+Z for `revoke_change`

  ## Conflict handling

  On `:revision_conflict` from `Studio.submit/3`, the LV's `dispatch/2`
  surfaces a flash error. The hook listens for the `phx:editor-revert`
  custom event (dispatched by future shell work) to reset DOM text for the
  affected node. For tests, the component also accepts an optional
  `:conflict_node_id` assign which renders a toast banner inline so the
  conflict path is observable from `render_component/2`.

  See `/tmp/wave-3c1-shared.md` for the Wave 3C1 contract.
  """

  use ContractWeb, :live_component

  use Gettext, backend: ContractWeb.Gettext

  @editable_kinds ~w(paragraph heading list_item)a

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:conflict_node_id, fn -> nil end)
     |> assign(:can_write?, can?(assigns[:current_scope], :write))
     |> assign(:can_revoke?, can?(assigns[:current_scope], :revoke))
     |> assign(:selected_node_id, get_in(assigns, [:studio_state, Access.key(:selected_node_id)]))}
  end

  # ------------------------------------------------------------------
  # Render
  # ------------------------------------------------------------------

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :projection, :map, required: true
  attr :current_scope, :map, required: true
  attr :conflict_node_id, :string, default: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="overflow-y-auto p-8 max-w-3xl mx-auto"
      data-stub="canvas-editor"
      data-mode="editing"
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Editable">
        export default {
          mounted() {
            this.debounceMs = 300
            this.timers = new Map()
            this.dirty = new Set()

            // Click/focus → set_node_focus on the parent LV.
            this.onFocus = (e) => {
              const el = e.target.closest("[data-node-id]")
              if (!el) return
              this.pushEvent("set_node_focus", {node_id: el.dataset.nodeId})
            }

            // Input → optimistic local-only; schedule debounced commit.
            this.onInput = (e) => {
              const el = e.target.closest("[contenteditable='true'][data-node-id]")
              if (!el) return
              const nodeId = el.dataset.nodeId
              this.dirty.add(nodeId)
              if (this.timers.has(nodeId)) clearTimeout(this.timers.get(nodeId))
              this.timers.set(nodeId, setTimeout(() => this.commit(el), this.debounceMs))
            }

            // Blur → commit immediately (cancels pending debounce).
            this.onBlur = (e) => {
              const el = e.target.closest("[contenteditable='true'][data-node-id]")
              if (!el) return
              const nodeId = el.dataset.nodeId
              if (this.timers.has(nodeId)) {
                clearTimeout(this.timers.get(nodeId))
                this.timers.delete(nodeId)
              }
              if (this.dirty.has(nodeId)) this.commit(el)
            }

            // Key handling: Enter on heading commits immediately, Cmd/Ctrl+Enter
            // always commits, Cmd/Ctrl+Z routes through revoke_change.
            this.onKeyDown = (e) => {
              const el = e.target.closest("[contenteditable='true'][data-node-id]")
              if (!el) return
              const isMod = e.metaKey || e.ctrlKey
              const kind = el.dataset.nodeKind

              if (isMod && (e.key === "z" || e.key === "Z")) {
                e.preventDefault()
                if (this.el.dataset.canRevoke !== "true") return
                const changeId = el.dataset.lastChangeId
                if (changeId) {
                  this.pushEvent("revoke_change", {change_id: changeId, node_id: el.dataset.nodeId})
                }
                return
              }

              if (isMod && e.key === "Enter") {
                e.preventDefault()
                this.commit(el)
                return
              }

              if (e.key === "Enter" && kind === "heading") {
                e.preventDefault()
                this.commit(el)
              }
            }

            // Server pushed projection update — sync server content into the DOM
            // when this node is NOT being actively typed. Avoids clobbering
            // in-flight optimistic text.
            this.syncFromServer = () => {
              const nodes = this.el.querySelectorAll("[contenteditable='true'][data-node-id]")
              nodes.forEach((el) => {
                const nodeId = el.dataset.nodeId
                if (this.dirty.has(nodeId)) return
                const server = el.dataset.serverContent || ""
                if (el.innerText !== server) el.innerText = server
              })
            }

            // Conflict revert: force-restore server content for a node.
            this.onRevert = (e) => {
              const nodeId = e.detail && e.detail.node_id
              if (!nodeId) return
              const el = this.el.querySelector(`[data-node-id="${nodeId}"]`)
              if (!el) return
              this.dirty.delete(nodeId)
              if (this.timers.has(nodeId)) {
                clearTimeout(this.timers.get(nodeId))
                this.timers.delete(nodeId)
              }
              el.innerText = el.dataset.serverContent || ""
            }

            this.el.addEventListener("focusin", this.onFocus)
            this.el.addEventListener("input", this.onInput)
            this.el.addEventListener("focusout", this.onBlur)
            this.el.addEventListener("keydown", this.onKeyDown)
            window.addEventListener("phx:editor-revert", this.onRevert)

            this.syncFromServer()
          },

          updated() { this.syncFromServer() },

          commit(el) {
            const nodeId = el.dataset.nodeId
            const content = el.innerText
            this.dirty.delete(nodeId)
            this.timers.delete(nodeId)
            this.pushEvent("edit_document", {node_id: nodeId, content: content})
          },

          destroyed() {
            this.el.removeEventListener("focusin", this.onFocus)
            this.el.removeEventListener("input", this.onInput)
            this.el.removeEventListener("focusout", this.onBlur)
            this.el.removeEventListener("keydown", this.onKeyDown)
            window.removeEventListener("phx:editor-revert", this.onRevert)
            this.timers.forEach((t) => clearTimeout(t))
            this.timers.clear()
          },
        }
      </script>

      <div
        id={"#{@id}-body"}
        class="contract-body"
        phx-hook=".Editable"
        data-can-write={to_string(@can_write?)}
        data-can-revoke={to_string(@can_revoke?)}
      >
        <%= if Enum.empty?(node_order(@projection)) do %>
          <p class="text-base-content/60 italic">
            {dgettext("studio", "이 문서에는 아직 내용이 없습니다.")}
          </p>
        <% else %>
          <%= for node_id <- node_order(@projection),
                  node = Map.get(@projection.nodes, node_id),
                  node != nil do %>
            {render_node(assigns, node)}
          <% end %>
        <% end %>

        <div
          :if={@conflict_node_id}
          role="status"
          aria-live="polite"
          data-role="revision-conflict-toast"
          data-conflict-node-id={@conflict_node_id}
          class="alert alert-warning mt-4 text-sm"
        >
          {dgettext(
            "studio",
            "다른 사용자의 변경이 먼저 적용되었습니다. 입력 내용을 서버 값으로 되돌렸습니다."
          )}
        </div>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Node renderers
  # ------------------------------------------------------------------

  defp render_node(assigns, %{kind: :heading} = node) do
    level = node[:attrs][:level] || node[:attrs]["level"] || 2

    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:level, clamp_level(level))
      |> assign(:editable?, editable?(node, assigns))

    ~H"""
    <.heading_tag
      level={@level}
      id={"node-#{@node.id}"}
      class={[
        "font-serif font-semibold mb-3 mt-6 outline-none rounded-sm focus:ring-2 focus:ring-primary/40",
        @editable? && "px-1 -mx-1"
      ]}
      contenteditable={editable_attr(@editable?)}
      data-node-id={@node.id}
      data-node-kind="heading"
      data-server-content={node_content(@node)}
      data-last-change-id={last_change_id(@node)}
      phx-click="set_node_focus"
      phx-value-node_id={@node.id}
      spellcheck="false"
    >{node_content(@node)}</.heading_tag>
    """
  end

  defp render_node(assigns, %{kind: :paragraph} = node) do
    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:editable?, editable?(node, assigns))

    ~H"""
    <p
      id={"node-#{@node.id}"}
      class={[
        "mb-3 outline-none rounded-sm focus:ring-2 focus:ring-primary/40",
        @editable? && "px-1 -mx-1 hover:bg-base-200/40"
      ]}
      contenteditable={editable_attr(@editable?)}
      data-node-id={@node.id}
      data-node-kind="paragraph"
      data-server-content={node_content(@node)}
      data-last-change-id={last_change_id(@node)}
      phx-click="set_node_focus"
      phx-value-node_id={@node.id}
      spellcheck="false"
    >{node_content(@node)}</p>
    """
  end

  defp render_node(assigns, %{kind: :list} = node) do
    ordered? = (node[:attrs] || %{}) |> Map.get(:ordered, false) || Map.get(node[:attrs] || %{}, "ordered", false)
    children = node[:children] || []

    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:ordered?, ordered?)
      |> assign(:children, children)

    ~H"""
    <.list_tag
      ordered?={@ordered?}
      id={"node-#{@node.id}"}
      class="list-inside mb-4 ml-4"
      data-node-id={@node.id}
      data-node-kind="list"
    >
      <%= for child_id <- @children,
              child = Map.get(@projection.nodes, child_id),
              child != nil do %>
        {render_node(assigns, child)}
      <% end %>
    </.list_tag>
    """
  end

  defp render_node(assigns, %{kind: :list_item} = node) do
    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:editable?, editable?(node, assigns))

    ~H"""
    <li
      id={"node-#{@node.id}"}
      class={[
        "mb-1 outline-none rounded-sm focus:ring-2 focus:ring-primary/40",
        @editable? && "px-1 hover:bg-base-200/40"
      ]}
      contenteditable={editable_attr(@editable?)}
      data-node-id={@node.id}
      data-node-kind="list_item"
      data-server-content={node_content(@node)}
      data-last-change-id={last_change_id(@node)}
      phx-click="set_node_focus"
      phx-value-node_id={@node.id}
      spellcheck="false"
    >{node_content(@node)}</li>
    """
  end

  defp render_node(assigns, %{kind: :table} = node) do
    # Read-only fallback per Wave 3C1 brief — table editing belongs to a
    # later wave. We still expose the DOM id so MarksLayer can target it.
    rows = (node[:attrs] || %{})[:rows] || (node[:attrs] || %{})["rows"] || []

    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:rows, rows)

    ~H"""
    <div
      id={"node-#{@node.id}"}
      class="overflow-x-auto my-4 border border-base-300 rounded-md"
      data-node-id={@node.id}
      data-node-kind="table"
      data-readonly="true"
      phx-click="set_node_focus"
      phx-value-node_id={@node.id}
    >
      <table class="table table-compact w-full">
        <tbody>
          <%= for row <- @rows do %>
            <tr>
              <%= for cell <- row do %>
                <td class="border border-base-200 px-2 py-1">{cell}</td>
              <% end %>
            </tr>
          <% end %>
          <%= if @rows == [] do %>
            <tr>
              <td class="text-base-content/50 italic px-2 py-1">
                {dgettext("studio", "표 (읽기 전용)")}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp render_node(assigns, %{kind: :section} = node) do
    children = node[:children] || []

    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:children, children)

    ~H"""
    <section
      id={"node-#{@node.id}"}
      class="mb-6"
      data-node-id={@node.id}
      data-node-kind="section"
    >
      <%= for child_id <- @children,
              child = Map.get(@projection.nodes, child_id),
              child != nil do %>
        {render_node(assigns, child)}
      <% end %>
    </section>
    """
  end

  # Fallback for any unknown / future node kind — render as inert div with
  # the DOM id intact so MarksLayer can still position over it.
  defp render_node(assigns, %{kind: kind} = node) do
    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:kind_str, to_string(kind))

    ~H"""
    <div
      id={"node-#{@node.id}"}
      class="my-2 text-base-content/70"
      data-node-id={@node.id}
      data-node-kind={@kind_str}
      data-readonly="true"
    >{node_content(@node)}</div>
    """
  end

  # ------------------------------------------------------------------
  # Tiny HEEx tag helpers
  # ------------------------------------------------------------------

  attr :level, :integer, required: true
  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :contenteditable, :string, default: nil
  attr :rest, :global, include: ~w(data-node-id data-node-kind data-server-content data-last-change-id phx-click phx-value-node_id spellcheck)
  slot :inner_block, required: true

  defp heading_tag(%{level: 1} = assigns) do
    ~H"<h1 id={@id} class={@class} contenteditable={@contenteditable} {@rest}>{render_slot(@inner_block)}</h1>"
  end

  defp heading_tag(%{level: 2} = assigns) do
    ~H"<h2 id={@id} class={@class} contenteditable={@contenteditable} {@rest}>{render_slot(@inner_block)}</h2>"
  end

  defp heading_tag(%{level: 3} = assigns) do
    ~H"<h3 id={@id} class={@class} contenteditable={@contenteditable} {@rest}>{render_slot(@inner_block)}</h3>"
  end

  defp heading_tag(%{level: 4} = assigns) do
    ~H"<h4 id={@id} class={@class} contenteditable={@contenteditable} {@rest}>{render_slot(@inner_block)}</h4>"
  end

  defp heading_tag(%{level: 5} = assigns) do
    ~H"<h5 id={@id} class={@class} contenteditable={@contenteditable} {@rest}>{render_slot(@inner_block)}</h5>"
  end

  defp heading_tag(assigns) do
    ~H"<h6 id={@id} class={@class} contenteditable={@contenteditable} {@rest}>{render_slot(@inner_block)}</h6>"
  end

  attr :ordered?, :boolean, default: false
  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(data-node-id data-node-kind)
  slot :inner_block, required: true

  defp list_tag(%{ordered?: true} = assigns) do
    ~H"""
    <ol id={@id} class={["list-decimal", @class]} {@rest}>{render_slot(@inner_block)}</ol>
    """
  end

  defp list_tag(assigns) do
    ~H"""
    <ul id={@id} class={["list-disc", @class]} {@rest}>{render_slot(@inner_block)}</ul>
    """
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp node_order(%{node_order: order}) when is_list(order), do: order
  defp node_order(_), do: []

  defp node_content(%{content: content}) when is_binary(content), do: content
  defp node_content(_), do: ""

  defp last_change_id(node) do
    case node[:attrs] || %{} do
      %{last_change_id: id} when is_binary(id) -> id
      %{"last_change_id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp clamp_level(n) when is_integer(n) and n >= 1 and n <= 6, do: n

  defp clamp_level(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> clamp_level(i)
      _ -> 2
    end
  end

  defp clamp_level(_), do: 2

  defp editable?(%{kind: kind}, %{can_write?: true}) when kind in @editable_kinds, do: true
  defp editable?(_, _), do: false

  defp editable_attr(true), do: "true"
  defp editable_attr(false), do: nil

  defp can?(%Contract.Context{perms: perms}, perm) when is_list(perms),
    do: perm in perms

  defp can?(%{perms: perms}, perm) when is_list(perms), do: perm in perms
  defp can?(_, _), do: false
end
