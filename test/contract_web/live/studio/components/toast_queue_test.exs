defmodule ContractWeb.Live.Studio.Components.ToastQueueTest do
  # Tests assert against Korean copy (the primary i18n surface for
  # studio). Without a per-test locale pin, Gettext falls back to `:en`
  # and would return the English msgstrs from priv/gettext/en/.../studio.po.
  # async: false because Gettext locale is process-dictionary state and
  # would race the other studio component subagents during parallel runs.
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ContractWeb.Live.Studio.Components.ToastQueue

  setup do
    Gettext.put_locale(ContractWeb.Gettext, "ko")
    on_exit(fn -> Gettext.put_locale(ContractWeb.Gettext, "en") end)
    :ok
  end

  describe "render_component/2 with empty stream/list" do
    test "renders the queue container with no toast rows" do
      html =
        render_component(ToastQueue,
          id: "toast-queue",
          streams: %{toasts: []},
          toasts: []
        )

      assert html =~ ~s(id="toast-queue")
      assert html =~ ~s(data-stub="toast-queue")
      assert html =~ ~s(data-role="toast-queue")
      refute html =~ ~s(data-role="toast")
      refute html =~ ~s(data-role="toast-more")
    end
  end

  describe "level-specific rendering" do
    test ":info toast renders with the success left-border + info icon" do
      toast = %{
        id: "t-info-1",
        level: :info,
        title: "Hello",
        body: "An informational note.",
        link: nil
      }

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ ~s(role="alert")
      assert html =~ ~s(data-toast-level="info")
      assert html =~ "border-l-success"
      assert html =~ "hero-information-circle-mini"
      assert html =~ "Hello"
      assert html =~ "An informational note."
      # Auto-dismiss is driven by the JS hook; the hook is mounted on the
      # row so its data-toast-level attribute is what gates the timer.
      # The `.Toast` colocated hook expands to the LV-namespaced form.
      assert html =~ "phx-hook=\""
      assert html =~ "ToastQueue.Toast"
    end

    test ":warning toast renders with the warning left-border + triangle icon" do
      toast = %{id: "t-w-1", level: :warning, title: "Heads up", body: nil, link: nil}

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ "border-l-warning"
      assert html =~ "hero-exclamation-triangle-mini"
      assert html =~ "Heads up"
    end

    test ":error toast renders with the error left-border, no auto-dismiss data flag" do
      toast = %{id: "t-e-1", level: :error, title: "Boom", body: "Stack: …", link: nil}

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ "border-l-error"
      assert html =~ "hero-exclamation-circle-mini"
      assert html =~ ~s(data-toast-level="error")
      # The colocated hook only schedules dismissal for `:info`; the
      # `data-toast-level` attribute carries the signal. We assert the
      # error row is present and its level is "error" — the hook then
      # short-circuits in JS (`if (level !== "info") return`).
      assert html =~ "Boom"
      assert html =~ "Stack: …"
    end
  end

  describe "dismiss affordance" do
    test "each toast row carries a dismiss button with phx-click wired to dismiss_toast" do
      toast = %{id: "tid-1", level: :error, title: "Oops", body: nil, link: nil}

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ ~s(data-role="toast-dismiss")
      # JS.push and JS.hide both encode into the phx-click attribute; we
      # don't pin to the exact JSON shape, just that the operation chain
      # references dismiss_toast and the row id.
      assert html =~ "dismiss_toast"
      assert html =~ "tid-1"
      # Korean aria-label.
      assert html =~ ~s(aria-label="알림 닫기")
    end

    test "handle_event/3 dismiss_toast accepts the toast id without crashing the LC" do
      # LCs don't get their own pid; handle_event runs in the parent
      # LV's process. We can still drive the function directly to assert
      # it returns {:noreply, socket}.
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      assert {:noreply, _} =
               ToastQueue.handle_event("dismiss_toast", %{"toast_id" => "x"}, socket)
    end
  end

  describe "stacking / collapse" do
    test "6+ toasts collapses to '+ N 더 보기' link by default" do
      toasts =
        for i <- 1..7 do
          %{id: "t-#{i}", level: :info, title: "T#{i}", body: nil, link: nil}
        end

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: toasts
        )

      # The 5 most-recent are visible; 2 are hidden behind the "+ N 더 보기" link.
      assert html =~ ~s(data-role="toast-more")
      assert html =~ "2개 더 보기"
      # Spot-check that only 5 toast rows render (count unique row ids).
      assert Enum.count(1..5, fn i -> html =~ ~s(data-toast-id="t-#{i}") end) == 5
      refute html =~ ~s(data-toast-id="t-6")
      refute html =~ ~s(data-toast-id="t-7")
    end
  end

  describe "i18n / Hangul rendering" do
    test "Korean toast body renders as composed syllables (no jamo decomposition)" do
      # 안녕하세요 is in pre-composed (NFC) form. The font-stack fix in
      # commit 7fb7483 ensures jamo are NOT exposed in the DOM; we
      # assert here that the exact pre-composed UTF-8 bytes round-trip.
      toast = %{
        id: "ko-1",
        level: :info,
        title: "내보내기 준비 완료",
        body: "안녕하세요 — 다운로드 링크가 생성되었습니다.",
        link: nil
      }

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ "내보내기 준비 완료"
      assert html =~ "안녕하세요 — 다운로드 링크가 생성되었습니다."
      # No standalone jamo leaked in (a regression check against the
      # font fallback issue from fix/3). Specifically: a jamo ㅇ should
      # not appear isolated in the output.
      refute html =~ <<0xE3, 0x85, 0x87>>
    end

    test "viewport=mobile positions the queue along the bottom with center alignment" do
      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          viewport: :mobile,
          toasts: []
        )

      assert html =~ ~s(data-viewport="mobile")
      assert html =~ "bottom-20"
      assert html =~ "items-center"
    end

    test "viewport=desktop pins the queue to the bottom-right" do
      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: []
        )

      assert html =~ ~s(data-viewport="desktop")
      assert html =~ "bottom-4"
      assert html =~ "right-4"
      assert html =~ "items-end"
    end
  end

  describe "link affordance" do
    test "toast with a link map renders a navigate-style anchor with the label" do
      toast = %{
        id: "t-link",
        level: :info,
        title: "Export ready",
        body: nil,
        link: %{label: "Download", navigate: "/exports/abc"}
      }

      html =
        render_component(ToastQueue,
          id: "tq",
          streams: %{toasts: []},
          toasts: [toast]
        )

      assert html =~ "Download"
      assert html =~ "/exports/abc"
    end
  end
end
