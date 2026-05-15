defmodule Contract.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail fast in :prod if required env vars are missing; warn in :dev/:test.
    :ok = Contract.Config.assert_loaded!(env())

    children = [
      ContractWeb.Telemetry,
      {Phoenix.PubSub, name: Contract.PubSub},
      Contract.Repo,
      {DNSCluster, query: Application.get_env(:contract, :dns_cluster_query) || :ignore},
      # Finch pool used by Swoosh.ApiClient.Finch. openai_ex / req each
      # manage their own pools internally, so one pool here is enough.
      {Finch, name: Swoosh.Finch},
      {Oban, Application.fetch_env!(:contract, Oban)},
      ContractWeb.Endpoint,
      # Wave 1A2 Agent runtime: per-run GenServer registry + transient supervisor.
      {Registry, keys: :unique, name: Contract.Agent.Registry},
      Contract.Agent.RunSupervisor,
      # Wave 2 Persistence runtime: per-document Session registry + transient supervisor.
      {Registry, keys: :unique, name: Contract.Session.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Contract.Session.Supervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Contract.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ContractWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp env do
    Application.get_env(:contract, :env, :dev)
  end
end
