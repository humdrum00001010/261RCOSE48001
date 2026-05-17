defmodule ContractWeb.Live.Studio.Components.Canvas.ReviewTest do
  @moduledoc """
  Component-level tests for Canvas.Review (Wave 3C1).

  Drives the LiveComponent through `Phoenix.LiveViewTest.render_component/2`
  with a synthetic `:changes_stream` (list of `{dom_id, change}` tuples)
  to exercise the changes-feed rendering without spinning up the full
  StudioLive. LV-level interaction tests for `change.revoke` /
  `set_node_focus` belong in `studio_live_test.exs`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.Canvas.Review

  @endpoint ContractWeb.Endpoint

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp base_studio_state(overrides \\ %{}) do
    Map.merge(
      %State{
        selected_document_id: "doc-1",
        selected_node_id: nil,
        last_seen_revision: 5,
        mode: :reviewing
      },
      Map.new(overrides)
    )
  end

  defp scope(perms) do
    %Context{
      user: %{id: Ecto.UUID.generate(), email: "u@example.com"},
      perms: perms
    }
  end

  defp projection(opts \\ []) do
    title = Keyword.get(opts, :title, "검토용 계약서 / Review Contract")

    nodes =
      Keyword.get(opts, :nodes, %{
        "n1" => %{id: "n1", kind: :paragraph, content: "First clause body."},
        "n2" => %{id: "n2", kind: :paragraph, content: "Second clause body."},
        "n3" => %{id: "n3", kind: :paragraph, content: "Third clause body."}
      })

    order = Keyword.get(opts, :node_order, Map.keys(nodes))

    marks =
      Keyword.get(opts, :marks, %{
        "m1" => %{
          id: "m1",
          intent: :concern,
          source: :agent,
          confidence: :high,
          target_type: :node,
          target_id: "n1",
          text: "Liability cap may be too low."
        },
        "m2" => %{
          id: "m2",
          intent: :assertion,
          source: :user,
          confidence: :medium,
          target_type: :node,
          target_id: "n1",
          text: "Counsel reviewed."
        }
      })

    %{
      title: title,
      type_key: :nda,
      metadata: %{},
      nodes: nodes,
      node_order: order,
      fields: %{},
      marks: marks,
      refs: %{}
    }
  end

  defp change(attrs \\ %{}) do
    defaults = %Contract.Change{
      id: Ecto.UUID.generate(),
      document_id: "doc-1",
      command_kind: "edit_document",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: 1,
      result_revision: 2,
      payload: [],
      marks: [],
      message: "Tightened indemnity wording.",
      affected_refs: [%{node_id: "n1"}],
      status: :active,
      inserted_at: ~U[2026-05-15 12:00:00Z]
    }

    Map.merge(defaults, attrs)
  end

  defp stream_list(changes) do
    changes
    |> Enum.with_index()
    |> Enum.map(fn {c, i} -> {"change-#{i}-#{c.id}", c} end)
  end

  defp render_review(opts) do
    render_component(
      Review,
      Keyword.merge(
        [
          id: "canvas",
          studio_state: base_studio_state(),
          projection: projection(),
          current_scope: scope([:read, :write, :commit, :revoke]),
          changes_stream: []
        ],
        opts
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "render" do
    test "renders the document body + changes feed (1)" do
      changes = [
        change(%{command_kind: "edit_document"}),
        change(%{command_kind: "set_contract_type"})
      ]

      html =
        render_review(
          changes_stream: stream_list(changes),
          current_scope: scope([:read, :revoke])
        )

      # Two-column layout
      assert html =~ ~s(data-component="canvas-review")
      assert html =~ "grid-cols-[1fr_320px]"

      # Document title + node ids exposed as anchors for MarksLayer
      assert html =~ "검토용 계약서"
      assert html =~ ~s(id="node-n1")
      assert html =~ ~s(id="node-n2")
      assert html =~ "First clause body."

      # Changes feed renders both entries with action_kind badges
      assert html =~ ~s(data-feed="changes")
      assert html =~ "edit_document"
      assert html =~ "set_contract_type"
      assert html =~ "Tightened indemnity wording."

      # No edit affordances — no textareas / contenteditable
      refute html =~ "contenteditable"
      refute html =~ "<textarea"
    end

    test "marks panel expands on click (sets aria-expanded=true and lists marks) (2b)" do
      # Drive the LiveComponent in a live LV process so handle_event fires.
      {:ok, view, _html} = live_isolated_review([])

      # Click toggle for node n1
      view
      |> Phoenix.LiveViewTest.element(
        ~s|button[phx-click="toggle_marks"][phx-value-node_id="n1"]|
      )
      |> Phoenix.LiveViewTest.render_click()

      html = Phoenix.LiveViewTest.render(view)

      assert html =~ ~s(id="node-marks-n1")
      assert html =~ "Liability cap may be too low."
      assert html =~ "Counsel reviewed."
      assert html =~ ~s(aria-expanded="true")
    end

    test "click on a feed entry pushes set_node_focus with node_id (3)" do
      changes = [change(%{command_kind: "edit_document", affected_refs: [%{node_id: "n2"}]})]

      html =
        render_review(
          changes_stream: stream_list(changes),
          current_scope: scope([:read, :revoke])
        )

      # The feed entry's click target carries the node_id and a JS push for
      # set_node_focus. JS commands render as escaped JSON in phx-click.
      assert html =~ ~s(phx-value-node_id="n2")
      assert html =~ "set_node_focus"
      # And the affected node has the id MarksLayer hooks onto.
      assert html =~ ~s(id="node-n2")
    end

    test ":revoke perm shows the revoke button (4a)" do
      changes = [change()]

      html =
        render_review(
          changes_stream: stream_list(changes),
          current_scope: scope([:read, :write, :revoke])
        )

      assert html =~ ~s(phx-click="change.revoke")
      assert html =~ ~s(phx-value-change_id=")
      assert html =~ "되돌리기"
    end

    test ":viewer (perms = [:read]) hides the revoke button (4b)" do
      changes = [change()]

      html =
        render_review(
          changes_stream: stream_list(changes),
          current_scope: scope([:read])
        )

      # Same document + feed still renders.
      assert html =~ "edit_document"
      assert html =~ "Tightened indemnity wording."

      # But no revoke affordance.
      refute html =~ ~s(phx-click="change.revoke")
      refute html =~ "되돌리기"
    end

    test "revoked changes never show the revoke button, even with perm (4c)" do
      changes = [change(%{status: :revoked})]

      html =
        render_review(
          changes_stream: stream_list(changes),
          current_scope: scope([:read, :revoke])
        )

      refute html =~ ~s(phx-click="change.revoke")
    end

    test "empty changes feed renders the Korean empty state msgid (5)" do
      html = render_review(changes_stream: [])

      # Inside the stream container, an :only-child placeholder is rendered.
      assert html =~ "변경 기록이 없습니다"
      assert html =~ ~s(data-empty-state="changes")
    end

    test "selected_node_id highlights the matching node (bonus)" do
      html =
        render_review(
          studio_state: base_studio_state(%{selected_node_id: "n2"}),
          changes_stream: []
        )

      # The highlighted node gets the warning/ring class.
      assert html =~ ~r/id="node-n2"[^>]*class="[^"]*ring-warning/
    end
  end

  # ---------------------------------------------------------------------------
  # Live isolation harness for handle_event coverage.
  #
  # `render_component/2` does not exercise `handle_event/3` on LiveComponents.
  # We embed Review in a tiny throwaway LiveView and drive it via the
  # LiveViewTest client.
  # ---------------------------------------------------------------------------

  defmodule Harness do
    use Phoenix.LiveView

    alias ContractWeb.Live.Studio.Components.Canvas.Review

    def mount(_params, _session, socket) do
      {:ok,
       socket
       |> assign(:studio_state, %State{mode: :reviewing, last_seen_revision: 0})
       |> assign(:projection, %{
         title: "Harness",
         type_key: nil,
         metadata: %{},
         nodes: %{
           "n1" => %{id: "n1", kind: :paragraph, content: "Body of n1."}
         },
         node_order: ["n1"],
         fields: %{},
         marks: %{
           "m1" => %{
             id: "m1",
             intent: :concern,
             source: :agent,
             confidence: :high,
             target_type: :node,
             target_id: "n1",
             text: "Liability cap may be too low."
           },
           "m2" => %{
             id: "m2",
             intent: :assertion,
             source: :user,
             confidence: :medium,
             target_type: :node,
             target_id: "n1",
             text: "Counsel reviewed."
           }
         },
         refs: %{}
       })
       |> assign(:current_scope, %Context{
         user: %{id: Ecto.UUID.generate(), email: "h@example.com"},
         perms: [:read, :revoke]
       })
       |> Phoenix.LiveView.stream(:changes, [])}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={Review}
          id="canvas"
          studio_state={@studio_state}
          projection={@projection}
          current_scope={@current_scope}
          changes_stream={@streams.changes}
        />
      </div>
      """
    end

    # Swallow shell-level events so the harness doesn't crash when the
    # component bubbles up `set_node_focus` or `change.revoke`.
    def handle_event(_event, _params, socket), do: {:noreply, socket}
  end

  defp live_isolated_review(_opts) do
    conn = Phoenix.ConnTest.build_conn()
    Phoenix.LiveViewTest.live_isolated(conn, Harness)
  end
end
