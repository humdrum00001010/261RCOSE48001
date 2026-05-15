defmodule Contract.Runtime.StateTest do
  use ExUnit.Case, async: true

  alias Contract.Runtime.State

  test "default struct has empty projection with all top-level keys" do
    s = %State{}
    assert s.revision == 0
    assert s.document_id == nil

    for key <- [:title, :type_key, :metadata, :nodes, :node_order, :fields, :marks, :refs] do
      assert Map.has_key?(s.projection, key), "projection missing key #{inspect(key)}"
    end

    assert s.projection.nodes == %{}
    assert s.projection.node_order == []
    assert s.projection.refs == %{}
  end

  test "empty_projection/0 returns the same value as the default" do
    assert %State{}.projection == State.empty_projection()
  end
end
