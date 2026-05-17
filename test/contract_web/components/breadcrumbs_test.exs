defmodule ContractWeb.Components.BreadcrumbsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ContractWeb.Components.Breadcrumbs

  # A minimal scope stub. We don't depend on Contract.Context here because
  # `build/2` only pattern-matches on `:user` — keeping the test tight and
  # independent of the auth module.
  defp scope(user \\ %{id: 1, email: "u@example.com"}) do
    %{user: user}
  end

  describe "breadcrumbs/1 rendering" do
    test "empty trail renders nothing" do
      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: [])

      assert html == "" or not (html =~ "<nav")
      refute html =~ "aria-current"
    end

    test "single Dashboard crumb renders as the current page (no link)" do
      trail = [%{label: "Dashboard", navigate: nil, current?: true}]
      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      assert html =~ ~s(aria-label="Breadcrumb")
      assert html =~ ~s(aria-current="page")
      assert html =~ "Dashboard"
      refute html =~ ~s(<a href)
      refute html =~ ~s(<a data-phx-link)
    end

    test "studio trail with document section renders 3 crumbs, last is current" do
      trail = [
        %{label: "Dashboard", navigate: "/dashboard", current?: false},
        %{label: "Documents", navigate: "/dashboard", current?: false},
        %{label: "Term Sheet v3", navigate: nil, current?: true}
      ]

      html = render_component(&Breadcrumbs.breadcrumbs/1, trail: trail)

      assert html =~ "Dashboard"
      assert html =~ "Documents"
      assert html =~ "Term Sheet v3"
      assert html =~ ~s(href="/dashboard")
      assert html =~ ~s(href="/dashboard")
      # The last crumb is plain text, not a link
      assert html =~ ~s(aria-current="page")

      # And it should appear inside a span, not an <a>
      [_, after_aria] = String.split(html, ~s(aria-current="page"), parts: 2)
      refute after_aria =~ ~r/\A[^<]*<a /

      # 3 list items
      assert length(Regex.scan(~r/<li/, html)) == 3
    end

    test "long labels truncate visually but preserve full label in title=, threshold label intact" do
      long_label = String.duplicate("x", 80)
      long_trail = [%{label: long_label, navigate: nil, current?: true}]
      long_html = render_component(&Breadcrumbs.breadcrumbs/1, trail: long_trail)

      # Full label preserved as title=; display is shorter; ellipsis sentinel present.
      assert long_html =~ ~s(title="#{long_label}")
      refute long_html =~ ~s(>#{long_label}<)
      assert long_html =~ "&hellip;" or long_html =~ "…"

      # Input map not mutated (truncation is display-only).
      [crumb] = long_trail
      assert crumb.label == long_label

      # Labels at the threshold are NOT truncated.
      label_40 = String.duplicate("a", 40)

      short_html =
        render_component(&Breadcrumbs.breadcrumbs/1,
          trail: [%{label: label_40, navigate: nil, current?: true}]
        )

      assert short_html =~ label_40
      refute short_html =~ "&hellip;"
      refute short_html =~ "…"
    end
  end

  describe "build/2 — trail construction" do
    test "returns [] for unauthenticated / user-less / unknown-page scopes" do
      assert Breadcrumbs.build(nil, page: :dashboard) == []
      assert Breadcrumbs.build(%{user: nil}, page: :dashboard) == []
      assert Breadcrumbs.build(scope(), page: :mystery) == []
    end

    test "dashboard: single current Dashboard crumb" do
      assert Breadcrumbs.build(scope(), page: :dashboard) ==
               [%{label: "Dashboard", navigate: nil, current?: true}]
    end

    test "settings: 3 crumbs with custom page label, default label = 'Account'" do
      custom = Breadcrumbs.build(scope(), page: :settings, settings_label: "Email & password")

      assert custom == [
               %{label: "Dashboard", navigate: "/dashboard", current?: false},
               %{label: "Settings", navigate: "/users/settings", current?: false},
               %{label: "Email & password", navigate: nil, current?: true}
             ]

      assert List.last(Breadcrumbs.build(scope(), page: :settings)) ==
               %{label: "Account", navigate: nil, current?: true}
    end

    # Document-pivot (SPEC.md 2026-05-15): Matter is internal context.
    # Studio trail collapses to 2 crumbs — Dashboard > (Document.title | Studio).
    test "studio: matter is always dropped; trail is Dashboard > (Document | Studio)" do
      matter = %{id: "m_42", name: "Acme/NewCo merger"}
      document = %{id: "d_1", title: "Term Sheet v3"}

      dashboard_crumb = %{label: "Dashboard", navigate: "/dashboard", current?: false}

      # With matter + document → document name wins.
      assert Breadcrumbs.build(scope(), page: :studio, matter: matter, document: document) ==
               [dashboard_crumb, %{label: "Term Sheet v3", navigate: nil, current?: true}]

      # With matter only → "Studio" fallback.
      assert Breadcrumbs.build(scope(), page: :studio, matter: matter) ==
               [dashboard_crumb, %{label: "Studio", navigate: nil, current?: true}]

      # No matter, no document → "Studio" fallback.
      assert Breadcrumbs.build(scope(), page: :studio) ==
               [dashboard_crumb, %{label: "Studio", navigate: nil, current?: true}]

      # Document only (no matter) → document name.
      assert Breadcrumbs.build(scope(),
               page: :studio,
               document: %{id: "d_1", title: "Untitled draft"}
             ) ==
               [dashboard_crumb, %{label: "Untitled draft", navigate: nil, current?: true}]
    end
  end
end
