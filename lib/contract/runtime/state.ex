defmodule Contract.Runtime.State do
  @moduledoc """
  The in-memory projection of a document that the Engine compiles against and
  the Session hydrates from `Contract.Store`. SPEC.md §13 references this as
  the second argument to `Engine.compile/2` and friends.

  ## Projection shape

  The `:projection` map is the pure data the Engine mutates. Its shape:

      %{
        title:      String.t() | nil,
        type_key:   Contract.Types.contract_type_key() | nil,
        metadata:   map(),
        nodes:      %{node_id => node_t()},
        node_order: [node_id],         # top-level order; tree is per-node parent_id
        fields:     %{field_id => field_t()},
        marks:      %{mark_id  => mark_t()},
        refs:       %{ref_id   => ref_target_t()}
      }

  ## Node kinds

  Per SPEC.md §15 invariant 15 ("soft meaning belongs in Marks, not in a giant
  hard legal ontology"), the Engine intentionally does **not** enumerate a
  fixed legal ontology of node kinds. The recommended baseline kinds are:

      :paragraph, :heading, :list, :list_item, :table, :cell, :section, :field_ref

  Authors and agents are free to use additional kinds as soft labels; the
  Engine treats node kinds as opaque atoms. Any "is this a clause?" semantics
  belong in marks, not in node kinds.
  """

  alias Contract.Types, as: T

  @type node_id :: T.id()
  @type field_id :: T.field_id()
  @type mark_id :: T.mark_id()
  @type ref_id :: T.id()

  @type node_t :: %{
          required(:id) => node_id(),
          required(:kind) => atom(),
          optional(:parent_id) => node_id() | nil,
          optional(:content) => String.t(),
          optional(:children) => [node_id()],
          optional(:attrs) => map()
        }

  @type field_t :: %{
          required(:id) => field_id(),
          optional(:key) => atom() | String.t(),
          optional(:value) => term(),
          optional(:attrs) => map()
        }

  @type mark_t :: %{
          required(:id) => mark_id(),
          required(:intent) => atom(),
          required(:source) => atom(),
          optional(:text) => String.t(),
          optional(:target_type) => atom(),
          optional(:target_id) => T.id() | nil,
          optional(:confidence) => atom(),
          optional(:data) => map()
        }

  @type ref_target_t :: %{
          required(:id) => ref_id(),
          required(:source_node_id) => node_id(),
          required(:target_id) => T.id(),
          optional(:type) => atom()
        }

  @type projection_t :: %{
          title: String.t() | nil,
          type_key: T.contract_type_key() | nil,
          metadata: map(),
          nodes: %{optional(node_id()) => node_t()},
          node_order: [node_id()],
          fields: %{optional(field_id()) => field_t()},
          marks: %{optional(mark_id()) => mark_t()},
          refs: %{optional(ref_id()) => ref_target_t()}
        }

  @type t :: %__MODULE__{
          document_id: T.document_id() | nil,
          revision: T.revision(),
          projection: projection_t()
        }

  @empty_projection %{
    title: nil,
    type_key: nil,
    metadata: %{},
    nodes: %{},
    node_order: [],
    fields: %{},
    marks: %{},
    refs: %{}
  }

  defstruct document_id: nil,
            revision: 0,
            projection: @empty_projection

  @doc """
  Returns an empty projection map. Useful for tests and Store hydration.
  """
  @spec empty_projection() :: projection_t()
  def empty_projection, do: @empty_projection
end
