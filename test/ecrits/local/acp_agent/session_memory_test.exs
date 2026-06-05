defmodule Ecrits.Local.AcpAgent.SessionMemoryTest do
  @moduledoc """
  Regression test for cross-turn conversation memory.

  The bug: every turn created a brand-new provider session (`session/new` ->
  codex `thread/start` with no `threadId`), so the agent had ZERO memory of
  prior turns. The fix persists the provider session id in the long-lived
  `Session` GenServer and RESUMES it (`session/load`) on turns 2+.

  Driven through the real `ExMCP.ACP` stack via `EcritsWeb.FakeAcpAdapter`,
  which reports each `session/new` / `session/load` to `:test_pid` so we can
  assert the resume happened with the SAME provider session id rather than a
  fresh one being minted.
  """

  use ExUnit.Case, async: false

  alias Ecrits.Local.AcpAgent.Session

  setup do
    id = "mem-test-" <> Ecto.UUID.generate()

    start_supervised!(
      {Session,
       id: id,
       ctx: nil,
       provider: %{id: "codex"},
       exmcp_adapter: EcritsWeb.FakeAcpAdapter,
       adapter_opts: [
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         test_pid: self(),
         report_session_lifecycle: true,
         script: [{:text_delta, "ok"}]
       ],
       workspace_root: File.cwd!(),
       mcp_servers: []}
    )

    :ok = Ecrits.Local.AcpAgent.subscribe(id)
    {:ok, id: id}
  end

  test "turn 2 resumes the same provider session id instead of minting a new one", %{id: id} do
    pid = Session.whereis(id)
    assert is_pid(pid)

    # ── Turn 1: a brand-new provider session is created ──────────────
    {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "favorite color is teal")
    assert_receive {:fake_acp_session, :new, provider_id_1}, 2_000
    assert is_binary(provider_id_1) and provider_id_1 != ""

    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000

    # ── Turn 2: the SAME provider session must be RESUMED, not re-created ──
    {:ok, %{id: turn2}} = Session.send_turn(pid, nil, "what is my favorite color?")

    # The bug would emit another `:new` with a DIFFERENT id here. The fix emits
    # `:load` (resume) carrying the SAME provider session id from turn 1.
    assert_receive {:fake_acp_session, method, provider_id_2}, 2_000

    assert method == :load,
           "expected turn 2 to RESUME the provider session (session/load), " <>
             "got session/#{method} — conversation memory is lost"

    assert provider_id_2 == provider_id_1,
           "turn 2 resumed a DIFFERENT provider session (#{inspect(provider_id_2)}) " <>
             "than turn 1 created (#{inspect(provider_id_1)}) — memory is lost"

    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn2}}, 2_000

    # And no second `:new` session was ever minted.
    refute_received {:fake_acp_session, :new, _}
  end
end
