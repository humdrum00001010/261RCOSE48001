defmodule Contract.IO.R2Stub do
  @moduledoc """
  In-memory stand-in for `Contract.IO.R2` used by Store/Session tests so we
  don't hit the network during the snapshot path.

  Uses a shared ETS table (`:r2_stub_objects`) so background tasks and
  GenServer processes spawned during a test still see the same object map.
  """

  @table :r2_stub_objects

  @doc "Ensures the ETS table exists. Idempotent."
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Clear all stored objects + flags. Call from `setup` of each test."
  def reset do
    setup()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Toggle the next `put/3` to fail with the given reason."
  def fail_next(:put, reason) do
    setup()
    :ets.insert(@table, {{:flag, :fail_put}, reason})
    :ok
  end

  def calls do
    setup()

    @table
    |> :ets.match_object({{:call, :_}, :_})
    |> Enum.map(fn {{:call, _idx}, call} -> call end)
  end

  def objects do
    setup()

    @table
    |> :ets.match_object({{:obj, :_}, :_})
    |> Map.new(fn {{:obj, key}, body} -> {key, body} end)
  end

  def put(key, body, opts \\ []) do
    setup()
    record_call({:put, key, byte_size(body), opts})

    case :ets.lookup(@table, {:flag, :fail_put}) do
      [{_, reason}] ->
        :ets.delete(@table, {:flag, :fail_put})
        {:error, reason}

      [] ->
        :ets.insert(@table, {{:obj, key}, body})
        {:ok, %{key: key, etag: "\"stub\""}}
    end
  end

  def get(key, _opts \\ []) do
    setup()
    record_call({:get, key})

    case :ets.lookup(@table, {:obj, key}) do
      [{_, body}] -> {:ok, body}
      [] -> {:error, :not_found}
    end
  end

  def delete(key, _opts \\ []) do
    setup()
    record_call({:delete, key})
    :ets.delete(@table, {:obj, key})
    :ok
  end

  def presigned_url(key, _opts \\ []) do
    {:ok, "https://stub.r2/#{key}"}
  end

  defp record_call(call) do
    idx = :erlang.unique_integer([:monotonic])
    :ets.insert(@table, {{:call, idx}, call})
  end
end
