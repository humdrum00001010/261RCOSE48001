defmodule Contract.Engine do
  @moduledoc """
  Pure mechanics. No LiveView, no OpenAI, no Slack, no MCP.

  Track A1 (feat/engine) fills these out. See SPEC.md §13.
  """

  alias Contract.Types, as: T

  # `Contract.ChangeInput` is defined by Track A1 — until then, treat the input
  # type as opaque (any term that round-trips through the Engine pipeline).
  @type change_input :: term()

  @spec compile(Contract.Action.t(), Contract.Runtime.State.t()) ::
          T.result(change_input())
  def compile(_action, _state), do: raise("Contract.Engine.compile/2 not implemented")

  @spec validate(change_input(), Contract.Runtime.State.t()) :: T.result(:ok)
  def validate(_input, _state), do: raise("Contract.Engine.validate/2 not implemented")

  @spec preimage(change_input(), Contract.Runtime.State.t()) :: T.result(map())
  def preimage(_input, _state), do: raise("Contract.Engine.preimage/2 not implemented")

  @spec inverse(change_input(), map()) :: T.result([Contract.Operation.t()])
  def inverse(_input, _preimage), do: raise("Contract.Engine.inverse/2 not implemented")

  @spec apply(change_input(), Contract.Runtime.State.t()) ::
          T.result(Contract.Runtime.State.t())
  def apply(_input, _state), do: raise("Contract.Engine.apply/2 not implemented")

  @spec affected_refs(change_input(), Contract.Runtime.State.t()) :: T.result([map()])
  def affected_refs(_input, _state),
    do: raise("Contract.Engine.affected_refs/2 not implemented")

  @spec build_change(Contract.Action.t(), change_input(), Contract.Runtime.State.t()) ::
          T.result(Contract.Change.t())
  def build_change(_action, _input, _state),
    do: raise("Contract.Engine.build_change/3 not implemented")
end
