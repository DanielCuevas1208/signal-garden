defmodule SignalGarden.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SignalGardenWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:signal_garden, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SignalGarden.PubSub},
      # The deterministic gossip simulator owns the simulation core and
      # broadcasts a snapshot to the LiveView every animation frame.
      {SignalGarden.Sim.Engine, name: SignalGarden.Sim.Engine},
      # Start to serve requests, typically the last entry
      SignalGardenWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SignalGarden.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SignalGardenWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
