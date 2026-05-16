defmodule Contract.Studio.ContextReservoir do
  @moduledoc """
  Live projection of contract context — the Studio's left rail.

  NOT the source of truth (Store + ChangeLog are). NOT a raw document navigator.

  Edits become Actions and flow through Runtime → Session → Engine → Store.
  Per SPEC.md §10a.

  ## Field shapes (data-only, validated at the changeset boundary)

    * `:brief` — `%{purpose: String.t() | nil, status: atom() | String.t() | nil,
       user_role: String.t() | nil, counterparty_role: String.t() | nil,
       title: String.t() | nil, type_key: String.t() | nil}`
    * `:shared_fields` — `[%{field_id: String.t(), label: String.t(),
       value: String.t() | nil, attrs: map()}]`
    * `:open_questions` — `[%{question_id: String.t(), text: String.t(),
       asked_by: atom(), answered_at: nil | DateTime.t() | NaiveDateTime.t()}]`
    * `:related_documents` — `[%{document_id: String.t(), label_ko: String.t(),
       label_en: String.t(), role: :current_draft | :source | :variant | :packet}]`
    * `:sources` — `[%{artifact_id: String.t() | nil,
       kind: :upload | :upstage_parse | :imported,
       created_at: DateTime.t() | NaiveDateTime.t() | nil, label: String.t()}]`
    * `:evidence` — `[%{evidence_id: String.t(),
       source: :law_mcp | :citation_verify | :government_comment,
       summary: String.t()}]`
    * `:recent_changes` — `[%{change_id: String.t(), action_kind: String.t(),
       applied_at: DateTime.t() | NaiveDateTime.t() | nil,
       summary_ko: String.t(), summary_en: String.t()}]`
    * `:recent_revokes` — same shape as `:recent_changes`
    * `:readiness` — `%{unresolved_questions: non_neg_integer(),
       source_modified_notes: non_neg_integer(), export_warnings: non_neg_integer(),
       lawyer_packet_status: atom()}`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false

  embedded_schema do
    field :brief, :map, default: %{}
    field :shared_fields, {:array, :map}, default: []
    field :open_questions, {:array, :map}, default: []
    field :related_documents, {:array, :map}, default: []
    field :sources, {:array, :map}, default: []
    field :evidence, {:array, :map}, default: []
    field :recent_changes, {:array, :map}, default: []
    field :recent_revokes, {:array, :map}, default: []
    field :readiness, :map, default: %{}
  end

  @fields ~w(brief shared_fields open_questions related_documents sources
             evidence recent_changes recent_revokes readiness)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(reservoir, attrs) do
    reservoir
    |> cast(attrs, @fields)
  end
end
