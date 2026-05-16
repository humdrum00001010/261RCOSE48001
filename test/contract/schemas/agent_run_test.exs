defmodule Contract.Schemas.AgentRunTest do
  use ExUnit.Case, async: true
  alias Contract.Agent.Run

  test "v0.5 extended fields cast through changeset" do
    assert %Run{} = struct(Run, [])

    attrs = %{
      status: :pending,
      owner_id: Ecto.UUID.generate(),
      chat_thread_id: Ecto.UUID.generate(),
      model: "gpt-5-codex",
      tools_enabled: ["law.lookup", "draft.edit"]
    }

    cs = Run.changeset(%Run{}, attrs)
    assert cs.valid?
    assert Ecto.Changeset.get_change(cs, :tools_enabled) == ["law.lookup", "draft.edit"]
  end
end
