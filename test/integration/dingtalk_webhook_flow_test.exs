defmodule Men.Integration.DingtalkWebhookFlowTest do
  use MenWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Men.Channels.Ingress.DingtalkAdapter
  alias Men.Gateway.DispatchServer

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, _context) do
      decoded = Jason.decode!(prompt)

      case decoded["content"] do
        "bridge_fail" ->
          {:error, %{status: :error, type: :failed, message: "bridge failed", details: %{source: :mock}}}

        _ ->
          {:ok, %{status: :ok, text: "bridge-final", meta: %{source: :mock}}}
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

  test "happy path: webhook ACK 后异步完成 final 回写", %{conn: conn} do
    payload = %{
      "event_type" => "message",
      "event_id" => "evt-integration-1",
      "sender_id" => "user-integration",
      "conversation_id" => "conv-integration",
      "content" => "integration content"
    }

    conn = post_signed(conn, payload)
    body = json_response(conn, 200)
    assert body["status"] == "accepted"
    assert body["request_id"] == "evt-integration-1"

    assert_receive {:egress_called, _target, %Men.Channels.Egress.Messages.FinalMessage{}}, 1_000
  end

  test "signature fail: 请求被拒绝且 bridge 不被调用", %{conn: conn} do
    payload = %{
      "event_type" => "message",
      "event_id" => "evt-integration-2",
      "sender_id" => "user-integration",
      "conversation_id" => "conv-integration",
      "content" => "integration content"
    }

    timestamp = System.system_time(:second)

    conn =
      conn
      |> put_req_header("x-dingtalk-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-dingtalk-signature", "broken-sign")
      |> post("/webhooks/dingtalk", payload)

    assert json_response(conn, 401)["error"] == "unauthorized"
    refute_receive {:egress_called, _, _}
  end

  test "bridge fail: egress 回写错误摘要并包含结构化日志字段", %{conn: conn} do
    payload = %{
      "event_type" => "message",
      "event_id" => "evt-integration-3",
      "sender_id" => "user-integration",
      "conversation_id" => "conv-integration",
      "content" => "bridge_fail"
    }

    log =
      capture_log(fn ->
        conn = post_signed(conn, payload)
        assert json_response(conn, 200)["status"] == "accepted"
      end)

    assert_receive {:egress_called, _target, %Men.Channels.Egress.Messages.ErrorMessage{} = err}, 1_000
    assert err.code == "bridge_error"
    assert log =~ "gateway.dispatch"
    assert log =~ "request_id="
    assert log =~ "session_key="
    assert log =~ "run_id="
  end

  defp post_signed(conn, payload) do
    timestamp = System.system_time(:second)
    raw_body = Jason.encode!(payload)

    signature =
      :crypto.mac(:hmac, :sha256, "integration-secret", Integer.to_string(timestamp) <> "\n" <> raw_body)
      |> Base.encode64()

    conn
    |> put_req_header("x-dingtalk-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-dingtalk-signature", signature)
    |> post("/webhooks/dingtalk", payload)
  end
end
