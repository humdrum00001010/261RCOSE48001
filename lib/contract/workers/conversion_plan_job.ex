defmodule Contract.Workers.ConversionPlanJob do
  @moduledoc """
  Background worker for asynchronous OpenAI-assisted field-plan
  refinement (SPEC.md §19, Wave 4.5).

  When `Contract.Conversion.propose_fields/2` returns a plan with ≥ 3
  fields whose strategy is `:ask_user`, the caller parks the plan in
  `Contract.Conversion.PlanCache` and enqueues a job with
  `%{"plan_id" => plan_id}`. The worker then:

    1. Fetches the cached `%Plan{}`.
    2. Filters the ambiguous (`:ask_user`) field plans.
    3. Calls `Contract.IO.OpenAI.one_shot/2` with a JSON-format prompt
       that lists each ambiguous source field + the target type semantics.
    4. Parses the model's JSON `{"refinements": [...]}` body.
    5. Atomically patches the cached plan via
       `PlanCache.update/2`, only touching field plans whose
       `source_field_id` appears in the refinement set AND whose suggested
       strategy is in `Contract.Conversion.allowed_strategies/0` (so the
       LLM can't smuggle in a junk atom).
    6. Broadcasts `{:plan_refined, plan_id}` on `"plan:<plan_id>"`.

  Hard guarantees:

    * Malformed JSON / driver error → the cached plan is left untouched
      (no crash, no broadcast). Oban will retry per `max_attempts`.
    * Unknown `plan_id` (e.g. the user closed the wizard) → silent `:ok`.
    * Refinements that target a field which is no longer `:ask_user` are
      ignored (user already picked a strategy).

  Args:

      %{ "plan_id" => string }
  """
  use Oban.Worker, queue: :agent, max_attempts: 3

  alias Contract.Conversion
  alias Contract.Conversion.{FieldPlan, Plan, PlanCache}

  @pubsub Contract.PubSub

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"plan_id" => plan_id}}) when is_binary(plan_id) do
    case PlanCache.get(plan_id) do
      {:ok, %Plan{} = plan} ->
        ambiguous = Enum.filter(plan.field_plans || [], &(&1.strategy == :ask_user))

        case analyze_with_openai(ambiguous, plan) do
          [] ->
            # Either no ambiguous fields or the driver failed / returned
            # garbage. Leave the plan alone; do not broadcast a no-op
            # "refined" event (the UI would otherwise flash the indicator).
            :ok

          refinements when is_list(refinements) ->
            :ok =
              PlanCache.update(plan_id, fn cached ->
                apply_refinements(cached, refinements)
              end)

            Phoenix.PubSub.broadcast(@pubsub, topic(plan_id), {:plan_refined, plan_id})
            :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  def perform(%Oban.Job{args: args}), do: {:error, {:bad_plan_args, args}}

  @doc "PubSub topic the wizard subscribes to for refinement notifications."
  @spec topic(String.t()) :: String.t()
  def topic(plan_id) when is_binary(plan_id), do: "plan:" <> plan_id

  # --- internals --------------------------------------------------------

  defp analyze_with_openai([], _plan), do: []

  defp analyze_with_openai(ambiguous_fields, %Plan{} = plan) do
    prompt = build_prompt(ambiguous_fields, plan)

    request = %{
      input: prompt,
      reasoning: %{effort: "medium"},
      text: %{format: %{type: "json_object"}}
    }

    # MCP tools are irrelevant for this short JSON-only call.
    opts = [include_law_mcp?: false, include_slack_mcp?: false]

    case driver().one_shot(request, opts) do
      {:ok, response} ->
        response
        |> extract_text()
        |> parse_refinements()

      {:error, _reason} ->
        []
    end
  end

  defp build_prompt(ambiguous_fields, %Plan{} = plan) do
    source_key = plan.source_type_key || "unknown"
    target_key = plan.target_type_key

    fields_json =
      ambiguous_fields
      |> Enum.map(fn %FieldPlan{} = fp ->
        %{
          "source_field_id" => fp.source_field_id,
          "target_field_id" => fp.target_field_id,
          "current_justification" => fp.justification
        }
      end)
      |> Jason.encode!()

    """
    You are a contract-type-conversion assistant. The user is converting a
    document from contract type "#{source_key}" to "#{target_key}". The
    deterministic planner marked the following fields as ambiguous
    (:ask_user). For each one, recommend one of the strategies:
      - "copy_once"             (snapshot the source value)
      - "link_to_matter_field"  (reference a matter-level fact)
      - "derive"                (computed reference)
      - "reference_only"        (leave value in source, point at it)
      - "ignore"                (drop the field)
      - "ask_user"              (still genuinely ambiguous — leave to the user)

    Reply with a single JSON object of the shape:

      {
        "refinements": [
          {
            "source_field_id": "...",
            "suggested_strategy": "copy_once",
            "justification": "..."
          },
          ...
        ]
      }

    Only include fields you have an opinion on. Do NOT invent
    source_field_ids that are not in the input list.

    Ambiguous fields: #{fields_json}
    """
  end

  # ---- response parsing ------------------------------------------------

  # Responses-API shape: prefer `output_text` shortcut when present,
  # otherwise walk `output[].content[].text`. Falls back to `""` for any
  # shape we don't recognise (treated as a parse failure → no refinement).
  defp extract_text(%{"output_text" => text}) when is_binary(text), do: text

  defp extract_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"content" => content} when is_list(content) -> content
      _ -> []
    end)
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"text" => %{"value" => v}} when is_binary(v) -> v
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_text(%{output_text: text}) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp parse_refinements(""), do: []

  defp parse_refinements(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"refinements" => refs}} when is_list(refs) -> refs
      _ -> []
    end
  end

  # ---- merge refinements back into the plan ----------------------------

  defp apply_refinements(%Plan{field_plans: plans} = plan, refinements)
       when is_list(plans) and is_list(refinements) do
    by_id =
      refinements
      |> Enum.reduce(%{}, fn ref, acc ->
        with id when is_binary(id) <- ref["source_field_id"],
             strategy_str when is_binary(strategy_str) <- ref["suggested_strategy"],
             strategy when is_atom(strategy) <- to_strategy(strategy_str),
             true <- strategy in Conversion.allowed_strategies() do
          Map.put(acc, id, %{
            strategy: strategy,
            justification: ref["justification"] || ref["rationale"]
          })
        else
          _ -> acc
        end
      end)

    new_plans =
      Enum.map(plans, fn
        %FieldPlan{strategy: :ask_user, source_field_id: id} = fp ->
          case Map.fetch(by_id, id) do
            {:ok, %{strategy: strategy, justification: just}} ->
              %FieldPlan{
                fp
                | strategy: strategy,
                  justification: just || fp.justification
              }

            :error ->
              fp
          end

        fp ->
          # Field is no longer :ask_user — the user already resolved it
          # while OpenAI was thinking. Don't clobber.
          fp
      end)

    %Plan{plan | field_plans: new_plans}
  end

  defp apply_refinements(%Plan{} = plan, _), do: plan

  defp to_strategy(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> nil
    end
  end

  defp driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:openai, Contract.IO.OpenAI)
  end
end
