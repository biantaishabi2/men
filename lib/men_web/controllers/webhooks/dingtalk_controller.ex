defmodule MenWeb.Webhooks.DingtalkController do
  @moduledoc """
  钉钉 webhook 控制器：仅负责 ingress -> dispatch -> egress 编排。
  """

  use MenWeb, :controller

  alias Men.Channels.Egress.DingtalkAdapter, as: DingtalkEgress
  alias Men.Channels.Ingress.DingtalkAdapter, as: DingtalkIngress
  alias Men.Gateway.DispatchServer

  def callback(conn, params) do
    request = %{
      headers: Map.new(conn.req_headers),
      body: params,
      raw_body: conn.assigns[:raw_body] || conn.private[:raw_body]
    }

    ingress_adapter = Keyword.get(config(), :ingress_adapter, DingtalkIngress)
    dispatch_server = Keyword.get(config(), :dispatch_server, DispatchServer)
    egress_adapter = Keyword.get(config(), :egress_adapter, DingtalkEgress)

    dispatch_result =
      case ingress_adapter.normalize(request) do
        {:ok, inbound_event} -> DispatchServer.dispatch(dispatch_server, inbound_event)
        {:error, ingress_error} -> {:error, ingress_error_to_dispatch_error(ingress_error)}
      end

    {status, body} = egress_adapter.to_webhook_response(dispatch_result)

    conn
    |> put_status(status)
    |> json(body)
  end

  defp config do
    Application.get_env(:men, __MODULE__, [])
  end

  defp ingress_error_to_dispatch_error(error) when is_map(error) do
    %{
      session_key: "dingtalk:unknown",
      run_id: "unknown_run",
      request_id: "unknown_request",
      reason: Map.get(error, :message, "ingress rejected"),
      code: Map.get(error, :code, "INGRESS_REJECTED"),
      metadata: Map.get(error, :details, %{})
    }
  end

  defp ingress_error_to_dispatch_error(error) do
    %{
      session_key: "dingtalk:unknown",
      run_id: "unknown_run",
      request_id: "unknown_request",
      reason: inspect(error),
      code: "INGRESS_REJECTED",
      metadata: %{}
    }
  end
end
