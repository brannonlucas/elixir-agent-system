defmodule NervousSystem.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NervousSystemWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:nervous_system, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: NervousSystem.PubSub},
      # Registry for looking up Room processes by ID
      {Registry, keys: :unique, name: NervousSystem.RoomRegistry},
      # Start to serve requests, typically the last entry
      NervousSystemWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NervousSystem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NervousSystemWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
