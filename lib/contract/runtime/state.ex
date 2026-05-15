defmodule Contract.Runtime.State do
  @moduledoc """
  The in-memory projection of a document that the Engine compiles against and
  the Session hydrates from `Contract.Store`. SPEC.md §13 references this as
  the second argument to `Engine.compile/2` and friends.

  Minimal shape — Track A1 will expand `:projection` as Engine logic lands.
  """

  alias Contract.Types, as: T

  @type t :: %__MODULE__{
          document_id: T.document_id() | nil,
          revision: T.revision(),
          projection: map()
        }

  defstruct document_id: nil,
            revision: 0,
            projection: %{}
end
