defmodule ContractWeb.Live.Studio.Components.Canvas.EditorTest do
  @moduledoc """
  Wave 3C1 — Canvas.Editor component spec. Tests cover:

    1. All node kinds render (paragraph, heading, list, list_item, table fallback).
    2. `:write` perm gates `contenteditable`.
    3. The colocated `.Editable` hook is wired for debounced `edit_document`.
    4. Cmd+Z exposes `revoke_change` via the hook (assertion is on hook
       wiring + `data-can-revoke="true"`).
    5. `:revoke` perm gates Cmd+Z (viewer = no revoke).
    6. Revision-conflict assigns surface a `revision-conflict-toast`.
    7. Korean (Hangul) content survives round-trip cleanly — no jamo
       breakage from rendering.
  """

  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.Canvas.Editor

  # --- Persona-perm fixtures (mirror Contract.PersonaFactory) ---------

  defp lawyer_scope(user) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a
    }
  end

  defp paralegal_scope(user) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke type_change agent_run)a
    }
  end

  defp viewer_scope(user),
    do: %Context{Context.for_user(user) | perms: ~w(read)a}

  defp admin_scope(user) do
    %Context{
      Context.for_user(user)
      | perms:
          ~w(read write commit revoke export type_change agent_run tenant_admin matter_admin)a
    }
  end

  # --- Projection fixtures --------------------------------------------

  defp sample_projection() do
    %{
      title: "Sample Contract",
      type_key: :nda,
      metadata: %{},
      nodes: %{
        "h1" => %{id: "h1", kind: :heading, content: "보안 유지 계약서", attrs: %{level: 1}},
        "p1" => %{id: "p1", kind: :paragraph, content: "본 계약은 비밀 정보 보호를 목적으로 한다."},
        "p2" => %{id: "p2", kind: :paragraph, content: "양 당사자는 신의 성실 원칙을 따른다."},
        "l1" => %{id: "l1", kind: :list, children: ["li1", "li2"], attrs: %{ordered: true}},
        "li1" => %{id: "li1", kind: :list_item, content: "정의"},
        "li2" => %{id: "li2", kind: :list_item, content: "비밀 정보의 범위"},
        "t1" => %{
          id: "t1",
          kind: :table,
          attrs: %{rows: [["갑", "을"], ["회사 A", "회사 B"]]}
        }
      },
      node_order: ["h1", "p1", "p2", "l1", "t1"],
      fields: %{},
      marks: %{},
      refs: %{}
    }
  end

  defp empty_state(),
    do: %State{mode: :editing, last_seen_revision: 7, selected_node_id: nil}

  # Reads the colocated `.Editable` hook source directly from the
  # component module. LV 1.1 extracts the script and registers it via
  # `Phoenix.LiveView.ColocatedHook`, so it does NOT appear in the
  # `render_component/2` HTML — we read the source file instead.
  @editor_source File.read!(
                   Path.join([
                     File.cwd!(),
                     "lib/contract_web/live/studio/components/canvas/editor.ex"
                   ])
                 )

  defp editor_hook_source(), do: @editor_source

  defp render(scope, projection, opts \\ []) do
    render_component(
      Editor,
      Keyword.merge(
        [
          id: "canvas-editor",
          studio_state: empty_state(),
          projection: projection,
          current_scope: scope
        ],
        opts
      )
    )
  end

  # --- Tests ----------------------------------------------------------

  describe "render_component/2 — node kinds" do
    setup do
      %{user: user_fixture()}
    end

    test "renders every node kind from the projection (h1, p, ol, li, table)",
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())

      # heading
      assert html =~ "<h1"
      assert html =~ ~s(id="node-h1")
      assert html =~ "보안 유지 계약서"

      # paragraphs
      assert html =~ ~s(id="node-p1")
      assert html =~ "본 계약은 비밀 정보 보호를 목적으로 한다."
      assert html =~ ~s(id="node-p2")

      # ordered list + items
      assert html =~ "<ol"
      assert html =~ ~s(id="node-l1")
      assert html =~ ~s(id="node-li1")
      assert html =~ ~s(id="node-li2")
      assert html =~ "정의"
      assert html =~ "비밀 정보의 범위"

      # table (read-only fallback)
      assert html =~ ~s(id="node-t1")
      assert html =~ ~s(data-readonly="true")
      assert html =~ "회사 A"
    end

    test "uses contract-body wrapper and overflow-y-auto on the pane",
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())
      assert html =~ "contract-body"
      assert html =~ "overflow-y-auto"
      assert html =~ "max-w-3xl"
    end

    test "renders an empty-state when node_order is empty", %{user: user} do
      empty = %{
        title: nil,
        type_key: nil,
        metadata: %{},
        nodes: %{},
        node_order: [],
        fields: %{},
        marks: %{},
        refs: %{}
      }

      html = render(lawyer_scope(user), empty)
      assert html =~ "이 문서에는 아직 내용이 없습니다."
    end
  end

  describe "persona-perm gating" do
    setup do
      %{user: user_fixture()}
    end

    test ":write perm → editable nodes carry contenteditable=\"true\"",
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())

      # Paragraph / heading / list_item are editable for :write.
      assert html =~ ~r/<h1[^>]+contenteditable="true"/
      assert html =~ ~r/<p[^>]+contenteditable="true"/
      assert html =~ ~r/<li[^>]+contenteditable="true"/

      # Hook flagged as writable.
      assert html =~ ~s(data-can-write="true")
    end

    test ":read-only (viewer) → no contenteditable, no edit hook write flag",
         %{user: user} do
      html = render(viewer_scope(user), sample_projection())

      refute html =~ ~s(contenteditable="true")
      assert html =~ ~s(data-can-write="false")
      # Still has the marks-anchor DOM ids so MarksLayer keeps working.
      assert html =~ ~s(id="node-p1")
      assert html =~ ~s(id="node-h1")
    end

    test "paralegal (write + revoke) gets both contenteditable AND can-revoke",
         %{user: user} do
      html = render(paralegal_scope(user), sample_projection())
      assert html =~ ~s(contenteditable="true")
      assert html =~ ~s(data-can-revoke="true")
    end
  end

  describe "Editable hook wiring (debounce + Cmd shortcuts)" do
    setup do
      %{user: user_fixture()}
    end

    test "writable persona: the .Editable hook is attached and exposes the debounced commit path",
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())

      # Phoenix LV 1.1 resolves the colocated `.Editable` hook to its
      # fully-qualified name when rendering the phx-hook attribute.
      assert html =~ "phx-hook=\"ContractWeb.Live.Studio.Components.Canvas.Editor.Editable\""

      # The Editor wires the hook on the body wrapper and passes can-write
      # flag so the JS side knows whether to commit edits.
      assert html =~ ~s(data-can-write="true")
      # Source of truth for the hook source itself is asserted below via
      # `editor_hook_source/0` so we don't depend on the colocated script
      # being inlined in the rendered HTML (LV 1.1 hoists it elsewhere).
      hook_src = editor_hook_source()
      assert hook_src =~ ~s(pushEvent("edit_document")
      assert hook_src =~ "this.debounceMs = 300"
      assert hook_src =~ "node_id"
    end

    test "Cmd+Z revoke path: hook reads data-can-revoke and pushes revoke_change",
         %{user: user} do
      # :revoke + :write persona (admin) → hook ALLOWED to fire revoke_change.
      html = render(admin_scope(user), sample_projection())

      assert html =~ ~s(data-can-revoke="true")

      hook_src = editor_hook_source()
      assert hook_src =~ ~s(pushEvent("revoke_change")
      assert hook_src =~ "metaKey || e.ctrlKey"
      # Hook respects the data-can-revoke gate before pushing.
      assert hook_src =~ ~s(this.el.dataset.canRevoke !== "true")
    end

    test "viewer is gated out of Cmd+Z: data-can-revoke=\"false\"", %{user: user} do
      html = render(viewer_scope(user), sample_projection())
      assert html =~ ~s(data-can-revoke="false")
    end

    test "set_node_focus is fired via phx-click on every editable node",
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())

      # Click → set_node_focus event with the node's id.
      assert html =~ ~s(phx-click="set_node_focus")
      assert html =~ ~s(phx-value-node_id="p1")
      assert html =~ ~s(phx-value-node_id="h1")
    end
  end

  describe "revision-conflict surfacing" do
    setup do
      %{user: user_fixture()}
    end

    test "no conflict assign → no toast banner rendered", %{user: user} do
      html = render(lawyer_scope(user), sample_projection())
      refute html =~ ~s(data-role="revision-conflict-toast")
    end

    test "conflict_node_id assign → renders the revert toast for that node",
         %{user: user} do
      html =
        render(lawyer_scope(user), sample_projection(), conflict_node_id: "p1")

      assert html =~ ~s(data-role="revision-conflict-toast")
      assert html =~ ~s(data-conflict-node-id="p1")
      assert html =~ "다른 사용자의 변경이 먼저 적용되었습니다."
    end
  end

  describe "Korean text content" do
    setup do
      %{user: user_fixture()}
    end

    test "renders precomposed Hangul cleanly without jamo decomposition",
         %{user: user} do
      projection = %{
        title: nil,
        type_key: nil,
        metadata: %{},
        nodes: %{
          "p1" => %{
            id: "p1",
            kind: :paragraph,
            content: "갑은 을에게 비밀 정보를 제공한다."
          }
        },
        node_order: ["p1"],
        fields: %{},
        marks: %{},
        refs: %{}
      }

      html = render(lawyer_scope(user), projection)
      assert html =~ "갑은 을에게 비밀 정보를 제공한다."

      # No NFD-decomposed jamo: composed Hangul syllables stay in the
      # Hangul Syllables block (U+AC00–U+D7A3). Spot-check '갑' (U+AC11)
      # is present and the conjoining jamo for the same syllable is NOT.
      assert html =~ "갑"
      # Conjoining initial ㄱ (U+1100) + medial ㅏ (U+1161) + final ㅂ (U+11B8)
      # would replace '갑' if Elixir/HEEx decomposed it. Confirm they do not
      # appear as a standalone sequence.
      refute html =~ <<0x1100::utf8, 0x1161::utf8, 0x11B8::utf8>>
    end

    test "Korean content participates in the data-server-content snapshot",
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())
      assert html =~ ~s(data-server-content="본 계약은 비밀 정보 보호를 목적으로 한다.")
      assert html =~ ~s(data-server-content="보안 유지 계약서")
    end
  end

  describe "MarksLayer DOM contract" do
    setup do
      %{user: user_fixture()}
    end

    test ~s(every renderable node carries id="node-#{"<node_id>"}" so MarksLayer can target it),
         %{user: user} do
      html = render(lawyer_scope(user), sample_projection())

      for node_id <- ~w(h1 p1 p2 l1 li1 li2 t1) do
        assert html =~ ~s(id="node-#{node_id}"),
               "expected DOM id node-#{node_id} for MarksLayer anchoring"
      end
    end
  end
end
