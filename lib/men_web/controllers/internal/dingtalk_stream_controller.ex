defmodule MenWeb.Internal.DingtalkStreamController do
  @moduledoc """
  钉钉 Stream 内部入口：仅接收 sidecar 转发事件并投递到 dispatch。
  """

  use MenWeb, :controller

  alias Men.Channels.Ingress.DingtalkStreamAdapter
  alias Men.Gateway.DispatchServer
  alias MenWeb.InternalAuth

  def create(conn, params) do
    ingress_adapter = Keyword.get(config(), :ingress_adapter, DingtalkStreamAdapter)
    dispatch_server = Keyword.get(config(), :dispatch_server, DispatchServer)

    with :ok <- InternalAuth.authorize(conn, config: config()),
         {:ok, inbound_event} <- ingress_adapter.normalize(params),
         :ok <- DispatchServer.enqueue(dispatch_server, inbound_event) do
      conn
      |> put_status(:ok)
      |> json(%{
        status: "accepted",
        code: "ACCEPTED",
        request_id: Map.get(inbound_event, :request_id),
        run_id: Map.get(inbound_event, :run_id)
      })
    else
      {:error, :missing_internal_token} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "error",
          code: "INTERNAL_TOKEN_MISSING",
          message: "internal stream token is not configured"
        })

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          status: "error",
          code: "UNAUTHORIZED",
          message: "invalid internal token"
        })

      {:error, :dispatch_server_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "error",
          code: "DISPATCH_UNAVAILABLE",
          message: "dispatch server unavailable"
        })

      {:error, ingress_error} when is_map(ingress_error) ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          status: "error",
          code: Map.get(ingress_error, :code, "INGRESS_REJECTED"),
          message: Map.get(ingress_error, :message, "invalid stream payload"),
          details: Map.get(ingress_error, :details, %{})
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          status: "error",
          code: "INVALID_REQUEST",
          message: inspect(reason)
        })
    end
  end

  defp config, do: Application.get_env(:men, __MODULE__, [])
end
