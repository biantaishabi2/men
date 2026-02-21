defmodule MenWeb.Webhooks.DingtalkController do
  @moduledoc """
  钉钉 webhook 控制器：同步 ACK 仅表示“已接收”。
  """

  use MenWeb, :controller

  alias Men.Channels.Ingress.DingtalkAdapter, as: DingtalkIngress
  alias Men.Gateway.DispatchServer

  def callback(conn, params) do
    request = %{
      headers: Map.new(conn.req_headers),
      body: params,
      raw_body: resolve_raw_body(conn, params)
    }

    ingress_adapter = Keyword.get(config(), :ingress_adapter, DingtalkIngress)
    dispatch_server = Keyword.get(config(), :dispatch_server, DispatchServer)

    case ingress_adapter.normalize(request) do
      {:ok, inbound_event} ->
        case DispatchServer.enqueue(dispatch_server, inbound_event) do
          :ok ->
            conn
            |> put_status(:ok)
            |> json(%{
              status: "accepted",
              code: "ACCEPTED",
              request_id: inbound_event.request_id
            })

          {:error, :dispatch_server_unavailable} ->
            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "dispatch_unavailable"})
        end

      {:error, :signature_invalid} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "bad_request", reason: inspect(reason)})
    end
  end

  defp config do
    Application.get_env(:men, __MODULE__, [])
  end

  # 测试/兼容场景下可能拿不到 parser 注入的 raw_body，这里兜底编码一次。
  defp resolve_raw_body(conn, params) do
    conn.assigns[:raw_body] ||
      conn.private[:raw_body] ||
      Jason.encode!(params)
  end
end
