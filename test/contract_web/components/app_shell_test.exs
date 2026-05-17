defmodule ContractWeb.Components.AppShellTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ContractWeb.Components.AppShell

  describe "app_shell/1" do
    test "renders v33 shared topbar with brand icon, dashboard link, studio label, and no upload action" do
      inner_block = [
        %{
          __slot__: :inner_block,
          inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<main id="shell-content">문서 목록</main>)) end
        }
      ]

      html =
        render_component(&AppShell.app_shell/1,
          active: "대시보드",
          inner_block: inner_block
        )

      assert html =~ ~s(class="app-shell")
      assert html =~ ~s(class="topbar")
      assert html =~ ~s(href="/")
      assert html =~ ~s(src="/assets/icons/brand-mark.svg")
      assert html =~ "Contract Studio"
      assert html =~ ~s(href="/dashboard")
      assert html =~ "대시보드"
      assert html =~ "스튜디오"
      assert html =~ "shell-content"
      assert html =~ "문서 목록"
      assert html =~ "is-active"
      refute html =~ "계약서 업로드"
      refute html =~ "새 문서"
    end

    test "v33 icon source assets are tracked outside generated static assets" do
      app_root = Path.expand("../../..", __DIR__)
      icon_dir = Path.join(app_root, "priv/static/images/icons")

      for icon <-
            ~w(brand-mark document upload search chevron-down more-vertical send check clock history) do
        path = Path.join(icon_dir, "#{icon}.svg")
        relative_path = Path.relative_to(path, app_root)

        assert File.exists?(path)
        assert {_, 1} = System.cmd("git", ["check-ignore", "-q", relative_path], cd: app_root)
      end
    end
  end
end
