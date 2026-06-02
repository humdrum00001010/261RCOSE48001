defmodule Ecrits.Local.Agent.OrchexAdapter do
  @moduledoc """
  Orchex adapter backed by existing local agent sessions.
  """

  @behaviour Orchex.Adapter

  alias Ecrits.Local.Agent.Session
  alias Ecrits.Local.Agent.SessionSupervisor
  alias Ecrits.Local.Agent.ToolRegistry

  @impl true
  def init(config) do
    providers = config |> Keyword.get(:providers, []) |> normalize_providers()
    {:ok, %{providers: providers, provider_ids: Enum.map(providers, & &1.id)}}
  end

  @impl true
  def spawn_agent(role, session_id, agent_config, state) do
    opts = session_opts(role)
    provider_id = provider_id(opts, agent_config)

    with {:ok, provider} <- fetch_provider(state, provider_id) do
      id = session_id || Keyword.get(opts, :id) || Ecto.UUID.generate()
      adapter = Keyword.get(opts, :adapter, provider.adapter)
      adapter_opts = Keyword.merge(provider.adapter_opts, Keyword.get(opts, :adapter_opts, []))

      args =
        opts
        |> Keyword.put(:id, id)
        |> Keyword.put(:ctx, Keyword.get(opts, :ctx))
        |> Keyword.put(:provider, public_provider_metadata(provider))
        |> Keyword.put(:adapter, adapter)
        |> Keyword.put(:adapter_opts, adapter_opts)

      case SessionSupervisor.start_session(args) do
        {:ok, pid} -> {:ok, agent_state(id, pid, opts), state}
        {:ok, pid, _info} -> {:ok, agent_state(id, pid, opts), state}
        {:error, {:already_started, pid}} -> {:ok, agent_state(id, pid, opts), state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def kill_agent(_aid, agent_state, state) do
    case session_pid(agent_state) do
      pid when is_pid(pid) ->
        GenServer.stop(pid)
        {:ok, state}

      nil ->
        {:ok, state}
    end
  end

  @impl true
  def query_agent(_aid, message, sender, agent_state, state) do
    with :ok <- validate_sender(sender),
         {:ok, pid} <- fetch_session(agent_state),
         {:ok, reply} <- Session.send_turn(pid, Map.get(agent_state, :ctx), message, []) do
      {:ok, reply, agent_state, state}
    else
      {:error, reason} -> {:error, reason, agent_state, state}
    end
  end

  @impl true
  def notify_agent(_aid, event, agent_state, state) do
    case fetch_session(agent_state) do
      {:ok, pid} ->
        _ = Session.send_turn(pid, Map.get(agent_state, :ctx), event, [])
        {:ok, agent_state, state}

      {:error, _reason} ->
        {:ok, agent_state, state}
    end
  end

  def config(providers) do
    [
      adapter: __MODULE__,
      adapter_config: [providers: providers],
      mcp_endpoints: [],
      skills: ToolRegistry.tools(),
      provider: default_provider_id(providers),
      provider_config: %{}
    ]
  end

  defp normalize_providers(providers) when is_list(providers) do
    Enum.map(providers, fn provider ->
      provider
      |> Map.new()
      |> Map.update!(:id, &normalize_provider_id/1)
      |> Map.update(:adapter_opts, [], &(&1 || []))
    end)
  end

  defp session_opts(%{opts: opts}) when is_list(opts), do: opts
  defp session_opts(%{"opts" => opts}) when is_list(opts), do: opts
  defp session_opts(opts) when is_list(opts), do: opts

  defp session_opts(role) when is_map(role) do
    role
    |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
    |> Keyword.new()
  end

  defp session_opts(_role), do: []

  defp provider_id(opts, agent_config) do
    opts
    |> Keyword.get(:provider, Map.get(agent_config, :provider, "codex"))
    |> normalize_provider_id()
  end

  defp fetch_provider(state, id) do
    case Enum.find(state.providers, &(&1.id == id)) do
      nil -> {:error, {:unsupported_provider, id, state.provider_ids}}
      provider -> {:ok, provider}
    end
  end

  defp public_provider_metadata(provider) do
    %{
      id: provider.id,
      label: provider.label,
      icon: provider.icon,
      favicon_src: provider.favicon_src
    }
  end

  defp agent_state(id, pid, opts) do
    %{session_id: id, pid: pid, ctx: Keyword.get(opts, :ctx)}
  end

  defp fetch_session(%{session_id: id}) when is_binary(id) do
    case Session.whereis(id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_session(_agent_state), do: {:error, :not_found}

  defp session_pid(%{session_id: id}) when is_binary(id), do: Session.whereis(id)
  defp session_pid(_agent_state), do: nil

  defp validate_sender(sender) when sender in [:user, :agent], do: :ok
  defp validate_sender(sender), do: {:error, {:invalid_sender, sender}}

  defp normalize_provider_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_provider_id(id) when is_binary(id), do: id
  defp normalize_provider_id(id), do: to_string(id)

  defp default_provider_id([%{id: id} | _providers]), do: normalize_provider_id(id)
  defp default_provider_id(_providers), do: "codex"

  defp normalize_key("adapter"), do: :adapter
  defp normalize_key("adapter_opts"), do: :adapter_opts
  defp normalize_key("ctx"), do: :ctx
  defp normalize_key("id"), do: :id
  defp normalize_key("provider"), do: :provider
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: key
end
