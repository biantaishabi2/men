defmodule Men.Integration.DingtalkWebhookFlowTest do
  use MenWeb.ConnCase, async: false

  alias Men.Channels.Ingress.DingtalkAdapter
  alias Men.Gateway.DispatchServer

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:bridge_called, prompt, context})
      {:ok, %{text: "bridge-final", meta: %{source: :integration}}}
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :dingtalk_integration_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockDispatchEgress do
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, _message), do: :ok
  end

  setup do
    Application.put_env(:men, :dingtalk_integration_test_pid, self())

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    start_supervised!(
      {DispatchServer,
       name: server_name,
       bridge_adapter: MockBridge,
       egress_adapter: MockDispatchEgress}
    )

    Application.put_env(:men, MenWeb.Webhooks.DingtalkController,
      ingress_adapter: DingtalkAdapter,
      dispatch_server: server_name
    )

    Application.put_env(:men, DingtalkAdapter,
      secret: "integration-secret",
      signature_window_seconds: 300
    )

    on_exit(fn ->
      Application.delete_env(:men, :dingtalk_integration_test_pid)
      Application.delete_env(:men, MenWeb.Webhooks.DingtalkController)
      Application.delete_env(:men, DingtalkAdapter)
    end)

    :ok
  end

  test "钉钉 webhook 进入 dispatch 主链路并返回 final 回写", %{conn: conn} do
    payload = %{
      "event_type" => "message",
      "event_id" => "evt-integration-1",
      "sender_id" => "user-integration",
      "conversation_id" => "conv-integration",
      "content" => "integration content"
    }

    timestamp = System.system_time(:second)
    raw_body = Jason.encode!(payload)

    signature =
      :crypto.mac(:hmac, :sha256, "integration-secret", Integer.to_string(timestamp) <> "\n" <> raw_body)
      |> Base.encode64()

    conn =
      conn
      |> put_req_header("x-dingtalk-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-dingtalk-signature", signature)
      |> post("/webhooks/dingtalk", payload)

    body = json_response(conn, 200)

    assert body["status"] == "final"
    assert body["code"] == "OK"
    assert body["message"] == "bridge-final"
    assert body["request_id"] == "evt-integration-1"
    assert is_binary(body["run_id"])

    assert_receive {:bridge_called, prompt, _context}

    assert Jason.decode!(prompt) == %{
             "channel" => "dingtalk",
             "event_type" => "message",
             "sender_id" => "user-integration",
             "conversation_id" => "conv-integration",
             "content" => "integration content",
             "raw_payload" => %{
               "event_type" => "message",
               "event_id" => "evt-integration-1",
               "sender_id" => "user-integration",
               "conversation_id" => "conv-integration",
               "content" => "integration content"
             }
           }
  end
end
