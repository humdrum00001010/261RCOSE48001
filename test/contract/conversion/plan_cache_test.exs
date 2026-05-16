defmodule Contract.Conversion.PlanCacheTest do
  use ExUnit.Case, async: false

  alias Contract.Conversion.{FieldPlan, Plan, PlanCache}

  defp build_plan(opts \\ []) do
    %Plan{
      source_document_id: Keyword.get(opts, :doc_id, Ecto.UUID.generate()),
      target_type_key: Keyword.get(opts, :target, "service_agreement_v1"),
      source_type_key: Keyword.get(opts, :source, "nda_v1"),
      strategies: [:copy_once, :ask_user],
      field_plans:
        Keyword.get(opts, :field_plans, [
          %FieldPlan{
            source_field_id: "f1",
            target_field_id: "f1",
            strategy: :ask_user,
            justification: "deterministic-default"
          }
        ]),
      impact: %{compatible?: true}
    }
  end

  describe "put/2 + get/1 round-trip" do
    test "stores and retrieves a plan" do
      plan = build_plan()
      key = "plan-fixture-#{System.unique_integer([:positive])}"

      assert :ok = PlanCache.put(key, plan)
      assert {:ok, ^plan} = PlanCache.get(key)
    end
  end

  describe "update/2" do
    test "applies the function atomically and returns :ok" do
      plan = build_plan()
      key = "plan-update-#{System.unique_integer([:positive])}"
      assert :ok = PlanCache.put(key, plan)

      assert :ok =
               PlanCache.update(key, fn %Plan{} = cached ->
                 [%FieldPlan{} = fp] = cached.field_plans
                 %Plan{cached | field_plans: [%FieldPlan{fp | strategy: :copy_once}]}
               end)

      assert {:ok, updated} = PlanCache.get(key)
      assert [%FieldPlan{strategy: :copy_once}] = updated.field_plans
    end

    test "returns {:error, :not_found} for an unknown plan_id" do
      assert {:error, :not_found} =
               PlanCache.update("nope-#{System.unique_integer([:positive])}", & &1)
    end
  end

  describe "get/1 on unknown plan_id" do
    test "returns {:error, :not_found}" do
      assert {:error, :not_found} =
               PlanCache.get("ghost-#{System.unique_integer([:positive])}")
    end
  end

  describe "put/2 overwrites prior values" do
    test "second put replaces the first" do
      key = "plan-overwrite-#{System.unique_integer([:positive])}"
      first = build_plan(target: "service_agreement_v1")
      second = build_plan(target: "supply_v1")

      assert :ok = PlanCache.put(key, first)
      assert :ok = PlanCache.put(key, second)
      assert {:ok, %Plan{target_type_key: "supply_v1"}} = PlanCache.get(key)
    end
  end
end
