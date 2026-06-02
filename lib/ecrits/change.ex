defmodule Ecrits.Change do
  @moduledoc """
  Durable, reversible result of a Command. See SPEC.md §6.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ecrits.Types, as: T

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "changes" do
    field :document_id, :binary_id
    field :chat_thread_id, :binary_id
    field :agent_run_id, :binary_id

    field :command_kind, :string
    field :field_path, {:array, :string}, default: []
    field :op, :string

    field :actor_type, Ecto.Enum, values: [:user, :agent, :lawyer, :slack, :system]
    field :actor_id, :binary_id

    field :base_revision, :integer
    field :result_revision, :integer
    field :idempotency_key, :string

    field :payload, {:array, :map}, default: []
    field :marks, {:array, :map}, default: []
    field :message, :string

    field :affected_refs, {:array, :map}, default: []
    field :preimage, :map
    field :inverse, {:array, :map}, default: []

    field :status, Ecto.Enum,
      values: [:active, :revoked, :partially_revoked, :superseded],
      default: :active

    timestamps()
  end

  @spec changeset(t(), T.attrs()) :: Ecto.Changeset.t()
  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :document_id,
      :chat_thread_id,
      :agent_run_id,
      :command_kind,
      :field_path,
      :op,
      :actor_type,
      :actor_id,
      :base_revision,
      :result_revision,
      :idempotency_key,
      :payload,
      :marks,
      :message,
      :affected_refs,
      :preimage,
      :inverse,
      :status
    ])
    |> validate_required([
      :document_id,
      :command_kind,
      :actor_type,
      :result_revision
    ])
  end

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: :active}), do: true
  def active?(%__MODULE__{}), do: false

  @spec revoked?(t()) :: boolean()
  def revoked?(%__MODULE__{status: status}), do: status in [:revoked, :partially_revoked]

  @spec touches?(t(), map() | binary()) :: boolean()
  def touches?(%__MODULE__{affected_refs: refs}, probe) when is_list(refs) do
    Enum.any?(refs, &ref_matches?(&1, probe))
  end

  def touches?(%__MODULE__{}, _probe), do: false

  defp ref_matches?(ref, id) when is_binary(id) do
    ref_value(ref, :ref_id) == id or ref_value(ref, :target_id) == id or
      ref_value(ref, :source_node_id) == id
  end

  defp ref_matches?(ref, probe) when is_map(probe) do
    [:ref_id, :target_id, :source_node_id]
    |> Enum.any?(fn key ->
      value = ref_value(probe, key)
      not is_nil(value) and ref_value(ref, key) == value
    end)
  end

  defp ref_matches?(_ref, _probe), do: false

  defp ref_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
