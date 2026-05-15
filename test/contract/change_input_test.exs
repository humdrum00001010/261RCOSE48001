defmodule Contract.ChangeInputTest do
  use ExUnit.Case, async: true

  alias Contract.ChangeInput

  test "default struct has the documented shape" do
    ci = %ChangeInput{}
    assert ci.ops == []
    assert ci.marks == []
    assert ci.affected_refs == []
    assert ci.inverse_ops == []
    assert ci.actor_type == :user
    assert ci.preimage == nil
    assert ci.metadata == %{}
  end

  test "all expected fields can be assigned" do
    ci = %ChangeInput{
      action_kind: :rename_document,
      matter_id: "m",
      document_id: "d",
      base_revision: 1,
      idempotency_key: "key-12345",
      actor_type: :agent,
      actor_id: "u",
      message: "hello",
      agent_run_id: "ar",
      metadata: %{foo: 1}
    }

    assert ci.action_kind == :rename_document
    assert ci.idempotency_key == "key-12345"
    assert ci.metadata == %{foo: 1}
  end
end
