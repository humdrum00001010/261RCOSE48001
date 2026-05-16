defmodule Contract.EngineTest do
  @moduledoc """
  Forwarder smoke test for `Contract.Engine`. SPEC.md v0.5 moves the
  reduction functions into `Contract.Session.Reducer`; `Contract.Engine`
  remains as a thin `defdelegate`-only module so older callers compile
  during the migration. This file verifies each delegated function still
  dispatches correctly through Engine.
  """

  use ExUnit.Case, async: true

  alias Contract.{ChangeInput, Command, Engine, Runtime}

  defp uuid(seed) do
    digits = String.pad_leading(Integer.to_string(seed), 12, "0")
    "11111111-1111-1111-1111-#{digits}"
  end

  defp new_state do
    %Runtime.State{
      document_id: uuid(0),
      revision: 0,
      projection: Runtime.State.empty_projection()
    }
  end

  defp sample_command do
    %Command{
      kind: :create_document,
      document_id: uuid(1),
      actor_type: :user,
      actor_id: uuid(2),
      base_revision: 0,
      payload: %{"title" => "Forwarder", "type_key" => "nda"}
    }
  end

  describe "forwarder dispatch" do
    test "compile/2 delegates to Session.Reducer" do
      assert {:ok, %ChangeInput{} = input} = Engine.compile(sample_command(), new_state())
      assert input.action_kind == :create_document
    end

    test "validate/2 delegates to Session.Reducer" do
      {:ok, input} = Engine.compile(sample_command(), new_state())
      assert {:ok, :ok} = Engine.validate(input, new_state())
    end

    test "preimage/2 delegates to Session.Reducer" do
      {:ok, input} = Engine.compile(sample_command(), new_state())
      assert {:ok, pre} = Engine.preimage(input, new_state())
      assert is_map(pre)
    end

    test "inverse/2 delegates to Session.Reducer" do
      {:ok, input} = Engine.compile(sample_command(), new_state())
      {:ok, pre} = Engine.preimage(input, new_state())
      assert {:ok, ops} = Engine.inverse(input, pre)
      assert is_list(ops)
    end

    test "apply/2 delegates to Session.Reducer" do
      {:ok, input} = Engine.compile(sample_command(), new_state())
      assert {:ok, %Runtime.State{revision: 1}} = Engine.apply(input, new_state())
    end

    test "affected_refs/2 delegates to Session.Reducer" do
      {:ok, input} = Engine.compile(sample_command(), new_state())
      assert {:ok, refs} = Engine.affected_refs(input, new_state())
      assert is_list(refs)
    end

    test "build_change/3 delegates to Session.Reducer" do
      command = sample_command()
      state = new_state()
      {:ok, %ChangeInput{} = input} = Engine.compile(command, state)
      {:ok, pre} = Engine.preimage(input, state)
      {:ok, inv} = Engine.inverse(input, pre)
      {:ok, refs} = Engine.affected_refs(input, state)

      enriched = %ChangeInput{
        input
        | preimage: pre,
          inverse_ops: inv,
          affected_refs: refs
      }

      assert {:ok, %Contract.Change{action_kind: "create_document"}} =
               Engine.build_change(command, enriched, state)
    end
  end
end
