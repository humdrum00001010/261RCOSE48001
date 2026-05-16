defmodule ContractWeb.Live.Studio.Components.ChatRail do
  @moduledoc """
  The central agent dialog surface (Wave 3C1 / chat-rail).

  Responsibilities:

    * Renders the streamed conversation (`@streams.chat_messages`) — both
      user-authored messages and agent bubbles (streamed + completed).
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
      |> assign(:start_options, start_options())

    ~H"""
    <aside
      id={@id}
      data-component="chat-rail"
      data-layout={if @mobile?, do: "mobile", else: "desktop"}
      data-stub="chat-rail"
      class={[
        "flex flex-col bg-base-100 min-h-0",
        not @mobile? && "w-[360px] border-l border-base-200",
        @mobile? && "w-full h-[100dvh]"
      ]}
    >
      <%!-- Header --%>
      <header class={[
        "flex items-center gap-2 px-4 py-3 border-b border-base-200 shrink-0",
        @mobile? && "py-2"
      ]}>
        <h2 :if={not @mobile?} class="font-medium text-sm text-base-content/80">
          {dgettext("studio", "에이전트")}
        </h2>

        <span
          data-role="agent-status-pill"
          data-status={@agent_status.key}
          class={[
            "ml-auto inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs",
            status_pill_class(@agent_status.key)
          ]}
        >
          <span
            :if={@agent_status.key == :responding}
            class="inline-block size-1.5 rounded-full bg-current animate-pulse"
            aria-hidden="true"
          >
          </span>
          {@agent_status.label}
        </span>
      </header>

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

      <%!-- Streamed conversation. The wrapper uses `:has()` to hide the
           welcome panel as soon as the stream contains a message. --%>
      <div
        id={"#{@id}-scroll"}
        data-role="chat-scroll"
        class="flex-1 min-h-0 overflow-y-auto px-4 py-3 group/chat"
      >
        <div
          :if={not @no_document?}
          id={"#{@id}-welcome"}
          data-role="chat-welcome"
          class="text-sm text-base-content/60 italic text-center py-8 group-has-[[data-role=chat-message]]/chat:hidden"
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
          class="group-has-[[data-role=chat-message]]/chat:hidden flex flex-col gap-3 max-w-[88%] self-start"
        >
          <div
            data-role="chat-message"
            data-message-role="agent"
            data-message-id="welcome-no-doc"
            class="rounded-lg bg-base-200 text-base-content text-sm px-3 py-2"
          >
            <p class="mb-2">{dgettext("studio", "새 문서를 시작합니다. 어떻게 시작할까요?")}</p>
            <ol class="list-decimal list-inside space-y-1 marker:text-base-content/60">
              <li>
                <strong>{dgettext("studio", "기존 계약서 업로드")}</strong>
                <span class="text-base-content/70">
                  {dgettext("studio", " — PDF, HWP, HWPX를 드래그하거나 선택")}
                </span>
              </li>
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

        <div
          id={"#{@id}-stream"}
          phx-update="stream"
          data-role="chat-stream"
          class="flex flex-col gap-3"
        >
          <article
            :for={{dom_id, msg} <- @streams.chat_messages}
            id={dom_id}
            data-role="chat-message"
            data-message-role={msg_role(msg)}
            data-transient={msg_transient?(msg)}
            class={[
              "flex flex-col gap-1 max-w-[88%]",
              msg_role(msg) == "user" && "self-end items-end ml-auto",
              msg_role(msg) == "agent" && "self-start items-start"
            ]}
          >
            <div class={[
              "rounded-lg px-3 py-2 text-sm whitespace-pre-wrap break-words",
              msg_role(msg) == "user" && "bg-primary text-primary-content",
              msg_role(msg) == "agent" && msg_transient?(msg) == "true" &&
                "bg-base-200 text-base-content/70 italic",
              msg_role(msg) == "agent" && msg_transient?(msg) == "false" &&
                "bg-base-200 text-base-content"
            ]}>
              {msg_body(msg)}
            </div>
            <time
              :if={msg_timestamp(msg)}
              datetime={msg_timestamp(msg)}
              class="text-[10px] text-base-content/40 px-1"
            >
              {msg_timestamp(msg)}
            </time>
          </article>
        </div>
      </div>

      <%!-- Input footer --%>
      <form
        id={"#{@id}-form"}
        phx-hook=".ChatInput"
        phx-submit="send_chat_message"
        data-role="chat-form"
        class={[
          "border-t border-base-200 bg-base-100 shrink-0 px-3 py-2",
          @mobile? && "pb-[max(0.5rem,env(safe-area-inset-bottom))]"
        ]}
        autocomplete="off"
      >
        <div class="flex items-end gap-2">
          <label for={"#{@id}-textarea"} class="sr-only">
            {dgettext("studio", "메시지")}
          </label>
          <div class="flex-1 [&_.fieldset]:!mb-0">
            <.input
              id={"#{@id}-textarea"}
              type="textarea"
              name="message"
              value=""
              rows="1"
              data-role="chat-textarea"
              data-autosize="true"
              placeholder={dgettext("studio", "메시지를 입력하세요…")}
              class="w-full textarea textarea-bordered textarea-sm resize-none min-h-[2.25rem] max-h-32"
            />
          </div>
          <button
            type="button"
            data-role="chat-send"
            data-action="send"
            class="btn btn-primary btn-sm shrink-0"
            aria-label={dgettext("studio", "보내기")}
          >
            {dgettext("studio", "보내기")}
          </button>
        </div>
        <p class="mt-1 text-[10px] text-base-content/40 px-1">
          {dgettext("studio", "Enter로 전송 · Shift+Enter로 줄바꿈")}
        </p>
      </form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatInput">
        export default {
          mounted() {
            this.form = this.el
            this.textarea = this.form.querySelector('[data-role="chat-textarea"]')
            this.sendButton = this.form.querySelector('[data-role="chat-send"]')

            this.send = (e) => {
              if (e) e.preventDefault()
              if (!this.textarea) return
              const value = this.textarea.value
              if (!value || !value.trim()) return
              this.pushEvent("send_chat_message", { message: value })
              this.textarea.value = ""
              this.autosize()
              // Keep focus on the textarea so the mobile keyboard never hides.
              this.textarea.focus({ preventScroll: true })
            }

            this.autosize = () => {
              if (!this.textarea) return
              if (this.textarea.dataset.autosize !== "true") return
              this.textarea.style.height = "auto"
              const next = Math.min(this.textarea.scrollHeight, 128)
              this.textarea.style.height = next + "px"
            }

            this.onKeydown = (e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                this.send(e)
              }
            }

            this.onInput = () => this.autosize()
            this.onClick = (e) => this.send(e)
            this.onSubmit = (e) => this.send(e)

            if (this.textarea) {
              this.textarea.addEventListener("keydown", this.onKeydown)
              this.textarea.addEventListener("input", this.onInput)
              this.autosize()
            }
            if (this.sendButton) {
              this.sendButton.addEventListener("click", this.onClick)
            }
            this.form.addEventListener("submit", this.onSubmit)
          },
          destroyed() {
            if (this.textarea) {
              this.textarea.removeEventListener("keydown", this.onKeydown)
              this.textarea.removeEventListener("input", this.onInput)
            }
            if (this.sendButton) {
              this.sendButton.removeEventListener("click", this.onClick)
            }
            if (this.form) {
              this.form.removeEventListener("submit", this.onSubmit)
            }
          }
        }
      </script>
    </aside>
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

  defp status_pill_class(:responding),
    do: "bg-primary/10 text-primary"

  defp status_pill_class(:error),
    do: "bg-error/10 text-error"

  defp status_pill_class(_),
    do: "bg-base-200 text-base-content/60"

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
      %{key: "upload", label: dgettext("studio", "기존 계약서 업로드")},
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

  defp msg_role(%{role: :user}), do: "user"
  defp msg_role(%{role: "user"}), do: "user"
  defp msg_role(%{role: :agent}), do: "agent"
  defp msg_role(%{role: "agent"}), do: "agent"
  defp msg_role(_), do: "agent"

  defp msg_transient?(%{transient?: true}), do: "true"
  defp msg_transient?(_), do: "false"

  defp msg_body(%{body: body}) when is_binary(body), do: body
  defp msg_body(%{result: %{body: body}}) when is_binary(body), do: body
  defp msg_body(%{result: result}) when is_binary(result), do: result
  defp msg_body(%{event: %{delta: delta}}) when is_binary(delta), do: delta
  defp msg_body(%{event: %{body: body}}) when is_binary(body), do: body
  defp msg_body(%{event: %{text: text}}) when is_binary(text), do: text
  defp msg_body(%{event: text}) when is_binary(text), do: text
  defp msg_body(_), do: ""

  defp msg_timestamp(%{timestamp: %DateTime{} = ts}), do: DateTime.to_iso8601(ts)
  defp msg_timestamp(%{timestamp: ts}) when is_binary(ts), do: ts
  defp msg_timestamp(_), do: nil
end
