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
    import Kernel, except: [send: 2]

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      if pid = Application.get_env(:men, :dingtalk_integration_test_pid) do
        Kernel.send(pid, {:egress_called, target, message})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:men, :dingtalk_integration_test_pid, self())

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    start_supervised!(
      {DispatchServer,
       name: server_name, bridge_adapter: MockBridge, egress_adapter: MockDispatchEgress}
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

  test "钉钉 webhook 进入主链路后立即 ACK，并在后台完成处理", %{conn: conn} do
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
      :crypto.mac(
        :hmac,
        :sha256,
        "integration-secret",
        Integer.to_string(timestamp) <> "\n" <> raw_body
      )
      |> Base.encode64()

    conn =
      conn
      |> put_req_header("x-dingtalk-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-dingtalk-signature", signature)
      |> post("/webhooks/dingtalk", payload)

    body = json_response(conn, 200)
    assert body["status"] == "accepted"
    assert body["code"] == "ACCEPTED"
    assert body["request_id"] == "evt-integration-1"

    assert_receive {:bridge_called, prompt, _context}

    assert_receive {:egress_called, "dingtalk:user-integration",
                    %Men.Channels.Egress.Messages.EventMessage{event_type: :final}}

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
