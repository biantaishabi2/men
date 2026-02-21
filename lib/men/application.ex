defmodule Men.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        MenWeb.Telemetry,
        Men.Repo,
        {DNSCluster, query: Application.get_env(:men, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Men.PubSub},
        # Start the Finch HTTP client for sending emails
        {Finch, name: Men.Finch}
      ] ++
        gateway_children() ++
        [
          # Start a worker by calling: Men.Worker.start_link(arg)
          # {Men.Worker, arg},
          # Start to serve requests, typically the last entry
          MenWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Men.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp gateway_children do
    coordinator_enabled? =
      Application.get_env(:men, Men.Gateway.SessionCoordinator, [])
      |> Keyword.get(:enabled, true)

    if coordinator_enabled? do
      [
        {Men.Gateway.SessionCoordinator, []},
        {Men.Gateway.DispatchServer, []}
      ]
    else
      [{Men.Gateway.DispatchServer, []}]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MenWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
