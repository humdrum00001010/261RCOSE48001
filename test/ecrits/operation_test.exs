defmodule Ecrits.OperationTest do
  use ExUnit.Case, async: true

  alias Ecrits.Operation

  test "changeset requires :op and :target_type" do
    cs = Operation.changeset(%Operation{}, %{})
    refute cs.valid?
    assert List.keyfind(cs.errors, :op, 0)
    assert List.keyfind(cs.errors, :target_type, 0)
  end

  test "all SPEC.md §7 op kinds are accepted" do
    for kind <- [
          :create_node,
          :delete_node,
          :move_node,
          :replace_content,
          :set_field,
          :set_attr,
          :bind_ref,
          :unbind_ref,
          :create_projection,
          :add_mark,
          :update_mark
        ] do
      cs = Operation.changeset(%Operation{}, %{op: kind, target_type: :node})
      assert cs.valid?, "#{kind} not accepted: #{inspect(cs.errors)}"
    end
  end

  test "rejects unknown op kind / unknown target_type" do
    refute Operation.changeset(%Operation{}, %{op: :rewrite_everything, target_type: :node}).valid?

    refute Operation.changeset(%Operation{}, %{op: :create_node, target_type: :clause}).valid?
  end
end
