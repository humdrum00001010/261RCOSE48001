defmodule Contract.Agent do
  @moduledoc """
  Semantic interpreter. Agent resolves targets; backend validates returned
  IDs. Track A2 (feat/io) implements this — it ships the "grill me" skill
  (Mark{intent: :ask} first-turn behavior) and OpenAI Responses-API MCP
  wiring against `https://korean-law-mcp.fly.dev/mcp?oc=${LAW_OC}`.

  See SPEC.md §20.
  """

  alias Contract.Types, as: T

  # Track A2 will materialize `Contract.Agent.Run`. Until then, keep the type
  # opaque for `@spec` purposes.
  @type run :: term()

  @spec start(T.ctx(), Contract.Action.t()) :: T.result(run())
  def start(_ctx, _action), do: raise("Contract.Agent.start/2 not implemented")

  @spec cancel(T.ctx(), T.agent_run_id()) :: T.result(run())
  def cancel(_ctx, _run_id), do: raise("Contract.Agent.cancel/2 not implemented")

  @spec observe_change(T.agent_run_id(), Contract.Change.t()) :: T.result(:ok)
  def observe_change(_run_id, _change),
    do: raise("Contract.Agent.observe_change/2 not implemented")

  @spec observe_revoke(T.agent_run_id(), Contract.Change.t()) :: T.result(:ok)
  def observe_revoke(_run_id, _revoke_change),
    do: raise("Contract.Agent.observe_revoke/2 not implemented")

  @spec build_context(T.ctx(), Contract.Action.t()) :: T.result(map())
  def build_context(_ctx, _action),
    do: raise("Contract.Agent.build_context/2 not implemented")

  @spec decode_action(map()) :: T.result(Contract.Action.t())
  def decode_action(_provider_output),
    do: raise("Contract.Agent.decode_action/1 not implemented")
end
