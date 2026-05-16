defmodule Contract.Conversion.PlanCache do
  @moduledoc """
  In-memory cache for `%Contract.Conversion.Plan{}` structs (Wave 4.5,
  SPEC.md §19 deferred section).

  Conversion plans are normally transient — held in LiveView assigns. To
  let the async-OpenAI refinement worker
  (`Contract.Workers.ConversionPlanJob`) hand a refined plan back to the
  wizard, we park the plan in a small GenServer-backed map keyed by a
  caller-chosen `plan_id` (typically `"plan-<source_doc_id>-<target_type_key>"`).

  Lifecycle:

    * `put/2` overwrites whatever was there before.
    * `update/2` applies a 1-arg function to the cached plan
      atomically (no read-modify-write race).
    * `get/1` returns `{:ok, plan}` or `{:error, :not_found}`.

  The cache is **memory-only**. There is no DB migration. A node restart
  drops everything, which is fine — the wizard rebuilds the plan via the
  deterministic planner on every open.
  """

  use GenServer

  alias Contract.Conversion.Plan

  @type plan_id :: String.t()

  # --- public API --------------------------------------------------------

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Store `plan` under `plan_id`. Overwrites prior values.
  """
  @spec put(plan_id(), Plan.t()) :: :ok
  def put(plan_id, %Plan{} = plan) when is_binary(plan_id) do
    GenServer.call(__MODULE__, {:put, plan_id, plan})
  end

  @doc """
  Fetch the cached plan. Returns `{:error, :not_found}` if the key is
  unknown.
  """
  @spec get(plan_id()) :: {:ok, Plan.t()} | {:error, :not_found}
  def get(plan_id) when is_binary(plan_id) do
    GenServer.call(__MODULE__, {:get, plan_id})
  end

  @doc """
  Apply `fun` to the cached plan atomically. The function receives the
  current `%Plan{}` and must return the new `%Plan{}` (no tuple). Returns
  `:ok` on success, `{:error, :not_found}` if the key is unknown.
  """
  @spec update(plan_id(), (Plan.t() -> Plan.t())) :: :ok | {:error, :not_found}
  def update(plan_id, fun) when is_binary(plan_id) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:update, plan_id, fun})
  end

  @doc """
  Drop the entry. No-op if the key is unknown.
  """
  @spec delete(plan_id()) :: :ok
  def delete(plan_id) when is_binary(plan_id) do
    GenServer.call(__MODULE__, {:delete, plan_id})
  end

  # --- GenServer callbacks ----------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:put, plan_id, plan}, _from, state) do
    {:reply, :ok, Map.put(state, plan_id, plan)}
  end

  def handle_call({:get, plan_id}, _from, state) do
    case Map.fetch(state, plan_id) do
      {:ok, plan} -> {:reply, {:ok, plan}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update, plan_id, fun}, _from, state) do
    case Map.fetch(state, plan_id) do
      {:ok, plan} ->
        new_plan = fun.(plan)
        {:reply, :ok, Map.put(state, plan_id, new_plan)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, plan_id}, _from, state) do
    {:reply, :ok, Map.delete(state, plan_id)}
  end
end
