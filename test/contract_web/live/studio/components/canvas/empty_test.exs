defmodule ContractWeb.Live.Studio.Components.Canvas.EmptyTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.Canvas.Empty

  # ---------------------------------------------------------------------------
  # Persona-perm fixtures (mirror Contract.PersonaFactory)
  # ---------------------------------------------------------------------------

  defp lawyer_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a
    }

  defp viewer_scope(user),
    do: %Context{Context.for_user(user) | perms: ~w(read)a}

  defp no_doc_state, do: %State{mode: :no_document, last_seen_revision: 0}

  defp render_empty(opts) do
    scope =
      Keyword.get_lazy(opts, :current_scope, fn -> lawyer_scope(user_fixture()) end)

    render_component(Empty,
      id: "canvas",
      studio_state: Keyword.get(opts, :studio_state, no_doc_state()),
      projection: Keyword.get(opts, :projection, %{nodes: %{}, fields: %{}, marks: %{}, refs: %{}}),
      current_scope: scope
    )
  end

  # ---------------------------------------------------------------------------
  # render_component cases
  # ---------------------------------------------------------------------------

  describe "render_component/2 — base render + persona gating" do
    test "renders the canvas-empty container with the illustration + headings" do
      html = render_empty([])

      assert html =~ ~s(data-stub="canvas-empty")
      assert html =~ ~s(data-role="canvas-empty")
      # Illustration reused from the dashboard empty-state.
      assert html =~ ~s(src="/images/landing/dashboard-empty.png")
      # Heading + subtitle (Korean primary).
      assert html =~ "문서를 선택하거나 새로 만드세요"
      assert html =~ "왼쪽에서 문서를 고르거나, 새 계약서를 시작합니다."
    end

    test "renders both action links for a lawyer (has :write)" do
      html = render_empty([])

      assert html =~ ~s(data-role="canvas-empty-actions")
      assert html =~ ~s(data-role="canvas-empty-new-document")
      assert html =~ ~s(data-role="canvas-empty-upload")
      assert html =~ ~s(phx-value-modal="new_document")
      assert html =~ ~s(phx-value-modal="upload")
      assert html =~ "+ 새 문서"
      assert html =~ "PDF 가져오기"
    end

    test "viewer persona sees illustration + copy but neither action link" do
      user = user_fixture()
      html = render_empty(current_scope: viewer_scope(user))

      # Body still rendered.
      assert html =~ "문서를 선택하거나 새로 만드세요"
      # …but actions container + buttons are hidden.
      refute html =~ ~s(data-role="canvas-empty-actions")
      refute html =~ "+ 새 문서"
      refute html =~ "PDF 가져오기"
      refute html =~ ~s(phx-value-modal="new_document")
      refute html =~ ~s(phx-value-modal="upload")
    end

    test "renders + 새 문서 link when current_scope.perms includes :write" do
      user = user_fixture()

      scope = %Context{
        Context.for_user(user)
        | perms: ~w(read write)a
      }

      html = render_empty(current_scope: scope)

      assert html =~ "+ 새 문서"
      assert html =~ "PDF 가져오기"
    end

    test "hides + 새 문서 link when current_scope.perms == [:read]" do
      user = user_fixture()
      scope = %Context{Context.for_user(user) | perms: ~w(read)a}

      html = render_empty(current_scope: scope)

      refute html =~ "+ 새 문서"
      refute html =~ "PDF 가져오기"
    end

    test "hides links when current_scope.perms is nil (defensive)" do
      user = user_fixture()
      scope = %Context{Context.for_user(user) | perms: nil}

      html = render_empty(current_scope: scope)

      refute html =~ "+ 새 문서"
      refute html =~ "PDF 가져오기"
    end

    test "Korean strings are precomposed Hangul syllables (no jamo decomposition)" do
      html = render_empty([])

      # Precomposed: each Korean character lives in the Hangul Syllables
      # block (U+AC00..U+D7A3). NFD-decomposed strings would contain
      # Hangul Jamo (U+1100..U+11FF) or compatibility jamo (U+3130..U+318F)
      # instead. Assert both: at least one syllable present, no decomposed
      # jamo runs in the rendered HTML.
      assert String.match?(html, ~r/[\x{AC00}-\x{D7A3}]/u)
      refute String.match?(html, ~r/[\x{1100}-\x{11FF}]/u)
      refute String.match?(html, ~r/[\x{3130}-\x{318F}]/u)

      # And the literal phrase round-trips byte-for-byte after NFC.
      assert html =~ :unicode.characters_to_nfc_binary("문서를 선택하거나 새로 만드세요")
    end
  end

  # ---------------------------------------------------------------------------
  # Click dispatch — the rendered `phx-click="open_modal"` (with the right
  # `phx-value-modal` param) flows up to StudioLive.handle_event/3, which
  # routes to `update_modal/3` and flips the relevant studio_state flag.
  #
  # We fire the events with `render_hook/3` against the live StudioLive
  # process directly — that bypasses DOM-element lookups (the default
  # mount path leaves `current_scope.perms == nil`, which correctly
  # *hides* the action buttons, so `element/2` wouldn't find them).
  # Component-side rendering (the actual `phx-click`+`phx-value-modal`
  # attributes that wire those buttons) is covered by the
  # `render_component/2` cases above.
  # ---------------------------------------------------------------------------

  describe "open_modal events route through StudioLive.handle_event/3" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "open_modal with modal=\"new_document\" is accepted (no flash error)",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      _ = render_hook(lv, "open_modal", %{"modal" => "new_document"})

      # `new_document` isn't a known `update_modal/3` key in the shell yet
      # (the modal-host subagent owns the routing). The contract we lock
      # here is that the click reaches handle_event/3 with the right
      # params and the LV stays alive — and importantly, no flash error
      # is set (which would indicate the event hit the fall-through
      # clause that calls event_to_action).
      assert Process.alive?(lv.pid)
      flash = :sys.get_state(lv.pid).socket.assigns.flash || %{}
      refute Map.get(flash, "error")
    end

    test "open_modal with modal=\"upload\" flips studio_state.upload_panel_open?",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      refute :sys.get_state(lv.pid).socket.assigns.studio_state.upload_panel_open?

      _ = render_hook(lv, "open_modal", %{"modal" => "upload"})

      assert :sys.get_state(lv.pid).socket.assigns.studio_state.upload_panel_open? == true
    end
  end
end
