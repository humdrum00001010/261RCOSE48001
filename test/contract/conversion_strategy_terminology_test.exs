defmodule Contract.ConversionStrategyTerminologyTest do
  use Contract.DataCase, async: false
  use Oban.Testing, repo: Contract.Repo

  import Mox

  alias Contract.Conversion
  alias Contract.Conversion.{FieldPlan, Plan, PlanCache}
  alias Contract.Context
  alias Contract.Documents
  alias Contract.IO.R2Stub
  alias Contract.Matters
  alias Contract.Workers.ConversionPlanJob

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    R2Stub.setup()
    R2Stub.reset()
    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)
    :ok
  end

  defp scope do
    %Context{
      user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "u@x"},
      tenant: Ecto.UUID.generate(),
      perms: [:type_change, :read, :write]
    }
  end

  defp source_doc(scope) do
    {:ok, matter} = Matters.create(scope, %{"name" => "m"})

    {:ok, doc} =
      Documents.create(scope, %{
        "matter_id" => matter.id,
        "title" => "src",
        "type_key" => "nda_v1"
      })

    doc
  end

  test "document identity facts use shared fact strategy terminology" do
    scope = scope()
    doc = source_doc(scope)

    assert {:ok, %Plan{} = plan} = Conversion.plan(scope, doc.id, "service_agreement_v1", [])

    assert :link_to_shared_fact in Conversion.allowed_strategies()
    refute :link_to_matter_field in Conversion.allowed_strategies()

    shared_fact_plans = Enum.filter(plan.field_plans, &(&1.strategy == :link_to_shared_fact))
    assert shared_fact_plans != []

    assert Enum.all?(shared_fact_plans, fn plan ->
             String.contains?(plan.justification, "shared fact")
           end)
  end

  test "legacy matter field strategy input maps to shared fact strategy" do
    scope = scope()
    doc = source_doc(scope)
    {:ok, plan} = Conversion.plan(scope, doc.id, "service_agreement_v1", [])
    [first | _] = plan.field_plans

    assert {:ok, %Plan{field_plans: field_plans}} =
             Conversion.set_field_strategy(
               scope,
               plan,
               first.source_field_id,
               :link_to_matter_field
             )

    assert Enum.find(field_plans, &(&1.source_field_id == first.source_field_id)).strategy ==
             :link_to_shared_fact
  end

  test "legacy matter field lineage strategy persists as shared fact" do
    scope = scope()
    source = source_doc(scope)
    {:ok, %Plan{} = plan} = Conversion.plan(scope, source.id, "service_agreement_v1", [])
    [first | _] = Enum.reject(plan.field_plans, &(&1.strategy in [:ignore, :ask_user]))

    plan = %Plan{
      plan
      | field_plans:
          Enum.map(plan.field_plans, fn %FieldPlan{} = fp ->
            if fp.source_field_id == first.source_field_id,
              do: %FieldPlan{fp | strategy: :link_to_matter_field},
              else: fp
          end)
    }

    {:ok, {new_doc, _change}} = Conversion.create_variant(scope, plan)

    assert Enum.any?(Documents.list_lineage(scope, new_doc.id), fn lineage ->
             lineage.source_field_id == first.source_field_id and
               lineage.strategy == :link_to_shared_fact
           end)
  end

  test "legacy matter field model output maps to shared fact strategy" do
    plan = %Plan{
      source_document_id: "doc-#{System.unique_integer([:positive])}",
      source_type_key: "nda_v1",
      target_type_key: "service_agreement_v1",
      strategies: Conversion.allowed_strategies(),
      field_plans: [
        %FieldPlan{
          source_field_id: "field_1",
          target_field_id: "field_1",
          strategy: :ask_user,
          justification: "ambiguous"
        }
      ]
    }

    plan_id = Conversion.plan_id(plan)
    :ok = PlanCache.put(plan_id, plan)

    refinements_json =
      Jason.encode!(%{
        "refinements" => [
          %{
            "source_field_id" => "field_1",
            "suggested_strategy" => "link_to_matter_field",
            "justification" => "Legacy strategy name."
          }
        ]
      })

    Contract.IO.OpenAIMock
    |> expect(:one_shot, fn _params, _opts -> {:ok, %{"output_text" => refinements_json}} end)

    assert :ok = perform_job(ConversionPlanJob, %{"plan_id" => plan_id})

    {:ok, refined} = PlanCache.get(plan_id)
    [field_plan] = refined.field_plans
    assert field_plan.strategy == :link_to_shared_fact
  end
end
