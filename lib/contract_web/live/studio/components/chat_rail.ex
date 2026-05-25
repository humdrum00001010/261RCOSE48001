defmodule ContractWeb.Live.Studio.Components.ChatRail do
  @moduledoc """
  The central agent dialog surface (Wave 3C1 / chat-rail).

  Responsibilities:

    * Renders the streamed conversation (`@streams.chat_messages`) — both
      user-authored messages and agent prose (streamed + completed).
    * Mounts the `GrillRail` sub-LiveComponent when the latest agent
      message has unresolved `mode: "grill"` ask-marks.
    * Owns the textarea + send button input footer.
    * Surfaces a header status pill keyed off `@studio_state.agent_run_id`.
    * Switches between a desktop right-rail layout and a mobile full-viewport
      layout depending on the `layout` attr / `viewport` assign.

  ## Hard local constraint

  The send button is `type="button"` (never `type="submit"`). The form's
  `phx-submit` exists as a fallback, but the colocated `.ChatInput` hook
  intercepts both Enter-in-textarea and click-on-send-button, calling
  `pushEvent` directly. This preserves keyboard focus on mobile across
  sends — losing focus mid-thread on Korean IME is the regression
  recorded in the responsive-scope memory.

  Keyboard rules:

    * Enter (no shift) → submit
    * Shift+Enter → newline
    * On send: clear textarea + refocus
  """
  use ContractWeb, :live_component

  alias ContractWeb.Live.Studio.Components.GrillRail

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :chat_thread, :map, default: nil
  attr :streams, :map, required: true
  attr :current_scope, :map, required: true
  attr :layout, :atom, default: :default

  # Whether to mount the GrillRail sub-LiveComponent. Parent decides this
  # based on the latest agent message's mode (`"grill"` = unanswered
  # ask-marks). Defaults to nil; the component falls back to
  # `studio_state.grill_active?` if the parent set that flag.
  attr :grill_active?, :any, default: nil

  # Unresolved ask-marks for the current agent_run_id. Computed by the
  # parent shell (filters `@projection.marks` for `intent: :ask` matching
  # the current `agent_run_id`) and forwarded into GrillRail. The shell
  # wiring is a separate merge-fix; this component just accepts + forwards.
  attr :grill_marks, :list, default: []

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:mobile?, fn -> assigns.layout == :mobile_full end)
      |> assign(:agent_status, agent_status(assigns.studio_state))
      |> assign(:observer_mode?, observer_mode?(assigns.current_scope))
      |> assign(:grill_active?, resolve_grill_active?(assigns))
      |> assign(:no_document?, no_document?(assigns.studio_state))
      |> assign(:chat_thread_title, chat_thread_title(assigns[:chat_thread]))
      |> assign(:chat_context_empty?, chat_context_empty?(assigns[:chat_thread]))
      |> assign(:start_options, start_options())

    ~H"""
    <aside
      id={@id}
      data-component="chat-rail"
      data-layout={if @mobile?, do: "mobile", else: "desktop"}
      data-stub="chat-rail"
      class={[
        "group/chat flex flex-col bg-base-200 text-base-content min-h-0 h-full w-full",
        not @mobile? && "shrink-0 border-l border-base-300",
        @mobile? && "w-full flex-1 h-full"
      ]}
    >
      <div
        data-role="chat-rail-controls"
        class="flex shrink-0 items-center justify-between gap-2 border-b border-base-300 bg-base-200/95 px-4 py-1"
      >
        <h2
          data-role="chat-thread-title"
          title={@chat_thread_title}
          class="flex min-w-0 flex-1 items-center gap-1.5 text-sm font-semibold leading-5 text-base-content"
        >
          <img
            src={~p"/images/icons/openai-blossom.svg"}
            data-role="chat-title-favicon"
            aria-hidden="true"
            alt=""
            class="size-4 shrink-0 opacity-85 [[data-theme=studio-dark]_&]:invert"
          />
          <form
            id="chat-thread-title-form"
            phx-submit="chat.thread.rename"
            phx-change="chat.thread.rename"
            data-role="chat-thread-title-form"
            class="min-w-0 flex-1"
          >
            <input
              id="chat-thread-title-input"
              type="text"
              name="title"
              value={@chat_thread_title}
              phx-debounce="blur"
              aria-label={dgettext("studio", "Chat title")}
              title={@chat_thread_title}
              autocomplete="off"
              spellcheck="false"
              data-role="chat-thread-title-input"
              class="block h-6 w-full min-w-0 truncate rounded-sm border border-transparent bg-transparent px-1 py-0 text-sm font-semibold leading-5 text-base-content outline-none transition-colors hover:border-base-300 hover:bg-base-100/60 focus:border-base-content/30 focus:bg-base-100 disabled:cursor-default disabled:text-base-content/70"
            />
          </form>
        </h2>

        <div class="flex shrink-0 items-center gap-1">
          <button
            type="button"
            phx-click="chat.context_reset"
            data-role="chat-context-reset"
            disabled={@chat_context_empty?}
            class="inline-flex size-8 items-center justify-center rounded-md text-base-content/60 hover:bg-base-300 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-35 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-base-content/25"
            aria-label={dgettext("studio", "Reset chat context")}
            title={dgettext("studio", "Reset chat context")}
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
        </div>
      </div>

      <%!-- Observer-mode banner (agent_supervised persona) --%>
      <div
        :if={@observer_mode?}
        data-role="observer-banner"
        role="status"
        class="px-4 py-2 text-xs bg-warning/10 text-warning-content border-b border-warning/30"
      >
        {dgettext("studio", "관찰 모드 — 메시지는 다른 사용자가 받습니다")}
      </div>

      <%!-- GrillRail (unanswered ask-marks) --%>
      <div :if={@grill_active?} class="shrink-0">
        <.live_component
          module={GrillRail}
          id={"#{@id}-grill"}
          studio_state={@studio_state}
          current_scope={@current_scope}
          grill_marks={@grill_marks}
        />
      </div>

      <%!-- Welcome panels (siblings of the stream so the stream can be a
           pure phx-update="stream" container). Hidden via the `group/chat`
           on the aside as soon as any chat-message appears in the stream. --%>
      <div
        :if={not @no_document?}
        id={"#{@id}-welcome"}
        data-role="chat-welcome"
        class="shrink-0 px-1.5 py-6 text-sm text-base-content/60 italic text-center group-has-[[data-role=chat-message]]/chat:hidden"
      >
        {dgettext(
          "studio",
          "에이전트에게 무엇이든 물어보세요 — 초안, 마크, 내보내기."
        )}
      </div>

      <div
        :if={@no_document?}
        id={"#{@id}-no-doc-welcome"}
        data-role="chat-no-doc-welcome"
        class="shrink-0 px-1.5 py-2 group-has-[[data-role=chat-message]]/chat:hidden flex flex-col gap-3 max-w-[88%] self-start"
      >
        <div
          data-role="chat-no-doc-message"
          class="rounded-lg rounded-tl-sm bg-base-100 border border-base-300 text-base-content text-sm px-3 py-2"
        >
          <p class="mb-2">{dgettext("studio", "새 문서를 시작합니다. 어떻게 시작할까요?")}</p>
          <ol class="list-decimal list-inside space-y-1 marker:text-base-content/60">
            <li>
              <strong>{dgettext("studio", "최근 문서 열기")}</strong>
              <span class="text-base-content/70">
                {dgettext("studio", " — 최근 작업한 문서로 이동")}
              </span>
            </li>
            <li>
              <strong>{dgettext("studio", "빈 계약서 만들기")}</strong>
              <span class="text-base-content/70">
                {dgettext("studio", " — 처음부터 작성")}
              </span>
            </li>
            <li>
              <strong>{dgettext("studio", "논의에서 시작")}</strong>
              <span class="text-base-content/70">
                {dgettext("studio", " — 사실관계, 거래 배경부터 정리한 뒤 초안")}
              </span>
            </li>
            <li>
              <strong>{dgettext("studio", "다른 문서에서 변형 만들기")}</strong>
              <span class="text-base-content/70">
                {dgettext("studio", " — 기존 문서의 유형 변환")}
              </span>
            </li>
          </ol>
          <p class="mt-2 text-base-content/70">
            {dgettext("studio", "무엇으로 시작할까요?")}
          </p>

          <div
            class="flex flex-wrap gap-2 mt-3"
            data-role="chat-no-doc-options"
          >
            <button
              :for={opt <- @start_options}
              type="button"
              phx-click="agent_option_picked"
              phx-value-key={opt.key}
              data-role="chat-no-doc-option"
              data-option-key={opt.key}
              class="btn btn-sm btn-ghost border border-base-300 rounded-full font-normal normal-case shadow-none hover:bg-base-200"
            >
              {opt.label}
            </button>
          </div>
        </div>
      </div>

      <%!-- Streamed conversation. Single scroll + stream container —
           no inner wrapper. --%>
      <div
        id={"#{@id}-stream"}
        phx-update="stream"
        data-role="chat-stream"
        class="flex-1 min-h-0 overflow-y-auto px-3 py-3 flex flex-col items-stretch gap-3"
      >
        <article
          :for={{dom_id, msg} <- @streams.chat_messages}
          :if={msg_visible?(msg)}
          id={dom_id}
          data-role="chat-message"
          data-message-role={msg_role(msg)}
          data-message-kind={msg_kind(msg)}
          data-transient={msg_transient?(msg)}
          phx-click={tool_call_toggle_js(msg)}
          phx-keydown={tool_call_toggle_js(msg)}
          phx-key={tool_call_toggle_key(msg)}
          role={tool_call_toggle_role(msg)}
          tabindex={tool_call_toggle_tabindex(msg)}
          aria-expanded={tool_call_aria_expanded(msg)}
          aria-controls={tool_call_aria_controls(msg)}
          class={
            [
              "group/message relative flex flex-col items-stretch gap-0.5 w-full",
              msg_role(msg) == "agent" && "self-start",
              # Collapse the parent stream's gap-3 between adjacent agent-side
              # articles so a tool_call row and the agent text that follows
              # read as a single turn rather than two separate messages.
              # Negative top margin on the *next* agent article cancels the
              # gap. Applied via Tailwind's next-sibling variant on this
              # element when it's an agent article.
              msg_role(msg) == "agent" && "[&+[data-message-role=agent]]:!-mt-3",
              tool_call_message?(msg) &&
                "cursor-pointer focus-visible:outline focus-visible:outline-1 focus-visible:outline-offset-1 focus-visible:outline-base-content/20"
            ]
          }
        >
          <.operation_block
            :if={msg_operation(msg)}
            operation={msg_operation(msg)}
            transient?={msg_transient?(msg) == "true"}
          />
          <%!-- User message: full-width rounded card (Codex CLI style).
               Slightly elevated background distinguishes the input echo
               from the agent's flat prose without needing a colored fill
               or a chat-tail pill. --%>
          <div
            :if={is_nil(msg_operation(msg)) and msg_role(msg) == "user"}
            class="w-full border border-base-content/10 bg-base-300/50 px-3 py-1.5 text-[13px] leading-snug whitespace-normal break-words text-base-content/95 shadow-[inset_0_1px_3px_rgba(0,0,0,0.10)]"
          >
            {msg_body(msg)}
          </div>

          <%!-- Agent message: flat prose, no card. Sits flush at the
               column edge like ChatGPT / Codex CLI. `agent-text` span is
               the per-token append target; body is split on \n\n+ into
               paragraph spans so paragraph breaks render with a real
               gap instead of being collapsed into one block. --%>
          <span
            :if={is_nil(msg_operation(msg)) and msg_role(msg) == "agent"}
            data-role="agent-text"
            data-message-id={dom_id}
            aria-busy={msg_transient?(msg)}
            class="block px-3 py-1 text-[14px] leading-relaxed break-words text-base-content"
          >
            <% paragraphs = agent_paragraphs(msg) %>
            <%= for {para, index} <- Enum.with_index(paragraphs) do %>
              <span
                data-role="agent-paragraph"
                class="block whitespace-normal [&:not(:last-child)]:mb-1"
              >
                {para}
                <span
                  :if={agent_loading?(msg) and index == length(paragraphs) - 1}
                  data-role="agent-loading"
                  role="status"
                  aria-label={dgettext("studio", "답변 작성 중")}
                  class="ml-1 inline-flex h-4 translate-y-[0.125rem] items-end gap-0.5 align-baseline text-base-content/45"
                >
                  <span
                    aria-hidden="true"
                    class="size-1 rounded-full bg-current motion-safe:animate-bounce [animation-delay:-240ms]"
                  >
                  </span>
                  <span
                    aria-hidden="true"
                    class="size-1 rounded-full bg-current motion-safe:animate-bounce [animation-delay:-120ms]"
                  >
                  </span>
                  <span
                    aria-hidden="true"
                    class="size-1 rounded-full bg-current motion-safe:animate-bounce"
                  >
                  </span>
                </span>
              </span>
            <% end %>
          </span>

          <time
            :if={not is_nil(msg_timestamp(msg)) and is_nil(msg_operation(msg))}
            datetime={msg_timestamp(msg)}
            class="text-[10px] text-base-content/35 self-end whitespace-nowrap"
          >
            {format_msg_time(msg_timestamp(msg))}
          </time>
        </article>
      </div>

      <%!-- Input footer — icon upload + message input + icon send.
           The row shape is identical on desktop and mobile. --%>
      <%!-- No `phx-submit` here — the colocated ChatInput hook is the
           single source of truth for sending. Keeping both produces a
           duplicate user message (empty + real) per turn. --%>
      <form
        id={"#{@id}-form"}
        phx-hook=".ChatInput"
        data-role="chat-form"
        class={[
          "border-t border-base-300 bg-base-200 shrink-0 px-3 py-2",
          @mobile? && "pb-[max(0.5rem,env(safe-area-inset-bottom))]"
        ]}
        autocomplete="off"
      >
        <%!-- Codex-style composer: full-width textarea on top, a faint
             meta row underneath (left = upload affordance, right = send
             arrow). Mono placeholder reads as a CLI prompt. --%>
        <div class="rounded-md border border-base-300 bg-base-100 focus-within:border-base-content/40 transition-colors">
          <label for={"#{@id}-textarea"} class="sr-only">
            {dgettext("studio", "메시지")}
          </label>
          <textarea
            id={"#{@id}-textarea"}
            name="message"
            rows="1"
            data-role="chat-textarea"
            data-autosize="true"
            placeholder={dgettext("studio", "메시지를 입력하세요 · Enter 보내기, Shift+Enter 줄바꿈")}
            class="block w-full min-h-[2.25rem] max-h-40 px-3 pt-2 pb-1 bg-transparent border-0 text-[13px] leading-snug text-base-content placeholder:text-base-content/35 resize-none outline-none focus:outline-none focus:ring-0 focus:shadow-none"
          ></textarea>
          <div class="flex items-center justify-between gap-2 px-2 pb-1.5 pt-0.5 text-[11px] text-base-content/45">
            <div class="flex items-center gap-1">
              <button
                id={"#{@id}-upload"}
                type="button"
                data-role="chat-upload"
                phx-click="agent_option_picked"
                phx-value-key="upload"
                class="inline-flex h-6 w-6 items-center justify-center rounded text-base-content/45 hover:text-base-content hover:bg-base-200 transition-colors"
                aria-label={dgettext("studio", "파일 업로드")}
              >
                <.icon name="hero-paper-clip" class="size-3.5" />
              </button>
            </div>
            <%= if @agent_status.key == :responding do %>
              <button
                id={"#{@id}-send"}
                type="button"
                phx-click="cancel_agent"
                data-role="chat-stop"
                data-action="stop"
                class="inline-flex h-6 w-6 items-center justify-center rounded bg-base-content text-base-100 hover:bg-base-content/80 transition-colors"
                aria-label={dgettext("studio", "중지")}
              >
                <.icon name="hero-stop" class="size-3.5" />
              </button>
            <% else %>
              <button
                id={"#{@id}-send"}
                type="button"
                data-role="chat-send"
                data-action="send"
                class="inline-flex h-6 w-6 items-center justify-center rounded text-base-content/45 hover:text-base-content transition-colors"
                aria-label={dgettext("studio", "보내기")}
              >
                <.icon name="hero-paper-airplane" class="size-3.5" />
              </button>
            <% end %>
          </div>
        </div>
      </form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatInput">
        export default {
          mounted() {
            this.form = this.el

            // Resolve the live textarea each call — morphdom may swap the node
            // across patches, so a cached ref can go stale.
            const textarea = () => this.form.querySelector('[data-role="chat-textarea"]')

            this.send = (e) => {
              if (e) e.preventDefault()
              const ta = textarea()
              if (!ta) return
              const value = ta.value
              if (!value || !value.trim()) return
              // chat.submit is handled by the parent StudioLive — pushEvent
              // from a LiveComponent-hosted hook still routes to the root LV.
              this.pushEvent("chat.submit", { message: value })
              ta.value = ""
              this.autosize()
              // Keep focus on the textarea so the mobile keyboard never hides.
              ta.focus({ preventScroll: true })
            }

            this.autosize = () => {
              const ta = textarea()
              if (!ta) return
              if (ta.dataset.autosize !== "true") return
              ta.style.height = "auto"
              const next = Math.min(ta.scrollHeight, 128)
              ta.style.height = next + "px"
            }

            // Event delegation on the stable <form> node. This is robust
            // against morphdom replacing the button or textarea subtree —
            // listeners on direct refs would silently break after a patch.
            this.onFormKeydown = (e) => {
              if (e.target.matches('[data-role="chat-textarea"]')
                  && e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                this.send(e)
              }
            }

            this.onFormInput = (e) => {
              if (e.target.matches('[data-role="chat-textarea"]')) this.autosize()
            }

            // Mobile (iOS Safari) regression fix: tapping the send button
            // fires `blur` on the textarea, which dismisses the keyboard.
            // With `h-[100dvh]` the layout reflows mid-tap and the `click`
            // never lands. Calling preventDefault() on pointerdown/mousedown
            // for the send button stops the focus shift, so the textarea
            // stays focused, the keyboard stays open, no reflow happens,
            // and the subsequent `click` fires cleanly.
            this.onFormPointerDown = (e) => {
              const btn = e.target.closest('[data-role="chat-send"]')
              if (btn && this.form.contains(btn)) e.preventDefault()
            }

            this.onFormClick = (e) => {
              const btn = e.target.closest('[data-role="chat-send"]')
              if (btn && this.form.contains(btn)) this.send(e)
            }

            this.onFormSubmit = (e) => this.send(e)

            // Live token streaming: per-delta `agent_text_append` events
            // bypass LV's stream-diff cycle (which would batch successive
            // stream_inserts into one render). We split each piece on
            // double-newlines so paragraph breaks land in their own
            // child span (matching the SSR shape from chat_rail.ex), and
            // get a controlled gap via `mb-1.5` instead of a full blank
            // line from whitespace-pre-wrap.
            this.onAppend = (e) => {
              const id = e.detail && e.detail.message_id
              const piece = e.detail && e.detail.piece
              if (!id || !piece) return
              const container = document.querySelector(
                `[data-role="agent-text"][data-message-id="${id}"]`
              )
              if (!container) return
              const paraClass = "block whitespace-normal [&:not(:last-child)]:mb-1"
              const paraSelector = '[data-role="agent-paragraph"]'
              const mkPara = () => {
                const s = document.createElement("span")
                s.dataset.role = "agent-paragraph"
                s.className = paraClass
                container.appendChild(s)
                return s
              }
              // First real token arriving: kill the bouncing-dots indicator.
              // Keeping it alive would just have it trail the prose as new
              // text streams in (the old behaviour moved it from paragraph
              // to paragraph), which reads as a stray glyph next to the
              // agent's words.
              const dropLoading = () => {
                const indicator = container.querySelector('[data-role="agent-loading"]')
                if (indicator) indicator.remove()
              }
              const appendText = (target, text) => {
                target.appendChild(document.createTextNode(text))
              }
              const paragraphs = container.querySelectorAll(paraSelector)
              let current = paragraphs[paragraphs.length - 1] || mkPara()
              dropLoading()
              const parts = piece.split(/\n{2,}/)
              appendText(current, parts[0])
              for (let i = 1; i < parts.length; i++) {
                current = mkPara()
                appendText(current, parts[i])
              }
            }
            window.addEventListener("phx:agent_text_append", this.onAppend)

            // Same trick for the reasoning stream. Without this, every
            // reasoning_summary delta (hundreds per turn) re-sent the
            // entire accumulated buffer through LV diffs and the text
            // arrived in big chunks instead of flowing.
            this.onReasoningAppend = (e) => {
              const id = e.detail && e.detail.message_id
              const piece = e.detail && e.detail.piece
              if (!id || !piece) return
              const span = document.querySelector(
                `[data-role="agent-reasoning-text"][data-message-id="${id}"]`
              )
              if (span && span.dataset.placeholder === "true") {
                span.textContent = ""
                span.dataset.placeholder = "false"
              }
              if (span) span.appendChild(document.createTextNode(piece))
              const details = document.querySelector(
                `[data-role="agent-reasoning-details-text"][data-message-id="${id}"]`
              )
              if (details) details.appendChild(document.createTextNode(piece))
            }
            window.addEventListener("phx:agent_reasoning_append", this.onReasoningAppend)

            // Sticky-bottom auto-scroll. Watches the chat-stream container
            // (which is also the scrollable viewport) for ANY DOM change
            // (stream_inserts, TextNode appends, etc.) and pulls the
            // viewport to bottom — but only while the user is already
            // pinned there. As soon as they scroll up to read earlier
            // turns we stop forcing them back down.
            this.scroller = document.querySelector('[data-role="chat-stream"]')
            if (this.scroller) {
              this.pinned = true
              const pinThreshold = 80
              this.onScroll = () => {
                const distance =
                  this.scroller.scrollHeight - this.scroller.scrollTop - this.scroller.clientHeight
                this.pinned = distance < pinThreshold
              }
              this.scroller.addEventListener("scroll", this.onScroll, { passive: true })

              this.scrollObserver = new MutationObserver(() => {
                if (this.pinned) this.scroller.scrollTop = this.scroller.scrollHeight
              })
              this.scrollObserver.observe(this.scroller, {
                childList: true,
                subtree: true,
                characterData: true
              })

              // Initial position at the bottom.
              this.scroller.scrollTop = this.scroller.scrollHeight
            }

            this.form.addEventListener("keydown", this.onFormKeydown)
            this.form.addEventListener("input", this.onFormInput)
            this.form.addEventListener("pointerdown", this.onFormPointerDown)
            this.form.addEventListener("mousedown", this.onFormPointerDown)
            this.form.addEventListener("click", this.onFormClick)
            this.form.addEventListener("submit", this.onFormSubmit)

            this.autosize()
          },
          destroyed() {
            if (this.onAppend) window.removeEventListener("phx:agent_text_append", this.onAppend)
            if (this.onReasoningAppend) window.removeEventListener("phx:agent_reasoning_append", this.onReasoningAppend)
            if (this.scrollObserver) this.scrollObserver.disconnect()
            if (this.scroller && this.onScroll) this.scroller.removeEventListener("scroll", this.onScroll)
            if (!this.form) return
            this.form.removeEventListener("keydown", this.onFormKeydown)
            this.form.removeEventListener("input", this.onFormInput)
            this.form.removeEventListener("pointerdown", this.onFormPointerDown)
            this.form.removeEventListener("mousedown", this.onFormPointerDown)
            this.form.removeEventListener("click", this.onFormClick)
            this.form.removeEventListener("submit", this.onFormSubmit)
          }
        }
      </script>
    </aside>
    """
  end

  attr :operation, :map, required: true
  attr :transient?, :boolean, default: false

  def operation_block(assigns) do
    assigns =
      assigns
      |> assign(:operation_id, operation_id(assigns.operation))
      |> assign(:operation_type, operation_type(assigns.operation))
      |> assign(:operation_status, operation_status(assigns.operation))
      |> assign(:operation_title, operation_title(assigns.operation))
      |> assign(:operation_summary, operation_summary(assigns.operation))

    ~H"""
    <%= if @operation_type in ["tool_call", "reasoning"] do %>
      <%!-- Codex-style inline trace row used for both tool calls and
           reasoning summaries. Visually identical: tiny wrench glyph + dim
           "<Label>: <one-liner>". The whole article carries the click
           handler (a `Phoenix.LiveView.JS` toggle, set on the <article>
           by the stream loop above) — child elements stay inert
           (`pointer-events-none`) so child clicks bubble cleanly. We
           render both the collapsed affordance AND the expanded details
           panel; the panel starts `hidden` and `JS.toggle_attribute`
           flips it client-side. Phoenix.LiveView streams don't re-render
           already-inserted items on outer assign changes, so any
           server-side expand state would never reach the DOM after the
           first insertion. --%>
      <div class={[
        "group/trace relative flex w-full items-center gap-1 px-3 py-1.5",
        @operation_type == "reasoning" && @transient? && "animate-pulse"
      ]}>
        <div
          id={"tool-trace-#{@operation_id}"}
          data-role="tool-trace"
          data-status={@operation_status}
          class={[
            "tool-trace inline-flex min-w-0 items-center gap-1.5 py-0.5 text-left text-[12px] leading-snug transition",
            @operation_status == "running" &&
              "text-base-content/45 animate-pulse",
            @operation_status == "completed" &&
              "text-base-content/55 hover:text-base-content/80",
            @operation_status == "failed" && "text-error/80"
          ]}
        >
          <.icon name="hero-wrench-screwdriver" class="size-3.5 shrink-0 opacity-70" />
          <span class="truncate">
            <span class="select-none">{operation_prefix_label(@operation_type)}: </span>
            <%= if @operation_type == "reasoning" do %>
              <span
                data-role="agent-reasoning-text"
                data-message-id={"chat-msg-reasoning-#{reasoning_run_id(@operation_id)}"}
                data-placeholder={reasoning_text_placeholder?(@operation_summary)}
                title={operation_reasoning_full(@operation)}
                class="min-w-0 truncate whitespace-nowrap"
              >
                {reasoning_text_or_placeholder(@operation_summary)}
              </span>
            <% else %>
              <span class="font-mono">{@operation_title}</span>
            <% end %>
            <span
              :if={@operation_type == "tool_call" and @operation_summary != ""}
              data-role="tool-trace-summary"
              class="ml-1 text-base-content/40"
            >
              {@operation_summary}
            </span>
          </span>
        </div>
        <span
          id={"tool-trace-#{@operation_id}-expand"}
          data-role="tool-trace-expand"
          data-visible={tool_trace_expand_visible(@operation_status)}
          title={tool_trace_expand_label(@operation_status)}
          aria-label={tool_trace_expand_label(@operation_status)}
          class={[
            "absolute right-0 top-1/2 inline-flex size-6 -translate-y-1/2 items-center justify-center text-base-content/55 transition pointer-events-none",
            @operation_status == "failed" && "opacity-100 text-error/80",
            @operation_status != "failed" &&
              "opacity-0 group-hover/message:opacity-100 group-hover/trace:opacity-100"
          ]}
        >
          <.icon name="hero-chevron-down" class="size-3" />
        </span>
      </div>
      <div
        id={"tool-trace-#{@operation_id}-details"}
        data-role="tool-trace-details"
        hidden
        class="self-start w-full max-w-full"
      >
        <div class="rounded-md border border-base-300 bg-base-100 px-3 py-2 font-mono text-[11px] leading-relaxed text-base-content/60 shadow-sm">
          <pre
            data-role={reasoning_details_data_role(@operation_type)}
            data-message-id={
              @operation_type == "reasoning" &&
                "chat-msg-reasoning-#{reasoning_run_id(@operation_id)}"
            }
            class="whitespace-pre-wrap break-words"
          >{operation_expanded_body(@operation_type, @operation)}</pre>
        </div>
        <div data-role="tool-trace-collapse-row" class="flex justify-center pt-1">
          <span
            id={"tool-trace-#{@operation_id}-collapse"}
            data-role="tool-trace-collapse"
            title={dgettext("studio", "접기")}
            aria-label={dgettext("studio", "접기")}
            class="inline-flex items-center gap-1 text-[11px] text-base-content/55 pointer-events-none"
          >
            <.icon name="hero-chevron-up" class="size-3" />
            {dgettext("studio", "접기")}
          </span>
        </div>
      </div>
    <% else %>
      <section
        id={"operation-block-#{@operation_id}"}
        data-role="operation-block"
        data-operation-type={@operation_type}
        data-operation-status={@operation_status}
        class={[
          "w-full rounded-md border border-base-300 bg-base-100 text-base-content shadow-sm overflow-hidden",
          @operation_type == "tool_call" && "tool-trace"
        ]}
      >
        <button
          id={"operation-block-#{@operation_id}-toggle"}
          type="button"
          aria-expanded="false"
          aria-controls={"operation-block-#{@operation_id}-details"}
          phx-click={
            JS.toggle_attribute({"hidden", "hidden"},
              to: "#operation-block-#{@operation_id}-details"
            )
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            |> JS.toggle(to: "#operation-block-#{@operation_id}-toggle [data-role='chev-right']")
            |> JS.toggle(to: "#operation-block-#{@operation_id}-toggle [data-role='chev-down']")
          }
          class="flex w-full items-start gap-2 px-3 py-2 text-left transition hover:bg-base-200/70"
        >
          <span
            data-role="chev-right"
            class="mt-0.5 size-4 shrink-0 text-base-content/50 hero-chevron-right"
          />
          <span
            data-role="chev-down"
            style="display: none;"
            class="mt-0.5 size-4 shrink-0 text-base-content/50 hero-chevron-down"
          />
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span class="truncate text-xs font-semibold uppercase text-base-content/60">
                {operation_label(@operation_type)}
              </span>
              <span class="rounded-full bg-base-200 px-1.5 py-0.5 text-[10px] font-medium text-base-content/60">
                {operation_status_label(@operation_status)}
              </span>
            </div>
            <p class="truncate text-sm font-medium text-base-content">{@operation_title}</p>
            <p :if={@operation_summary != ""} class="mt-0.5 text-xs text-base-content/60">
              {@operation_summary}
            </p>
          </div>
        </button>
        <div
          :if={@operation_type == "evidence"}
          data-role="evidence-block"
          class="border-t border-base-200 bg-base-50 px-3 py-2 text-xs text-base-content/70"
        >
          <div class="flex items-start justify-between gap-3">
            <dl class="grid min-w-0 flex-1 grid-cols-[auto_1fr] gap-x-2 gap-y-1">
              <dt class="text-base-content/50">인용</dt>
              <dd class="truncate font-medium text-base-content">{evidence_citation(@operation)}</dd>
              <dt class="text-base-content/50">출처</dt>
              <dd class="truncate">{evidence_source(@operation)}</dd>
              <dt class="text-base-content/50">수집 시각</dt>
              <dd>
                <time datetime={evidence_captured_at(@operation)}>
                  {evidence_captured_at(@operation)}
                </time>
              </dd>
            </dl>
            <button
              :if={evidence_snapshot_id(@operation)}
              type="button"
              data-role="evidence-attach"
              phx-click="evidence.attach"
              phx-value-evidence_snapshot_id={evidence_snapshot_id(@operation)}
              class="inline-flex size-8 shrink-0 items-center justify-center rounded-md border border-base-300 text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
              aria-label={dgettext("studio", "근거 연결")}
            >
              <.icon name="hero-link" class="size-4" />
            </button>
          </div>
        </div>
        <div
          :if={@operation_type == "source_interpretation"}
          data-role="source-interpretation-block"
          class="border-t border-base-200 bg-base-50 px-3 py-2 text-xs text-base-content/70"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="font-medium text-base-content">{dgettext("studio", "원문 문서")}</span>
            <span>{source_claim_count_label(length(source_operation_claims(@operation)))}</span>
          </div>
          <ul
            :if={source_operation_regions(@operation) != []}
            class="mt-2 space-y-1"
            data-role="source-regions"
          >
            <li :for={region <- source_operation_regions(@operation)} class="truncate">
              <span>{detail_value(region, "raw_text")}</span>
            </li>
          </ul>
          <ul
            :if={source_operation_claims(@operation) != []}
            class="mt-2 space-y-1"
            data-role="source-claims"
          >
            <li
              :for={claim <- source_operation_claims(@operation)}
              class="rounded border border-base-200 px-2 py-1"
            >
              <span class="font-medium">{claim_kind_label(claim)}</span>
              <span class="ml-1">{claim_value(claim)}</span>
            </li>
          </ul>
        </div>
        <div
          :if={@operation_type == "source_claim"}
          data-role="source-claim-block"
          class="border-t border-base-200 bg-base-50 px-3 py-2 text-xs text-base-content/70"
        >
          <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2 gap-y-1">
            <dt class="font-medium text-base-content/60">항목</dt>
            <dd>{source_claim_field_label(@operation)}</dd>
            <dt class="font-medium text-base-content/60">값</dt>
            <dd>{source_claim_value(@operation)}</dd>
            <dt class="font-medium text-base-content/60">신뢰도</dt>
            <dd>{source_claim_confidence(@operation)}</dd>
          </dl>
          <ul
            :if={source_claim_anchors(@operation) != []}
            class="mt-2 space-y-1"
            data-role="source-claim-anchors"
          >
            <li
              :for={anchor <- source_claim_anchors(@operation)}
              class="rounded border border-base-200 px-2 py-1"
            >
              <span :if={detail_value(anchor, "page")}>p.{detail_value(anchor, "page")}</span>
              <span>{detail_value(anchor, "text") || inspect(anchor)}</span>
            </li>
          </ul>
          <div class="mt-2 flex flex-wrap gap-1.5" data-role="source-claim-controls">
            <button
              type="button"
              class="btn btn-xs btn-primary"
              phx-click="source_claim.confirm"
              phx-value-source_claim_id={source_claim_id(@operation)}
              phx-value-source_document_id={source_document_id(@operation)}
            >
              확정
            </button>
            <details class="group/correct" data-role="source-claim-correct-panel">
              <summary class="btn btn-xs list-none marker:hidden">
                수정
              </summary>
              <.form
                for={source_claim_correction_form(@operation)}
                id={"source-claim-correct-form-#{source_claim_id(@operation)}"}
                phx-submit="source_claim.correct"
                data-role="source-claim-correct-form"
                class="mt-2 flex w-full min-w-64 items-end gap-2 rounded-md border border-base-200 bg-base-100 p-2"
              >
                <input type="hidden" name="source_claim_id" value={source_claim_id(@operation)} />
                <input type="hidden" name="source_document_id" value={source_document_id(@operation)} />
                <.input
                  id={"source-claim-correct-value-#{source_claim_id(@operation)}"}
                  name="value"
                  type="text"
                  value={source_claim_value(@operation)}
                  class="input input-xs min-w-0 flex-1"
                />
                <button type="submit" class="btn btn-xs btn-primary">저장</button>
              </.form>
            </details>
            <button
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="source_claim.reject"
              phx-value-source_claim_id={source_claim_id(@operation)}
              phx-value-source_document_id={source_document_id(@operation)}
            >
              반려
            </button>
            <button
              type="button"
              class="btn btn-xs"
              phx-click="source_claim.link_to_document"
              phx-value-source_claim_id={source_claim_id(@operation)}
              phx-value-source_document_id={source_document_id(@operation)}
            >
              문서에 연결
            </button>
            <button
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="source_claim.unlink"
              phx-value-source_claim_id={source_claim_id(@operation)}
              phx-value-source_document_id={source_document_id(@operation)}
            >
              연결 해제
            </button>
          </div>
        </div>
        <div
          id={"operation-block-#{@operation_id}-details"}
          data-role="operation-details"
          hidden
          class="border-t border-base-200 bg-base-50 px-3 py-2"
        >
          <pre class="whitespace-pre-wrap break-words text-xs leading-relaxed text-base-content/70">{operation_details(@operation)}</pre>
        </div>
      </section>
    <% end %>
    """
  end

  # ----------------------------------------------------------------------------
  # Status pill helpers
  # ----------------------------------------------------------------------------

  @doc false
  def agent_status(%{agent_run_id: nil}), do: %{key: :idle, label: status_idle()}

  def agent_status(%{agent_run_id: id}) when is_binary(id),
    do: %{key: :responding, label: status_busy()}

  def agent_status(_), do: %{key: :idle, label: status_idle()}

  defp status_idle, do: dgettext("studio", "대기 중")
  defp status_busy, do: dgettext("studio", "응답 중…")

  # ----------------------------------------------------------------------------
  # Observer / persona helpers
  # ----------------------------------------------------------------------------

  @doc false
  # agent_supervised persona perm signature: has agent_run + write + commit
  # but lacks both :export and :type_change. This is the unique fingerprint
  # vs. lawyer (has both), paralegal (has type_change), viewer (no write),
  # admin (has both).
  def observer_mode?(%{perms: perms}) when is_list(perms) do
    :agent_run in perms and :write in perms and :commit in perms and
      :export not in perms and :type_change not in perms
  end

  def observer_mode?(_), do: false

  # ----------------------------------------------------------------------------
  # Header helpers
  # ----------------------------------------------------------------------------

  defp chat_thread_title(%{title: title}) when is_binary(title) and title != "",
    do: title

  defp chat_thread_title(_), do: dgettext("studio", "새 대화")

  defp chat_context_empty?(%{message_count: count}) when is_integer(count), do: count == 0
  defp chat_context_empty?(_), do: true

  # ----------------------------------------------------------------------------
  # No-document welcome — SPEC.md §10. When the LV mounts WITHOUT a selected
  # document, the chat shows a pre-canned agent message with 5 quick-start
  # options. Each chip emits `agent_option_picked` with a `key`, which the
  # parent StudioLive handles uniformly.
  # ----------------------------------------------------------------------------

  @doc false
  def no_document?(%Contract.Studio.State{mode: :no_document}), do: true
  def no_document?(%{mode: :no_document}), do: true
  def no_document?(_), do: false

  @doc false
  def start_options do
    [
      %{key: "recent", label: dgettext("studio", "최근 문서 열기")},
      %{key: "blank", label: dgettext("studio", "빈 계약서 만들기")},
      %{key: "draft_from_discussion", label: dgettext("studio", "논의에서 시작")},
      %{key: "variant_from_other", label: dgettext("studio", "다른 문서에서 변형 만들기")}
    ]
  end

  # ----------------------------------------------------------------------------
  # Grill helpers — the parent decides whether the latest agent message has
  # unanswered ask-marks; we just render the sub-component when told.
  # ----------------------------------------------------------------------------

  defp resolve_grill_active?(assigns) do
    cond do
      assigns[:grill_active?] == true -> true
      Map.get(assigns[:studio_state] || %{}, :grill_active?) == true -> true
      true -> false
    end
  end

  # ----------------------------------------------------------------------------
  # Message field extractors — the stream items use a few shapes:
  #
  #   * user message:   %{id, role: :user, body, timestamp}
  #   * agent stream:   %{id, role: :agent, event: <event>, transient?: true}
  #   * agent complete: %{id, role: :agent, result: <result>, transient?: false}
  # ----------------------------------------------------------------------------

  defp msg_operation(%{operation: operation}) when is_map(operation), do: operation
  defp msg_operation(%{"operation" => operation}) when is_map(operation), do: operation
  defp msg_operation(_), do: nil

  defp tool_call_message?(msg), do: match?(%{}, tool_call_operation(msg))

  # The whole article carries a `Phoenix.LiveView.JS` toggle that flips
  # the `hidden` attribute on the details panel and the article's
  # aria-expanded — pure client-side, no server roundtrip. The chevron
  # and the 접기 sub-elements stay `pointer-events-none` so a click
  # anywhere on the row bubbles to the article handler exactly once.
  # We can't drive expand state from a server assign because
  # `phx-update="stream"` items don't re-render when outer assigns
  # change — that was the "freshly-inserted tool_call won't expand,
  # reload doesn't fix it" regression.
  defp tool_call_toggle_js(msg) do
    case tool_call_operation(msg) do
      nil ->
        nil

      operation ->
        operation_id = operation_id(operation)

        # Attribute selector (not `#id`) — tool ids like
        # `tool-{run_id}-doc.get` contain dots, which CSS would parse as
        # class separators and miss the element entirely.
        JS.toggle_attribute({"hidden", "hidden"},
          to: ~s([id="tool-trace-#{operation_id}-details"])
        )
        |> JS.toggle_attribute({"aria-expanded", "true", "false"})
    end
  end

  defp tool_call_toggle_key(msg) do
    if tool_call_message?(msg), do: "Enter"
  end

  defp tool_call_toggle_role(msg) do
    if tool_call_message?(msg), do: "button"
  end

  defp tool_call_toggle_tabindex(msg) do
    if tool_call_message?(msg), do: "0"
  end

  defp tool_call_aria_expanded(msg) do
    if tool_call_message?(msg), do: "false"
  end

  defp tool_call_aria_controls(msg) do
    case tool_call_operation(msg) do
      nil -> nil
      operation -> "tool-trace-#{operation_id(operation)}-details"
    end
  end

  defp tool_call_operation(msg) do
    case msg_operation(msg) do
      operation when is_map(operation) ->
        if operation_type(operation) in ["tool_call", "reasoning"], do: operation

      _ ->
        nil
    end
  end

  defp operation_id(operation), do: operation_value(operation, "id") || Ecto.UUID.generate()
  defp operation_type(operation), do: operation_value(operation, "type") || "operation"
  defp operation_status(operation), do: operation_value(operation, "status") || "pending"

  defp operation_title(operation) do
    case operation_type(operation) do
      "source_claim" ->
        dgettext("studio", "%{field} 확인", field: source_claim_field_label(operation))

      _ ->
        operation_value(operation, "title") || operation_label(operation_type(operation))
    end
  end

  defp operation_summary(operation) do
    case operation_type(operation) do
      "source_interpretation" ->
        source_claim_count_label(length(source_operation_claims(operation)))

      _ ->
        operation_value(operation, "summary") || operation_value(operation, "body") || ""
    end
  end

  defp evidence_snapshot_id(operation), do: operation_value(operation, "evidence_snapshot_id")

  defp evidence_source(operation) do
    operation
    |> operation_value("source")
    |> source_label(operation_value(operation, "provider"))
  end

  defp evidence_citation(operation),
    do: operation_value(operation, "citation") || operation_title(operation)

  defp evidence_captured_at(operation), do: operation_value(operation, "captured_at") || ""

  defp operation_details_map(operation) do
    case operation_value(operation, "details") do
      details when is_map(details) -> stringify_detail_keys(details)
      _ -> %{}
    end
  end

  defp stringify_detail_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp source_operation_claims(operation),
    do: operation |> operation_details_map() |> Map.get("claims", []) |> List.wrap()

  defp source_operation_regions(operation),
    do: operation |> operation_details_map() |> Map.get("regions", []) |> List.wrap()

  defp source_claim_id(operation),
    do: operation_details_map(operation)["source_claim_id"] || operation_value(operation, "id")

  defp source_claim_correction_form(operation),
    do: Phoenix.Component.to_form(%{"value" => source_claim_value(operation)})

  defp source_document_id(operation),
    do: operation_details_map(operation)["source_document_id"] || ""

  defp source_claim_anchors(operation) do
    details = operation_details_map(operation)

    (details["anchors"] || get_in(details, ["proposed_structured", "anchors"]) || [])
    |> List.wrap()
  end

  defp source_claim_confidence(operation),
    do: operation |> operation_details_map() |> Map.get("confidence") |> display_value()

  defp source_claim_field(operation) do
    details = operation_details_map(operation)
    details["proposed_kind"] || details["field"] || details["field_id"] || ""
  end

  defp source_claim_field_label(operation), do: source_claim_field(operation) |> field_label()

  defp source_claim_value(operation) do
    details = operation_details_map(operation)
    details["user_value"] || details["value"] || details["proposed_value"] || ""
  end

  defp display_value(nil), do: ""
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_integer(value), do: Integer.to_string(value)
  defp display_value(value) when is_float(value), do: Float.to_string(value)
  defp display_value(value), do: inspect(value)

  defp claim_kind(claim),
    do: detail_value(claim, "proposed_kind") || detail_value(claim, "kind") || ""

  defp claim_kind_label(claim), do: claim |> claim_kind() |> field_label()

  defp claim_value(claim),
    do: detail_value(claim, "proposed_value") || detail_value(claim, "value") || ""

  defp detail_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp detail_value(_map, _key), do: nil

  defp operation_details(operation) do
    details = operation_value(operation, "details") || operation

    case Jason.encode(details, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(details, pretty: true)
    end
  end

  defp operation_value(operation, key) when is_map(operation) do
    Map.get(operation, key) || Map.get(operation, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(operation, key)
  end

  defp operation_value(_operation, _key), do: nil

  defp operation_label("tool_call"), do: "도구 실행"
  defp operation_label("source_interpretation"), do: "원문 해석"
  defp operation_label("source_claim"), do: "추출값"
  defp operation_label("evidence"), do: "근거"
  defp operation_label("export_status"), do: "내보내기"
  defp operation_label("conversion_plan"), do: "변환 계획"

  defp operation_label(type) when is_binary(type), do: dgettext("studio", "작업")

  defp operation_label(_), do: "작업"

  defp tool_trace_expand_visible("failed"), do: "true"
  defp tool_trace_expand_visible(_status), do: "false"

  defp tool_trace_expand_label("failed"), do: dgettext("studio", "실패 세부 정보")
  defp tool_trace_expand_label(_status), do: dgettext("studio", "펼치기")

  defp operation_status_label("completed"), do: dgettext("studio", "완료")
  defp operation_status_label("ready"), do: dgettext("studio", "준비됨")
  defp operation_status_label("proposed"), do: dgettext("studio", "제안됨")
  defp operation_status_label("pending"), do: dgettext("studio", "대기")
  defp operation_status_label("failed"), do: dgettext("studio", "실패")
  defp operation_status_label(status) when is_binary(status), do: dgettext("studio", "진행 중")
  defp operation_status_label(_), do: dgettext("studio", "진행 중")

  defp source_claim_count_label(count), do: dgettext("studio", "추출값 %{count}개", count: count)

  defp source_label(source, provider) do
    source = to_string(source || "")
    provider = to_string(provider || "")

    cond do
      String.contains?(provider, "law_mcp") or String.contains?(source, "Korea Law MCP") ->
        dgettext("studio", "법령 검색 결과")

      source == "" ->
        dgettext("studio", "제공된 근거")

      true ->
        dgettext("studio", "제공된 근거")
    end
  end

  defp field_label("effective_date"), do: dgettext("studio", "효력 발생일")
  defp field_label("party_a"), do: dgettext("studio", "갑")
  defp field_label("party_b"), do: dgettext("studio", "을")
  defp field_label("counterparty"), do: dgettext("studio", "상대방")
  defp field_label("contract_amount"), do: dgettext("studio", "계약 금액")
  defp field_label("payment_terms"), do: dgettext("studio", "지급 조건")
  defp field_label("term"), do: dgettext("studio", "계약 기간")
  defp field_label(value) when is_binary(value) and value != "", do: dgettext("studio", "문서 항목")
  defp field_label(_), do: dgettext("studio", "문서 항목")

  defp msg_role(%{role: :user}), do: "user"
  defp msg_role(%{role: "user"}), do: "user"
  defp msg_role(%{role: :agent}), do: "agent"
  defp msg_role(%{role: "agent"}), do: "agent"
  defp msg_role(%{role: :assistant}), do: "agent"
  defp msg_role(%{role: "assistant"}), do: "agent"
  defp msg_role(_), do: "agent"

  defp msg_transient?(%{transient?: true}), do: "true"
  defp msg_transient?(_), do: "false"

  defp msg_kind(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp msg_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp msg_kind(_), do: "text"

  defp msg_visible?(msg) do
    # Legacy `kind: :reasoning` rows with no operation are filtered out —
    # the production path now persists reasoning as an `operation` map and
    # the `:agent_reasoning_done` handler deletes the streaming bubble
    # when the body ends up empty. Keeping the guard prevents stale ghost
    # rows in tests / older serialized state.
    not (is_nil(msg_operation(msg)) and msg_kind(msg) == "reasoning")
  end

  defp reasoning_text_or_placeholder(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> dgettext("studio", "생각 중")
      text -> text
    end
  end

  defp reasoning_text_or_placeholder(_), do: dgettext("studio", "생각 중")

  defp reasoning_text_placeholder?(summary) when is_binary(summary) do
    if String.trim(summary) == "", do: "true", else: "false"
  end

  defp reasoning_text_placeholder?(_), do: "true"

  defp reasoning_run_id("reasoning-" <> rest), do: rest
  defp reasoning_run_id(id) when is_binary(id), do: id
  defp reasoning_run_id(_), do: ""

  defp reasoning_details_data_role("reasoning"), do: "agent-reasoning-details-text"
  defp reasoning_details_data_role(_), do: nil

  defp operation_prefix_label("reasoning"), do: "Thinking"
  defp operation_prefix_label(_), do: "Tool"

  defp operation_reasoning_full(operation) do
    details = operation_details_map(operation)
    Map.get(details, "text", "")
  end

  defp operation_expanded_body("reasoning", operation), do: operation_reasoning_full(operation)
  defp operation_expanded_body(_, operation), do: operation_details(operation)

  # Show the bouncing-dots indicator only while the message is in-flight
  # AND has no visible body yet. Once the first token has landed, drop the
  # dots — otherwise the indicator keeps trailing the prose as the JS hook
  # ferries it from paragraph to paragraph during streaming.
  defp agent_loading?(msg) do
    msg_transient?(msg) == "true" and (msg_body(msg) || "") == ""
  end

  defp agent_paragraphs(msg), do: String.split(msg_body(msg) || "", ~r/\n{2,}/)

  defp msg_body(%{body: body}) when is_binary(body), do: body
  defp msg_body(%{body: body}) when is_binary(body), do: collapse_blanks(body)
  defp msg_body(%{result: %{body: body}}) when is_binary(body), do: collapse_blanks(body)
  defp msg_body(%{result: result}) when is_binary(result), do: collapse_blanks(result)
  defp msg_body(%{event: %{delta: delta}}) when is_binary(delta), do: collapse_blanks(delta)
  defp msg_body(%{event: %{body: body}}) when is_binary(body), do: collapse_blanks(body)
  defp msg_body(%{event: %{text: text}}) when is_binary(text), do: collapse_blanks(text)
  defp msg_body(%{event: text}) when is_binary(text), do: collapse_blanks(text)
  defp msg_body(_), do: ""

  # `whitespace-pre-wrap` renders every `\n` as a literal line break,
  # so the model's `\n\n` paragraph breaks read as a full empty line of
  # line-height. Collapse runs of 2+ newlines to a single one to keep
  # message density tight without losing paragraph boundaries.
  defp collapse_blanks(text) when is_binary(text),
    do: String.replace(text, ~r/\n{2,}/, "\n")

  defp msg_timestamp(%{timestamp: %DateTime{} = ts}), do: DateTime.to_iso8601(ts)
  defp msg_timestamp(%{timestamp: ts}) when is_binary(ts), do: ts
  defp msg_timestamp(_), do: nil

  # Compact wall-time HH:MM for the message side-marker. Falls back to the
  # raw string if parsing fails so tests / non-iso inputs don't crash.
  defp format_msg_time(nil), do: ""

  defp format_msg_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> format_kst(dt)
      _ -> ts
    end
  end

  defp format_msg_time(%DateTime{} = dt), do: format_kst(dt)
  defp format_msg_time(_), do: ""

  # Render in Korea Standard Time (UTC+9, no DST → safe to hard-shift
  # without a tzdata dependency). Display-only — the underlying DateTime
  # stays tagged UTC in the DB.
  defp format_kst(%DateTime{} = dt) do
    dt
    |> DateTime.add(9 * 3600, :second)
    |> Calendar.strftime("%Y/%m/%d %H:%M")
  end
end
