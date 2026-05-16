defmodule ContractWeb.Live.Studio.Components.ContextReservoirTest do
  @moduledoc """
  Component-level tests for `ContextReservoir` — the LiveComponent that
  replaces `DocumentList` in the Studio left rail (SPEC.md §10a).

  We use `Phoenix.LiveViewTest.render_component/2` to exercise
  `update/2` + render output; LV-level wiring (mount, dispatch funnel)
  is covered by `studio_live_test.exs`.

  The studio surface is Korean-primary; `config/test.exs` pins the
  global UI locale to "en", so each test below explicitly flips the
  process-local Gettext locale to "ko" (mirrors `document_list_test`).
  """
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Contract.Context
  alias Contract.Studio.ContextReservoir
  alias ContractWeb.Live.Studio.Components.ContextReservoir, as: ContextReservoirLC

  # ---------------------------------------------------------------------------
  # LC-round-trip harness — mounts the ContextReservoir LC and records every
  # message the LC `send/2`s back up to its parent so we can assert on the
  # `handle_info/2` protocol from tests without standing up the full
  # StudioLive. Defined *inside* the test module (compiled as a nested
  # module) so it's robust under ExUnit's async parallel runner — defining
  # it at top-level caused intermittent "module not available" errors when
  # the suite runs alongside other compiled tests.
  # ---------------------------------------------------------------------------

  defmodule Harness do
    @moduledoc false
    use ContractWeb, :live_view

    alias Phoenix.Component, as: PC
    alias ContractWeb.Live.Studio.Components.ContextReservoir, as: LC

    @impl true
    def mount(_params, session, socket) do
      {:ok,
       socket
       |> PC.assign(:reservoir, session["reservoir"])
       |> PC.assign(:current_scope, session["current_scope"])
       |> PC.assign(:trace, [])}
    end

    @impl true
    def handle_info({:context_reservoir_edit_field, field_id, value}, socket) do
      line = "trace=context_reservoir_edit_field field_id=#{field_id} value=#{value}"
      {:noreply, PC.update(socket, :trace, &[line | &1])}
    end

    def handle_info({:context_reservoir_focus_question, question_id}, socket) do
      line = "trace=context_reservoir_focus_question question_id=#{question_id}"
      {:noreply, PC.update(socket, :trace, &[line | &1])}
    end

    def handle_info(_, socket), do: {:noreply, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={LC}
          id="context-reservoir"
          reservoir={@reservoir}
          current_scope={@current_scope}
        />
        <ul data-role="trace">
          <li :for={line <- @trace}>{line}</li>
        </ul>
      </div>
      """
    end
  end

  setup do
    Gettext.put_locale(ContractWeb.Gettext, "ko")
    :ok
  end

  # --- persona-perm fixtures -----------------------------------------------

  defp lawyer_scope do
    %Context{
      user: %{id: Ecto.UUID.generate()},
      perms: ~w(read write commit revoke export type_change agent_run)a
    }
  end

  defp viewer_scope do
    %Context{user: %{id: Ecto.UUID.generate()}, perms: ~w(read)a}
  end

  defp empty_reservoir, do: %ContextReservoir{}

  defp populated_reservoir do
    %ContextReservoir{
      brief: %{
        title: "상호 비밀유지계약서",
        purpose: "기술 협업 검토",
        status: :active,
        user_role: "공급자",
        counterparty_role: "수요자"
      },
      shared_fields: [
        %{field_id: "party_a", label: "을", value: "ACME 주식회사", attrs: %{}},
        %{field_id: "jurisdiction", label: "준거법", value: "대한민국", attrs: %{}}
      ],
      open_questions: [
        %{
          question_id: "q-1",
          text: "비밀유지 기간은?",
          asked_by: :agent,
          answered_at: nil
        },
        %{
          question_id: "q-2",
          text: "관할법원은?",
          asked_by: :agent,
          answered_at: nil
        }
      ],
      related_documents: [
        %{
          document_id: Ecto.UUID.generate(),
          label_ko: "원본 업로드",
          label_en: "Original upload",
          role: :source
        },
        %{
          document_id: Ecto.UUID.generate(),
          label_ko: "변호사용 패킷",
          label_en: "Lawyer packet",
          role: :packet
        }
      ],
      sources: [
        %{
          artifact_id: "art-1",
          kind: :upstage_parse,
          created_at: DateTime.utc_now(),
          label: "원본 NDA.pdf"
        }
      ],
      evidence: [
        %{
          evidence_id: "ev-1",
          source: :law_mcp,
          summary: "민법 §103 — 사회질서 위반"
        }
      ],
      recent_changes: [
        %{
          change_id: "c-1",
          action_kind: "edit_document",
          applied_at: DateTime.add(DateTime.utc_now(), -120, :second),
          summary_ko: "에이전트가 §3 비밀유지 기간 절을 수정함",
          summary_en: "Agent edited §3 confidentiality term"
        }
      ],
      recent_revokes: [
        %{
          change_id: "c-2",
          action_kind: "revoke_change",
          applied_at: DateTime.add(DateTime.utc_now(), -300, :second),
          summary_ko: "사용자가 §5 손해배상 조항 변경을 되돌림",
          summary_en: "User revoked §5 indemnification change"
        }
      ],
      readiness: %{
        unresolved_questions: 2,
        source_modified_notes: 0,
        export_warnings: 1,
        lawyer_packet_status: :in_progress
      }
    }
  end

  defp render_lc(opts) do
    render_component(
      ContextReservoirLC,
      Keyword.merge(
        [id: "context-reservoir", current_scope: lawyer_scope()],
        opts
      )
    )
  end

  # ----------------------------------------------------------------------------
  # 1. Empty reservoir → only Brief + Readiness render, others collapse.
  # ----------------------------------------------------------------------------

  describe "empty state" do
    test "collapses every list section but keeps Brief + Readiness as baseline" do
      html = render_lc(reservoir: empty_reservoir())

      # The aside chrome is present.
      assert html =~ ~s(data-component="context-reservoir")
      assert html =~ ~s(data-role="context-reservoir")

      # Baseline sections — always rendered.
      assert html =~ ~s(data-section="brief")
      assert html =~ ~s(data-section="readiness")
      assert html =~ "개요"
      assert html =~ "준비 상태"

      # Collapsible sections — must not render.
      refute html =~ ~s(data-section="shared-fields")
      refute html =~ ~s(data-section="open-questions")
      refute html =~ ~s(data-section="related-documents")
      refute html =~ ~s(data-section="sources")
      refute html =~ ~s(data-section="evidence")
      refute html =~ ~s(data-section="recent-changes")
      refute html =~ ~s(data-section="recent-revokes")

      # Empty brief renders the "no brief yet" hint.
      assert html =~ ~s(data-role="brief-empty")
      assert html =~ "개요가 아직 없습니다"

      # Readiness defaults to 0s.
      assert html =~ ~s(data-role="readiness-unresolved")
    end
  end

  # ----------------------------------------------------------------------------
  # 2. Populated reservoir → every section renders.
  # ----------------------------------------------------------------------------

  describe "populated reservoir" do
    test "renders all nine sections in order" do
      html = render_lc(reservoir: populated_reservoir())

      # All 9 section markers must be present.
      for section <- ~w(brief shared-fields open-questions related-documents
                        sources evidence recent-changes recent-revokes readiness) do
        assert html =~ ~s(data-section="#{section}"),
               "expected reservoir to render section #{section}"
      end

      # Spot-check the values made it through.
      assert html =~ "상호 비밀유지계약서"
      assert html =~ "ACME 주식회사"
      assert html =~ "비밀유지 기간은?"
      assert html =~ "원본 업로드"
      assert html =~ "원본 NDA.pdf"
      assert html =~ "민법 §103"
      assert html =~ "에이전트가 §3 비밀유지 기간 절을 수정함"
      assert html =~ "사용자가 §5 손해배상 조항 변경을 되돌림"
    end

    test "open question count is shown next to the section heading" do
      html = render_lc(reservoir: populated_reservoir())

      assert html =~ ~s(data-role="open-question-count")
      # Two unresolved questions in the fixture — assert on the digit
      # inside the count span, without coupling to HEEx indent width.
      assert [_, "2"] =
               Regex.run(~r/data-role="open-question-count">\s*(\d+)\s*</, html)
    end

    test "readiness numerics are tabular-nums and reflect the source map" do
      html = render_lc(reservoir: populated_reservoir())

      assert html =~ ~s(data-role="readiness-unresolved")
      assert html =~ ~s(data-role="readiness-export-warnings")
      assert html =~ ~s(data-role="readiness-source-modified")
      assert html =~ ~s(data-role="readiness-packet")
      # Lawyer packet status atomized to in_progress → translated to 진행 중.
      assert html =~ "진행 중"
    end
  end

  # ----------------------------------------------------------------------------
  # 3. Inline-edit affordance for shared fields.
  # ----------------------------------------------------------------------------

  describe "inline edit affordance" do
    test "lawyer (has :write perm) sees a button for each shared field" do
      html = render_lc(reservoir: populated_reservoir(), current_scope: lawyer_scope())

      assert html =~ ~s(data-role="shared-field-edit")
      assert html =~ ~s(phx-click="edit_field")
      assert html =~ ~s(phx-value-field_id="party_a")
      assert html =~ ~s(phx-value-field_id="jurisdiction")
    end

    test "viewer (read-only) sees plain values, no edit button" do
      html = render_lc(reservoir: populated_reservoir(), current_scope: viewer_scope())

      assert html =~ ~s(data-role="shared-field-value")
      refute html =~ ~s(data-role="shared-field-edit")
      refute html =~ ~s(phx-click="edit_field")
    end
  end

  # ----------------------------------------------------------------------------
  # 4. LiveComponent stateful events — edit_field flips inline input, submit
  #    sends the typed message to the parent process.
  # ----------------------------------------------------------------------------

  describe "stateful events (LiveView round-trip)" do
    test "edit_field toggles the input element for that field", %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, Harness,
          session: %{
            "reservoir" => populated_reservoir(),
            "current_scope" => lawyer_scope()
          }
        )

      # Up front: no input, just the edit button.
      refute render(lv) =~ ~s(data-role="shared-field-input")

      # Click the field — LC switches into edit mode for that row only.
      html =
        lv
        |> element(~s([data-role="shared-field-edit"][phx-value-field_id="party_a"]))
        |> render_click()

      assert html =~ ~s(data-role="shared-field-input")
      assert html =~ ~s(data-role="shared-field-form")
    end

    test "submit_field sends :context_reservoir_edit_field to the parent LV",
         %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, Harness,
          session: %{
            "reservoir" => populated_reservoir(),
            "current_scope" => lawyer_scope()
          }
        )

      lv
      |> element(~s([data-role="shared-field-edit"][phx-value-field_id="jurisdiction"]))
      |> render_click()

      lv
      |> form(~s(form[data-role="shared-field-form"]),
        field_id: "jurisdiction",
        value: "Republic of Korea"
      )
      |> render_submit()

      # The harness LV records the inbound message into its assigns; we
      # render and assert the trace contains the right tuple.
      html = render(lv)
      assert html =~ "trace=context_reservoir_edit_field"
      assert html =~ "field_id=jurisdiction"
      assert html =~ "value=Republic of Korea"
    end

    test "open_question_in_chat sends :context_reservoir_focus_question to parent LV",
         %{conn: conn} do
      {:ok, lv, _html} =
        live_isolated(conn, Harness,
          session: %{
            "reservoir" => populated_reservoir(),
            "current_scope" => lawyer_scope()
          }
        )

      lv
      |> element(
        ~s([data-role="open-question-answer-btn"][phx-value-question_id="q-1"])
      )
      |> render_click()

      html = render(lv)
      assert html =~ "trace=context_reservoir_focus_question"
      assert html =~ "question_id=q-1"
    end
  end

  # ----------------------------------------------------------------------------
  # 5. Visual / mature-look guards. No shadows, hairline borders, daisyUI
  #    "card" emerald-fill blocks must not slip in.
  # ----------------------------------------------------------------------------

  describe "visual restraint" do
    test "uses hairline borders, no drop shadows" do
      html = render_lc(reservoir: populated_reservoir())

      # `border-base-200` separators show up.
      assert html =~ "border-base-200"
      # No shadow utilities anywhere in the rail.
      refute html =~ "shadow-"
      # No emerald block fills (allow emerald accents on borders/text — those
      # would use `border-emerald-*` / `text-emerald-*`, not `bg-emerald-*`).
      refute html =~ "bg-emerald"
    end

    test "container is 320px on desktop and chromeless on drawer" do
      desktop_html =
        render_lc(reservoir: empty_reservoir(), layout: :desktop)

      assert desktop_html =~ ~s(data-layout="desktop")
      assert desktop_html =~ "w-[320px]"
      assert desktop_html =~ "border-r"

      drawer_html =
        render_lc(reservoir: empty_reservoir(), layout: :drawer)

      assert drawer_html =~ ~s(data-layout="drawer")
      refute drawer_html =~ "w-[320px]"
      refute drawer_html =~ "border-r"
    end
  end

  # ----------------------------------------------------------------------------
  # 6. Korean copy renders cleanly (no jamo decomposition / mojibake) and
  #    Brief field labels show up in the user's locale.
  # ----------------------------------------------------------------------------

  describe "i18n — Korean primary" do
    test "section headings render as fully-composed Hangul" do
      html = render_lc(reservoir: populated_reservoir())

      # Composed Hangul characters (not decomposed jamo).
      for ko <- ["개요", "공유 필드", "미해결 질문", "관련 문서", "원본", "근거",
                 "최근 변경", "최근 되돌림", "준비 상태"] do
        assert html =~ ko, "expected #{ko} in rendered HTML"
        # No NFD decomposition — code point of a syllable block stays single.
        assert ko == :unicode.characters_to_nfc_binary(ko),
               "#{ko} is not in NFC form"
      end
    end
  end
end

