defmodule Ecrits.Workspace.SessionAgentStateTest do
  use ExUnit.Case, async: true

  alias Ecrits.Agent.Dialog
  alias Ecrits.Workspace.Session.Agent

  test "preserves the session agent defaults as an embedded schema" do
    assert %Agent{
             role: :foreground,
             pid: nil,
             title_user_edited?: false,
             transcript: [],
             queue: [],
             current_turn: nil,
             adapter_opts: [],
             mcp_servers: []
           } = %Agent{}

    assert Agent.__schema__(:type, :id) == :string
    assert MapSet.new(Agent.__schema__(:virtual_fields)) == MapSet.new([:adapter_opts, :pid])
  end

  test "changeset casts durable fields and embedded transcript only" do
    pid = self()

    changeset =
      Agent.changeset(%Agent{pid: pid, adapter_opts: [model: "test"]}, %{
        id: "agent-1",
        role: :background,
        provider: "codex",
        provider_session_id: "provider-session-1",
        title: "Review",
        title_user_edited?: true,
        transcript: [
          %{turn_id: "turn-1", user: "Review this", agent: "Done", items: [%{"type" => "text"}]}
        ],
        queue: [%{"id" => "turn-2"}],
        current_turn: %{"id" => "turn-1", "status" => "running"},
        mcp_servers: [%{"name" => "law"}],
        pid: spawn(fn -> :ok end),
        adapter_opts: [model: "ignored"]
      })

    assert changeset.valid?

    assert %Agent{
             id: "agent-1",
             role: :background,
             pid: ^pid,
             provider: "codex",
             provider_session_id: "provider-session-1",
             title: "Review",
             title_user_edited?: true,
             transcript: [%Dialog{turn_id: "turn-1"}],
             queue: [%{"id" => "turn-2"}],
             current_turn: %{"id" => "turn-1", "status" => "running"},
             adapter_opts: [model: "test"],
             mcp_servers: [%{"name" => "law"}]
           } = Ecto.Changeset.apply_changes(changeset)
  end
end
