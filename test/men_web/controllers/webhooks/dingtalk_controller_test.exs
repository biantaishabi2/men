defmodule MenWeb.Webhooks.DingtalkControllerTest do
  use MenWeb.ConnCase, async: false

  alias Men.Gateway.DispatchServer

  defmodule MockIngress do
    def normalize(request) do
      if pid = Application.get_env(:men, :dingtalk_controller_test_pid) do
        send(pid, {:ingress_called, request})
      end

      case Map.get(request.body, "mode") do
        "invalid_signature" ->
          {:error, :signature_invalid}

        _ ->
          {:ok,
           %{
             request_id: "req-ok",
             payload: "hello",
             channel: "dingtalk",
             event_type: "message",
             user_id: "user-ok"
           }}
      end
    end
  end

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      if pid = Application.get_env(:men, :dingtalk_controller_test_pid) do
        send(pid, {:bridge_called, prompt, context})
      end

      {:ok, %{status: :ok, text: "ok-response", meta: %{source: :mock}}}
    end
  end

  defmodule MockDispatchEgress do
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, _message), do: :ok
  end

  setup do
    Application.put_env(:men, :dingtalk_controller_test_pid, self())

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    start_supervised!(
      {DispatchServer,
       name: server_name, bridge_adapter: MockBridge, egress_adapter: MockDispatchEgress}
    )

    Application.put_env(:men, MenWeb.Webhooks.DingtalkController,
      ingress_adapter: MockIngress,
      dispatch_server: server_name
    )

    on_exit(fn ->
      Application.delete_env(:men, :dingtalk_controller_test_pid)
      Application.delete_env(:men, MenWeb.Webhooks.DingtalkController)
    end)

    :ok
  end

  test "主流程：ingress -> enqueue，HTTP 立即 accepted", %{conn: conn} do
    conn = post(conn, "/webhooks/dingtalk", %{"mode" => "ok"})

    body = json_response(conn, 200)
    assert body["status"] == "accepted"
    assert body["code"] == "ACCEPTED"
    assert body["request_id"] == "req-ok"

    assert_receive {:ingress_called, request}, 1_000
    assert is_binary(request.raw_body)

    assert_receive {:bridge_called, "hello", _context}, 1_000
  end

  test "非法签名：请求被拒绝且不进入 dispatch", %{conn: conn} do
    conn = post(conn, "/webhooks/dingtalk", %{"mode" => "invalid_signature"})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert_receive {:ingress_called, _request}, 1_000
    refute_receive {:bridge_called, _, _}
  end

  test "慢桥接不阻塞 webhook ACK" do
    started_at = System.monotonic_time(:millisecond)
    conn = Phoenix.ConnTest.build_conn() |> post("/webhooks/dingtalk", %{"mode" => "ok"})
    duration_ms = System.monotonic_time(:millisecond) - started_at

    body = json_response(conn, 200)
    assert body["status"] == "accepted"
    assert duration_ms < 150
  end
end
