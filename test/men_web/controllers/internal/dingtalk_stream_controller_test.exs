defmodule MenWeb.Internal.DingtalkStreamControllerTest do
  use MenWeb.ConnCase, async: false

  alias Men.Gateway.DispatchServer

  defmodule MockIngress do
    def normalize(params) do
      if pid = Application.get_env(:men, :dingtalk_stream_controller_test_pid) do
        send(pid, {:ingress_called, params})
      end

      case Map.get(params, "mode") do
        "invalid" ->
          {:error,
           %{code: "INVALID_REQUEST", message: "invalid payload", details: %{field: :content}}}

        _ ->
          {:ok,
           %{
             request_id: "req-stream",
             run_id: "run-stream",
             payload: %{channel: "dingtalk", content: "from-stream"},
             channel: "dingtalk",
             user_id: "stream-user",
             group_id: "stream-chat"
           }}
      end
    end
  end

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      if pid = Application.get_env(:men, :dingtalk_stream_controller_test_pid) do
        send(pid, {:bridge_called, prompt, context})
      end

      {:ok, %{text: "ok-stream"}}
    end
  end

  defmodule MockEgress do
    @behaviour Men.Channels.Egress.Adapter
    @impl true
    def send(_target, _message), do: :ok
  end

  setup do
    Application.put_env(:men, :dingtalk_stream_controller_test_pid, self())

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    start_supervised!(
      {DispatchServer, name: server_name, bridge_adapter: MockBridge, egress_adapter: MockEgress}
    )

    Application.put_env(:men, MenWeb.Internal.DingtalkStreamController,
      ingress_adapter: MockIngress,
      dispatch_server: server_name,
      internal_token: "stream-token"
    )

    on_exit(fn ->
      Application.delete_env(:men, :dingtalk_stream_controller_test_pid)
      Application.delete_env(:men, MenWeb.Internal.DingtalkStreamController)
    end)

    :ok
  end

  test "鉴权成功后 accepted 且触发 dispatch", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-men-internal-token", "stream-token")
      |> post("/internal/dingtalk/stream", %{"mode" => "ok"})

    body = json_response(conn, 200)
    assert body["status"] == "accepted"
    assert body["code"] == "ACCEPTED"
    assert body["request_id"] == "req-stream"
    assert body["run_id"] == "run-stream"

    assert_receive {:ingress_called, %{"mode" => "ok"}}
    assert_receive {:bridge_called, prompt, _context}
    assert Jason.decode!(prompt) == %{"channel" => "dingtalk", "content" => "from-stream"}
  end

  test "缺少 token 返回 401", %{conn: conn} do
    conn = post(conn, "/internal/dingtalk/stream", %{"mode" => "ok"})

    assert json_response(conn, 401) == %{
             "status" => "error",
             "code" => "UNAUTHORIZED",
             "message" => "invalid internal token"
           }
  end

  test "ingress 失败返回 400", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-men-internal-token", "stream-token")
      |> post("/internal/dingtalk/stream", %{"mode" => "invalid"})

    body = json_response(conn, 400)
    assert body["status"] == "error"
    assert body["code"] == "INVALID_REQUEST"
    assert body["message"] == "invalid payload"
  end
end
