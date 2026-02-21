defmodule MenWeb.Webhooks.FeishuController do
  use MenWeb, :controller

  alias Men.Channels.Ingress.FeishuAdapter
  alias Men.Gateway.DispatchServer

  def create(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""

    request = %{
      headers: extract_headers(conn),
      body: raw_body
    }

    case FeishuAdapter.normalize(request) do
      {:ok, inbound_event} ->
        _ = dispatch(inbound_event)
        json(conn, %{status: "accepted"})

      {:error, reason} ->
        if FeishuAdapter.unauthorized_reason?(reason) do
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "unauthorized"})
        else
          conn
          |> put_status(:bad_request)
          |> json(%{error: "bad_request", reason: inspect(reason)})
        end
    end
  end

  defp dispatch(inbound_event) do
    config = Application.get_env(:men, __MODULE__, [])

    case Keyword.get(config, :dispatch_fun) do
      fun when is_function(fun, 1) ->
        fun.(inbound_event)

      _ ->
        dispatch_server = Keyword.get(config, :dispatch_server, DispatchServer)
        dispatch_server.dispatch(inbound_event)
    end
  end

  defp extract_headers(conn) do
    %{
      "x-lark-signature" => first_header(conn, "x-lark-signature"),
      "x-lark-request-timestamp" => first_header(conn, "x-lark-request-timestamp"),
      "x-lark-nonce" => first_header(conn, "x-lark-nonce")
    }
  end

  defp first_header(conn, key) do
    case get_req_header(conn, key) do
      [value | _] -> value
      _ -> nil
    end
  end
end
