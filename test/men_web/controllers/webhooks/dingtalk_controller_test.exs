defmodule MenWeb.Webhooks.DingtalkControllerTest do
  use MenWeb.ConnCase, async: false

  alias Men.Channels.Ingress.DingtalkAdapter
  alias Men.Gateway.DispatchServer

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:bridge_called, prompt, context})

      case Jason.decode(prompt) do
        {:ok, %{"content" => "bridge_error"}} ->
          {:error,
           %{
             type: :failed,
             code: "BRIDGE_FAIL",
             message: "runtime bridge failed",
             details: %{source: :mock}
           }}

        {:ok, %{"content" => "timeout"}} ->
          {:error,
           %{
             type: :timeout,
             code: "CLI_TIMEOUT",
             message: "runtime timeout",
             details: %{source: :mock}
           }}

        _ ->
          {:ok, %{text: "ok-response", meta: %{source: :mock}}}
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :dingtalk_controller_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockDispatchEgress do
    import Kernel, except: [send: 2]

    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      if pid = Application.get_env(:men, :dingtalk_controller_test_pid) do
        Kernel.send(pid, {:dispatch_egress_called, target, message})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:men, :dingtalk_controller_test_pid, self())

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
      secret: "test-dingtalk-secret",
      signature_window_seconds: 300
    )

    on_exit(fn ->
      Application.delete_env(:men, :dingtalk_controller_test_pid)
      Application.delete_env(:men, MenWeb.Webhooks.DingtalkController)
      Application.delete_env(:men, DingtalkAdapter)
    end)

    :ok
  end

  test "主流程编排：ingress -> dispatch -> final 回写", %{conn: conn} do
    {raw_body, payload} = fixture_payload_with_raw("dingtalk/happy_path.json")
    conn = signed_json_post(conn, "/webhooks/dingtalk", raw_body)

    body = json_response(conn, 200)
    assert body["status"] == "final"
    assert body["code"] == "OK"
    assert body["message"] == "ok-response"
    assert body["request_id"] == payload["event_id"]
    assert is_binary(body["run_id"])

    assert_receive {:bridge_called, prompt, context}
    assert Jason.decode!(prompt)["content"] == payload["content"]
    assert context.request_id == payload["event_id"]
    assert context.session_key == "dingtalk:#{payload["sender_id"]}"
    assert context.run_id == body["run_id"]

    assert_receive {:dispatch_egress_called, target, message}
    assert target == "dingtalk:#{payload["sender_id"]}"
    assert message.metadata.request_id == payload["event_id"]
    assert message.metadata.session_key == "dingtalk:#{payload["sender_id"]}"
    assert message.metadata.run_id == body["run_id"]
  end

  test "非法签名：401 拒绝且不进入 dispatch", %{conn: conn} do
    {raw_body, _payload} = fixture_payload_with_raw("dingtalk/invalid_signature.json")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-dingtalk-timestamp", Integer.to_string(System.system_time(:second)))
      |> put_req_header("x-dingtalk-signature", "bad-signature")
      |> post("/webhooks/dingtalk", raw_body)

    assert json_response(conn, 401)["error"] == "unauthorized"
    refute_receive {:bridge_called, _, _}
    refute_receive {:dispatch_egress_called, _, _}
  end

  test "bridge error：HTTP200 + error 语义 + 链路字段完整", %{conn: conn} do
    {raw_body, payload} = fixture_payload_with_raw("dingtalk/invalid_signature.json")
    conn = signed_json_post(conn, "/webhooks/dingtalk", raw_body)

    body = json_response(conn, 200)
    assert body["status"] == "error"
    assert body["code"] == "BRIDGE_FAIL"
    assert body["message"] == "runtime bridge failed"
    assert body["request_id"] == payload["event_id"]
    assert is_binary(body["run_id"])

    assert body["details"]["request_id"] == payload["event_id"]
    assert body["details"]["session_key"] == "dingtalk:#{payload["sender_id"]}"
    assert body["details"]["run_id"] == body["run_id"]

    assert_receive {:dispatch_egress_called, target, message}
    assert target == "dingtalk:#{payload["sender_id"]}"
    assert message.code == "BRIDGE_FAIL"
  end

  test "bridge timeout：HTTP200 + timeout 语义 + 链路字段完整", %{conn: conn} do
    {raw_body, payload} = fixture_payload_with_raw("dingtalk/bridge_timeout.json")
    conn = signed_json_post(conn, "/webhooks/dingtalk", raw_body)

    body = json_response(conn, 200)
    assert body["status"] == "timeout"
    assert body["code"] == "CLI_TIMEOUT"
    assert body["message"] == "runtime timeout"
    assert body["request_id"] == payload["event_id"]
    assert is_binary(body["run_id"])

    assert body["details"]["request_id"] == payload["event_id"]
    assert body["details"]["session_key"] == "dingtalk:#{payload["sender_id"]}"
    assert body["details"]["run_id"] == body["run_id"]

    assert_receive {:dispatch_egress_called, target, message}
    assert target == "dingtalk:#{payload["sender_id"]}"
    assert message.code == "CLI_TIMEOUT"
  end

  defp signed_json_post(conn, path, raw_body) do
    timestamp = System.system_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, "test-dingtalk-secret", Integer.to_string(timestamp) <> "\n" <> raw_body)
      |> Base.encode64()

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-dingtalk-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-dingtalk-signature", signature)
    |> post(path, raw_body)
  end

  defp fixture_payload_with_raw(path) do
    raw_body =
      "test/support/fixtures/webhooks"
      |> Path.join(path)
      |> File.read!()
      |> String.trim()

    {raw_body, Jason.decode!(raw_body)}
  end
end
