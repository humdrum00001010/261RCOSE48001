defmodule Contract.ContractTypes do
  @moduledoc """
  Catalog of contract types known to the Studio. Each type has a stable
  `type_key` (the snake_case slug persisted on every Document/projection)
  plus presentational metadata.

  TODO(Wave 3C2): this is a stub. The real type registry will live in a
  separate module that compiles `priv/contract_types/*.toml` definitions
  (field maps, default templates, conversion routes) at app start. The
  web shell only needs `list/2` for the "New Document" modal — kept here
  so the dashboard can render even before the registry exists.
  """

  @type type_entry :: %{
          type_key: String.t(),
          name: String.t(),
          name_ko: String.t(),
          description: String.t()
        }

  @stub_types [
    %{
      type_key: "nda_v1",
      name: "Non-Disclosure Agreement",
      name_ko: "비밀유지계약서",
      description: "Bilateral or unilateral NDA. Term, scope, carve-outs, exit obligations."
    },
    %{
      type_key: "franchise_v1",
      name: "Franchise Agreement",
      name_ko: "가맹계약서",
      description: "공정거래위원회-aligned franchise template. Territory, fees, IP licence, renewal."
    },
    %{
      type_key: "service_agreement_v1",
      name: "Service Agreement",
      name_ko: "용역계약서",
      description: "General professional services. Scope, deliverables, payment, liability."
    },
    %{
      type_key: "employment_v1",
      name: "Employment Contract",
      name_ko: "근로계약서",
      description: "Standard form aligned with 근로기준법. Wage, hours, termination."
    },
    %{
      type_key: "supply_v1",
      name: "Supply Agreement",
      name_ko: "물품공급계약서",
      description: "Goods supply, delivery terms, warranties, force majeure."
    }
  ]

  @doc """
  Returns the list of contract type entries available for new-document
  creation. The `_ctx` and `_opts` arguments mirror the eventual
  context-scoped signature so callers don't need to change when the
  real registry lands.
  """
  @spec list(term(), keyword()) :: [type_entry()]
  def list(_ctx \\ nil, _opts \\ []), do: @stub_types

  @doc "Look up a single type entry by its `type_key`. Returns nil if unknown."
  @spec get(String.t()) :: type_entry() | nil
  def get(type_key) when is_binary(type_key) do
    Enum.find(@stub_types, &(&1.type_key == type_key))
  end
end
