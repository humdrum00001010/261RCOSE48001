defmodule Ecrits.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail fast in :prod if required env vars are missing; warn in :dev/:test.
    :ok = Ecrits.Config.assert_loaded!(env())

    children = Ecrits.Supervision.children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ecrits.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EcritsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp env do
    Application.get_env(:ecrits, :env, :dev)
  end
end
