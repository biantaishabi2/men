defmodule MenWeb.Webhooks.DingtalkControllerTest do
  use MenWeb.ConnCase, async: false

  alias Men.Gateway.DispatchServer

  defmodule MockIngress do
    def normalize(request) do
      notify({:ingress_called, request})

      case Map.get(request.body, "mode") do
        "invalid_signature" ->
          {:error,
           %{
             code: "INVALID_SIGNATURE",
             message: "invalid signature",
             details: %{field: :signature}
           }}

        "timeout" ->
          {:ok,
           %{
             request_id: "req-timeout",
             payload: %{channel: "dingtalk", content: "timeout"},
             channel: "dingtalk",
             user_id: "user-timeout"
           }}

        _ ->
          {:ok,
           %{
             request_id: "req-ok",
             payload: %{channel: "dingtalk", content: "hello"},
             channel: "dingtalk",
             user_id: "user-ok"
           }}
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :dingtalk_controller_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:bridge_called, prompt, context})

      if prompt == "{\"channel\":\"dingtalk\",\"content\":\"timeout\"}" do
        {:error,
         %{
           type: :timeout,
           code: "CLI_TIMEOUT",
           message: "runtime timeout",
           details: %{source: :mock}
         }}
      else
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
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, _message), do: :ok
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
      ingress_adapter: MockIngress,
      dispatch_server: server_name
    )

    on_exit(fn ->
      Application.delete_env(:men, :dingtalk_controller_test_pid)
      Application.delete_env(:men, MenWeb.Webhooks.DingtalkController)
    end)

    :ok
  end

  test "主流程编排：ingress -> dispatch -> final 回写", %{conn: conn} do
    conn = post(conn, "/webhooks/dingtalk", %{"mode" => "ok"})

    body = json_response(conn, 200)
    assert body["status"] == "final"
    assert body["code"] == "OK"
    assert body["message"] == "ok-response"
    assert body["request_id"] == "req-ok"
    assert is_binary(body["run_id"])

    assert_receive {:ingress_called, request}
    assert is_binary(request.raw_body)
    assert Jason.decode!(request.raw_body) == %{"mode" => "ok"}

    assert_receive {:bridge_called, prompt, _context}
    assert Jason.decode!(prompt) == %{"channel" => "dingtalk", "content" => "hello"}
  end

  test "非法签名：被拒绝且不进入 dispatch", %{conn: conn} do
    conn = post(conn, "/webhooks/dingtalk", %{"mode" => "invalid_signature"})

    assert json_response(conn, 200) == %{
             "status" => "error",
             "code" => "INVALID_SIGNATURE",
             "message" => "invalid signature",
             "request_id" => "unknown_request",
             "run_id" => "unknown_run",
             "details" => %{"field" => "signature"}
           }

    assert_receive {:ingress_called, _request}
    refute_receive {:bridge_called, _, _}
  end

  test "bridge timeout：HTTP200 + timeout body", %{conn: conn} do
    conn = post(conn, "/webhooks/dingtalk", %{"mode" => "timeout"})

    body = json_response(conn, 200)
    assert body["status"] == "timeout"
    assert body["code"] == "CLI_TIMEOUT"
    assert body["message"] == "runtime timeout"

    assert_receive {:ingress_called, _request}

    assert_receive {:bridge_called, prompt, _context}
    assert Jason.decode!(prompt) == %{"channel" => "dingtalk", "content" => "timeout"}
  end

  test "并发请求下 dispatch 与回写语义稳定" do
    tasks =
      1..20
      |> Task.async_stream(
        fn index ->
          mode = if rem(index, 2) == 0, do: "timeout", else: "ok"

          conn =
            Phoenix.ConnTest.build_conn()
            |> post("/webhooks/dingtalk", %{"mode" => mode})

          {mode, json_response(conn, 200)}
        end,
        timeout: 5_000,
        max_concurrency: 10,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(tasks, fn
             {:ok, {"ok", body}} -> body["status"] == "final" and body["code"] == "OK"
             {:ok, {"timeout", body}} -> body["status"] == "timeout" and body["code"] == "CLI_TIMEOUT"
             _ -> false
           end)
  end
end
