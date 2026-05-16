defmodule Contract.Engine do
  @moduledoc deprecated:
               "Use Contract.Session.Reducer. Engine remains as a forwarder for migration."

  @moduledoc """
  Deprecated thin forwarder to `Contract.Session.Reducer`. See SPEC.md v0.5
  §8 — `Contract.Session.Reducer` is the canonical internal helper; the
  Engine module is preserved so older callers keep compiling during the
  v0.5 migration.
  """

  alias Contract.Session.Reducer

  defdelegate compile(command, state), to: Reducer
  defdelegate validate(input, state), to: Reducer
  defdelegate preimage(input, state), to: Reducer
  defdelegate inverse(input, preimage), to: Reducer
  defdelegate apply(input, state), to: Reducer
  defdelegate affected_refs(input, state), to: Reducer
  defdelegate build_change(command, input, state), to: Reducer
end
