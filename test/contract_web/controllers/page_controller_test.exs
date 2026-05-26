defmodule ContractWeb.PageControllerTest do
  use ContractWeb.ConnCase

  @moduledoc """
  Landing page assertions for the v0.5/design-landing surface
  (DESIGN.md §3). The landing is Korean-primary; PageController.home
  pins the Gettext locale to "ko" so msgids render through ko/landing.po.

  These tests pin the *intent* of the v31 design:

    * Three conceptual blocks (`포맷 → IR 정규화` / `AI가 먼저 묻는 핵심
      질문` / `답이 곧 계약 조항`). Block copy is customer-facing
      Korean only — no internal module/class names (e.g. "StudioLive")
      may appear on this surface.
    * Three-line serif headline (`복잡한 문서 프로토콜을,` / `병렬 하네스로` /
      `패키지합니다.`).
    * A primary `보관함 열기` CTA that targets `/dashboard` for
      authenticated users and `/users/log-in` for anonymous users.
    * A secondary `작동 방식 보기 →` link that anchors to `#how-it-works`.
    * The Westlaw silhouette test (see the bottom of this file).
  """

  describe "GET /" do
    test "renders the Korean-primary v31 headline ladder", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "복잡한 문서 프로토콜을,"
      assert body =~ "병렬 하네스로"
      assert body =~ "패키지합니다."
    end

    test "renders the lead paragraph in Korean", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "한국어 계약서를 손볼 때,"
      assert body =~ "AI 에이전트가 먼저 필요한 조건을 묻고"
      assert body =~ "그 답을 그대로 조항으로 옮겨 적습니다."
    end

    test "renders the three conceptual blocks (DESIGN.md §3)", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "포맷 → IR 정규화"
      assert body =~ "AI가 먼저 묻는 핵심 질문"
      assert body =~ "답이 곧 계약 조항"
      # And the numbered eyebrows on each block.
      assert body =~ ~s(data-eyebrow="01")
      assert body =~ ~s(data-eyebrow="02")
      assert body =~ ~s(data-eyebrow="03")
    end

    test "landing pitch is about writing the contract, not logging history", %{conn: conn} do
      # Product positioning: convenient legal-document writing — NOT a
      # change-history / audit tool. The "변경 이력" / "기록" /
      # "흔적" framing belongs in-product (Studio), not on the
      # landing surface where it confuses what the product does.
      body = conn |> get(~p"/") |> html_response(200)
      [_pre, body_block] = String.split(body, ~s(data-landing="v31"), parts: 2)
      [landing_body, _post] = String.split(body_block, "</main>", parts: 2)

      refute landing_body =~ "변경 이력"
      refute landing_body =~ "흔적"
    end

    test "landing copy contains no internal product jargon", %{conn: conn} do
      # The landing surface speaks the customer's language: no
      # module / class / function names from the codebase. If you find
      # yourself wanting to add one, write the customer-facing Korean
      # phrase instead.
      body = conn |> get(~p"/") |> html_response(200)
      [_pre, body_block] = String.split(body, ~s(data-landing="v31"), parts: 2)
      [landing_body, _post] = String.split(body_block, "</main>", parts: 2)

      refute landing_body =~ "StudioLive"
      refute landing_body =~ "RunServer"
      refute landing_body =~ "agent.ask"
      refute landing_body =~ "commit · diff"
      refute landing_body =~ "brief.md"
    end

    test "renders the eyebrow + secondary CTA anchor", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "계약기계"
      assert body =~ "작동 방식 보기"
      assert body =~ ~s(href="#how-it-works")
      assert body =~ ~s(id="how-it-works")
    end

    test "anonymous user gets `보관함 열기` pointing to /users/log-in", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "보관함 열기"
      # Anonymous primary CTA targets log-in, never /dashboard.
      assert body =~ ~s(href="/users/log-in")
      refute body =~ ~s(href="/storage")
    end

    test "authenticated user gets `보관함 열기` pointing to /storage", %{conn: conn} do
      user = Contract.AccountsFixtures.user_fixture()
      body = conn |> log_in_user(user) |> get(~p"/") |> html_response(200)
      assert body =~ "보관함 열기"
      assert body =~ ~s(href="/storage")
      refute body =~ ~s(href="/users/log-in")
    end

    test "renders the small private-beta footnote", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "비공개 베타. 초청제로 운영합니다."
    end

    test "exposes the hamburger drawer toggle on mobile (chrome unchanged)", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s(id="mobile-nav-drawer")
      assert body =~ ~s(for="mobile-nav-drawer")
    end
  end

  # Responsive guarantees previously asserted by grepping app.css for
  # hand-written .landing-v31__* / .dashboard-v31__* selectors. Those
  # rules moved to Tailwind utilities at the call sites, so the test
  # now pins the rendered markup intent instead: the landing landmark
  # carries data-landing="v31", and each conceptual block carries
  # data-landing-block. See feedback-responsive-scope.md — public
  # surfaces remain mobile-first.
  describe "responsive landmark contract" do
    test "landing main exposes the data-landing marker", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s(data-landing="v31")
    end

    test "three conceptual blocks each carry the data-landing-block marker", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      block_count =
        ~r/data-landing-block/
        |> Regex.scan(body)
        |> length()

      assert block_count == 3
    end
  end

  describe "Westlaw silhouette test — v31 design hard constraints" do
    # These assertions guard against the public surface drifting back
    # toward a generic SaaS-pop visual language. They cover both the
    # banned utility classes (rounded-2xl / shadow-xl / text-6xl /
    # font-black) and the banned copy ("Powered by AI", "transform",
    # "revolutionize", "seamless"). The whole-page body is checked so
    # the test catches any reintroduction from a partial / nav / footer
    # change, not just the landing template proper.

    setup %{conn: conn} do
      %{body: conn |> get(~p"/") |> html_response(200)}
    end

    test "no banned utility classes inside the landing body", %{body: body} do
      [_pre, body_block] = String.split(body, ~s(data-landing="v31"), parts: 2)
      [landing_body, _post] = String.split(body_block, "</main>", parts: 2)

      refute landing_body =~ "rounded-2xl"
      refute landing_body =~ "shadow-xl"
      refute landing_body =~ "text-6xl"
      refute landing_body =~ "font-black"
    end

    test "no banned marketing copy anywhere on the page", %{body: body} do
      refute body =~ "Powered by AI"
      refute body =~ "powered by AI"
      refute body =~ "revolutionize"
      refute body =~ "Revolutionize"
      refute body =~ "seamless"
      refute body =~ "Seamless"
      # "transform" appears in CSS (transition properties, transform)
      # only via vendored stylesheets; the landing body must not use
      # it as copy. Scope the assertion to the landing container.
      [_pre, body_block] = String.split(body, ~s(data-landing="v31"), parts: 2)
      [landing_body, _post] = String.split(body_block, "</main>", parts: 2)
      refute landing_body =~ "transform"
      refute landing_body =~ "Transform"
    end

    test "no pricing block, no feature-card grid, no hero image of the product", %{body: body} do
      refute body =~ ~s(id="pricing")
      refute body =~ "Per-seat"
      # The old hero illustration is gone; the three-block right column
      # replaces it.
      refute body =~ "/images/landing/hero.png"
    end

    test "landing CTA is a real daisyUI button, not a marketing pop pill", %{body: body} do
      [_pre, body_block] = String.split(body, ~s(data-landing="v31"), parts: 2)
      [landing_body, _post] = String.split(body_block, "</main>", parts: 2)
      # The landing CTA migrated to daisyUI `btn btn-primary` (matches the
      # studio emerald primary). Earlier the design forbade this utility
      # to avoid saas-pop styling; once daisyUI's `primary` was retuned to
      # our muted emerald the rule inverted — we now require it so the
      # landing button is structurally identical to every other primary
      # action in the product.
      assert landing_body =~ "btn btn-primary"
      # `btn-ghost` is still banned from the landing body — ghost buttons
      # are reserved for in-product chrome, not marketing surfaces.
      refute landing_body =~ "btn-ghost"
    end
  end
end
