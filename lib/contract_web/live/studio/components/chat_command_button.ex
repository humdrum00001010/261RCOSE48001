defmodule ContractWeb.Live.Studio.Components.ChatCommandButton do
  @moduledoc """
  Mobile-only command affordance for the ChatRail input footer (Wave 3C1).

  Replaces the desktop `Cmd+K` CommandPalette on touch devices, which lack a
  meta-key chord. The component renders a single icon-only button to the left
  of the chat input. Tapping it opens a bottom-sheet modal (DaisyUI
  `modal modal-bottom modal-open`) that lists the same actions as the desktop
  palette, filtered by the active persona's perms.

  Reuse:

    * The command catalog is sourced from
      `ContractWeb.Components.CommandPalette.available_commands/1` so the
      mobile sheet always stays in sync with the desktop palette.

    * Only `{:emit, :command_palette_picked, payload}` commands and
      `{:navigate, path}` commands surface — `{:mode, _}` sub-modes
      (`:search_law`, `:search_documents`, `:info`) are desktop-only because
      they require keyboard-driven typeahead the mobile button does not host.

  Hard constraints:

    * Renders nothing on `:viewport == :desktop` (the global Cmd+K palette is
      already mounted in the app layout).

    * Emits events back to the parent LV with `phx-click="command_palette_picked"`
      and `phx-value-action_kind="<kind>"` so the Studio LV's
      `event_to_command/3` funnel can route to the right Action.

    * Component-local state (sheet open / closed) is owned by the live
      component; the parent LV does not need to track it.

  Korean copy:

    * Sheet header reads "명령어" (Commands) with "Commands" as the English
      fallback.
    * The trigger button has an aria-label of "명령어 열기" (Open commands).
  """
  use ContractWeb, :live_component

  alias ContractWeb.Components.CommandPalette
  alias ContractWeb.Components.CommandPalette.Command

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :current_scope, :map, required: true
  attr :current_document_id, :any, default: nil
  attr :viewport, :atom, default: :mobile

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :sheet_open?, false)}
  end

  @impl true
  def update(assigns, socket) do
    current_scope = Map.get(assigns, :current_scope)
    studio_state = Map.get(assigns, :studio_state)

    current_document_id =
      Map.get(assigns, :current_document_id) || selected_document_id(studio_state)

    socket =
      socket
      |> assign(:id, Map.fetch!(assigns, :id))
      |> assign(:current_scope, current_scope)
      |> assign(:current_document_id, current_document_id)
      |> assign(:studio_state, studio_state)
      |> assign(:viewport, Map.get(assigns, :viewport, :mobile))
      |> assign(:commands, sheet_commands(current_scope, current_document_id))

    # `:initial_open?` is a test-only assign — set it from `render_component`
    # to force the sheet open without simulating the tap.
    socket =
      case Map.get(assigns, :initial_open?, false) do
        true -> assign(socket, :sheet_open?, true)
        _ -> socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("open_sheet", _params, socket) do
    {:noreply, assign(socket, :sheet_open?, true)}
  end

  def handle_event("close_sheet", _params, socket) do
    {:noreply, assign(socket, :sheet_open?, false)}
  end

  # --- Render -----------------------------------------------------------

  @impl true
  def render(%{viewport: :desktop} = assigns) do
    # Desktop uses the global Cmd+K palette — render nothing.
    ~H"""
    <span id={@id} data-role="chat-command-button-skipped" hidden />
    """
  end

  def render(assigns) do
    ~H"""
    <div id={@id} class="lg:hidden" data-role="chat-command-button">
      <button
        type="button"
        class="btn btn-ghost btn-sm btn-square text-base-content/70 hover:text-base-content"
        phx-click="open_sheet"
        phx-target={@myself}
        aria-label="명령어 열기 / Open commands"
        data-role="chat-command-trigger"
      >
        <.icon name="hero-command-line" class="size-5" />
      </button>

      <dialog
        :if={@sheet_open?}
        id={"#{@id}-sheet"}
        class="modal modal-bottom modal-open"
        role="dialog"
        aria-modal="true"
        aria-label="명령어 / Commands"
        data-role="chat-command-sheet"
      >
        <div class="modal-box bg-base-100 p-0 max-h-[80vh] flex flex-col">
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-200">
            <h2 class="text-sm font-semibold tracking-tight">
              명령어 <span class="ml-2 text-xs text-base-content/50">Commands</span>
            </h2>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="close_sheet"
              phx-target={@myself}
              aria-label="닫기 / Close"
              data-role="chat-command-close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div
            class="flex-1 overflow-y-auto py-2"
            data-role="chat-command-list"
          >
            <%= if @commands == [] do %>
              <p class="px-4 py-6 text-center text-sm text-base-content/50">
                사용할 수 있는 명령어가 없습니다.
                <span class="block text-xs text-base-content/40 mt-1">
                  No commands available.
                </span>
              </p>
            <% else %>
              <ul class="list-none">
                <li :for={cmd <- @commands}>
                  {render_row(assign(assigns, :cmd, cmd))}
                </li>
              </ul>
            <% end %>
          </div>

          <div class="border-t border-base-200 px-3 py-2 text-[11px] text-base-content/50 flex items-center justify-between">
            <span>탭하여 실행 / Tap to run</span>
            <span class="font-mono">⌘K</span>
          </div>
        </div>

        <button
          type="button"
          class="modal-backdrop"
          phx-click="close_sheet"
          phx-target={@myself}
          aria-label="닫기 / Close"
        >
          close
        </button>
      </dialog>
    </div>
    """
  end

  defp render_row(assigns) do
    ~H"""
    <button
      type="button"
      class="w-full text-left px-4 py-3 flex items-center justify-between gap-3 text-sm hover:bg-base-200/60 active:bg-base-200 border-b border-base-200/40 last:border-b-0"
      data-cmd-id={@cmd.id}
      data-cmd-group={@cmd.group}
      data-role="chat-command-row"
      {row_event_attrs(@cmd)}
    >
      <span class="flex flex-col min-w-0">
        <span class="truncate font-medium">{@cmd.label}</span>
        <span :if={@cmd.hint} class="text-xs text-base-content/50 truncate">
          {@cmd.hint}
        </span>
      </span>
      <.icon name="hero-chevron-right" class="size-4 text-base-content/30 shrink-0" />
    </button>
    """
  end

  # Build the `phx-*` attribute list for a row given its command action.
  # Returns a keyword list usable in HEEx attribute splat.
  defp row_event_attrs(%Command{action: {:emit, _kind, payload}}) do
    action_kind = Map.get(payload, :action_kind) || Map.get(payload, "action_kind")

    [
      {:"phx-click", "command_palette_picked"},
      {:"phx-value-action_kind", action_kind},
      # Also expose `kind` so the existing Studio LV `event_to_command/3`
      # funnel (which matches on `%{"kind" => kind}`) routes the event
      # without per-event-name special casing. This keeps the on-the-wire
      # payload compatible with the desktop palette's push_event form
      # (which uses `action_kind`).
      {:"phx-value-kind", action_kind}
    ]
  end

  defp row_event_attrs(%Command{action: {:navigate, path}}) do
    [{:"phx-click", JS.navigate(path)}]
  end

  defp row_event_attrs(_cmd) do
    # `:mode` commands (search_law / search_documents / info) are
    # keyboard-driven sub-modes that the bottom-sheet doesn't host. They
    # are filtered out by `sheet_commands/1` so this clause exists as a
    # defensive no-op for forward-compat with future Command shapes.
    [{:disabled, "true"}]
  end

  # --- Catalog selection ------------------------------------------------

  @doc """
  Returns the persona-filtered command list the sheet should show.

  Filters the global palette catalog (single-source) down to commands the
  bottom-sheet can sensibly host:

    * `{:emit, _, _}` action commands — these route through the LV.
    * `{:navigate, _}` navigation commands — these issue a JS navigate.

  Sub-mode commands (`{:mode, _}`) are filtered out because the mobile
  bottom-sheet does not host typeahead search; users seeking law / document
  search on mobile reach for the dedicated panels.
  """
  @spec sheet_commands(map() | nil) :: [Command.t()]
  def sheet_commands(scope), do: sheet_commands(scope, nil)

  @doc false
  @spec sheet_commands(map() | nil, term()) :: [Command.t()]
  def sheet_commands(scope, current_document_id) do
    scope
    |> CommandPalette.available_commands(current_document_id: current_document_id)
    |> Enum.filter(&renderable?/1)
  end

  defp selected_document_id(%{selected_document_id: id}) when is_binary(id) and id != "", do: id
  defp selected_document_id(_), do: nil

  defp renderable?(%Command{action: {:emit, _, _}}), do: true
  defp renderable?(%Command{action: {:navigate, _}}), do: true
  defp renderable?(_), do: false
end
