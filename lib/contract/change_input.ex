defmodule Contract.ChangeInput do
  @moduledoc """
  Intermediate result of `Contract.Engine.compile/2`: a validated, ready-to-apply
  representation of an `Contract.Command`. Not durable — only `Contract.Change`
  is. See SPEC.md §13.

  Lifecycle:

      Engine.compile/2     → returns %ChangeInput{}            (ops, marks filled)
      Engine.validate/2    → returns :ok                       (no struct change)
      Engine.preimage/2    → returns map                       (caller stuffs into :preimage)
      Engine.inverse/2     → returns [Operation.t()]           (caller stuffs into :inverse_ops)
      Engine.apply/2       → returns new Runtime.State
      Engine.affected_refs → returns [map()]                   (caller stuffs into :affected_refs)
      Engine.build_change/3 → returns Contract.Change          (durable)
  """

  alias Contract.{MarkInput, Operation, Types}

  @type t :: %__MODULE__{
          action_kind: atom(),
          matter_id: Types.matter_id() | nil,
          document_id: Types.document_id() | nil,
          base_revision: Types.revision() | nil,
          idempotency_key: Types.idempotency_key() | nil,
          actor_type: atom(),
          actor_id: Types.user_id() | nil,
          ops: [Operation.t()],
          marks: [MarkInput.t()],
          message: String.t() | nil,
          affected_refs: [map()],
          preimage: map() | nil,
          inverse_ops: [Operation.t()],
          agent_run_id: Types.agent_run_id() | nil,
          metadata: map()
        }

  defstruct action_kind: nil,
            matter_id: nil,
            document_id: nil,
            base_revision: nil,
            idempotency_key: nil,
            actor_type: :user,
            actor_id: nil,
            ops: [],
            marks: [],
            message: nil,
            affected_refs: [],
            preimage: nil,
            inverse_ops: [],
            agent_run_id: nil,
            metadata: %{}
end
