defmodule Ecrits.ChangeInputTest do
  use ExUnit.Case, async: true

  alias Ecrits.ChangeInput

  test "struct defaults are sensible and every documented field is assignable" do
    default = %ChangeInput{}
    assert default.ops == []
    assert default.marks == []
    assert default.affected_refs == []
    assert default.inverse_ops == []
    assert default.actor_type == :user
    assert default.preimage == nil
    assert default.metadata == %{}

    populated = %ChangeInput{
      action_kind: :rename_document,
      document_id: "d",
      base_revision: 1,
      idempotency_key: "key-12345",
      actor_type: :agent,
      actor_id: "u",
      message: "hello",
      agent_run_id: "ar",
      metadata: %{foo: 1}
    }

    assert populated.action_kind == :rename_document
    assert populated.idempotency_key == "key-12345"
    assert populated.metadata == %{foo: 1}
  end
end
