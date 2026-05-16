defmodule Contract.Schemas.ToolCallTest do
  use ExUnit.Case, async: true
  alias Contract.ToolCall

  test "struct + valid changeset + required validation" do
    assert %ToolCall{} = struct(ToolCall, [])

    attrs = %{agent_run_id: Ecto.UUID.generate(), name: "law.lookup"}
    assert ToolCall.changeset(%ToolCall{}, attrs).valid?
    refute ToolCall.changeset(%ToolCall{}, %{}).valid?
  end
end
