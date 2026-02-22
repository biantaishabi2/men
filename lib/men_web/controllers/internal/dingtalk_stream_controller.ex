defmodule MenWeb.Internal.DingtalkStreamController do
  @moduledoc """
  钉钉 Stream 内部入口：仅接收 sidecar 转发事件并投递到 dispatch。
  """

  use MenWeb, :controller

  alias Men.Channels.Ingress.DingtalkStreamAdapter
  alias Men.Gateway.DispatchServer

  def create(conn, params) do
    ingress_adapter = Keyword.get(config(), :ingress_adapter, DingtalkStreamAdapter)
    dispatch_server = Keyword.get(config(), :dispatch_server, DispatchServer)

    with :ok <- authorize(conn),
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

  defp authorize(conn) do
    with {:ok, expected_token} <- fetch_expected_token(),
         {:ok, presented_token} <- fetch_presented_token(conn),
         true <- Plug.Crypto.secure_compare(expected_token, presented_token) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :unauthorized}
    end
  end

  defp fetch_expected_token do
    token =
      Keyword.get(config(), :internal_token) ||
        System.get_env("DINGTALK_STREAM_INTERNAL_TOKEN")

    if is_binary(token) and token != "" do
      {:ok, token}
    else
      {:error, :missing_internal_token}
    end
  end

  defp fetch_presented_token(conn) do
    from_header = List.first(get_req_header(conn, "x-men-internal-token"))

    token =
      from_header ||
        bearer_token(conn)

    if is_binary(token) and token != "" do
      {:ok, token}
    else
      {:error, :unauthorized}
    end
  end

  defp bearer_token(conn) do
    case List.first(get_req_header(conn, "authorization")) do
      "Bearer " <> token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp config, do: Application.get_env(:men, __MODULE__, [])
end
