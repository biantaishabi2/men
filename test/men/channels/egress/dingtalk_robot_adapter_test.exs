defmodule Men.Channels.Egress.DingtalkRobotAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.DingtalkRobotAdapter
  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}

  defmodule MockTransport do
    @behaviour Men.Channels.Egress.DingtalkRobotAdapter.HttpTransport

    @impl true
    def post(url, headers, body, _opts) do
      if pid = Application.get_env(:men, :dingtalk_robot_test_pid) do
        send(pid, {:transport_post, url, headers, body})
      end

      mode = Application.get_env(:men, :dingtalk_robot_test_mode, :ok)

      case mode do
        :ok ->
          {:ok, %{status: 200, body: %{"errcode" => 0, "errmsg" => "ok"}}}

        :dingtalk_error ->
          {:ok, %{status: 200, body: %{"errcode" => 310_000, "errmsg" => "invalid user"}}}

        :http_error ->
          {:ok, %{status: 500, body: %{"error" => "server error"}}}

        :network_error ->
          {:error, :timeout}
      end
    end
  end

  setup do
    Application.put_env(:men, :dingtalk_robot_test_pid, self())
    Application.put_env(:men, :dingtalk_robot_test_mode, :ok)

    Application.put_env(:men, DingtalkRobotAdapter,
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=test-token",
      sign_enabled: false,
      transport: MockTransport
    )

    on_exit(fn ->
      Application.delete_env(:men, :dingtalk_robot_test_pid)
      Application.delete_env(:men, :dingtalk_robot_test_mode)
      Application.delete_env(:men, DingtalkRobotAdapter)
    end)

    :ok
  end

  test "发送 FinalMessage 成功" do
    message = %FinalMessage{
      session_key: "dingtalk:u1",
      content: "done",
      metadata: %{request_id: "req-1", run_id: "run-1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_post, url, headers, body}
    assert String.contains?(url, "access_token=test-token")
    assert {"content-type", "application/json"} in headers

    decoded = Jason.decode!(body)
    assert decoded["msgtype"] == "text"
    assert String.contains?(decoded["text"]["content"], "request_id=req-1")
    assert String.contains?(decoded["text"]["content"], "run_id=run-1")
  end

  test "发送 ErrorMessage 成功并带 code" do
    message = %ErrorMessage{
      session_key: "dingtalk:u1",
      reason: "bridge failed",
      code: "BRIDGE_FAIL",
      metadata: %{request_id: "req-2", run_id: "run-2"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_post, _url, _headers, body}
    decoded = Jason.decode!(body)
    assert String.contains?(decoded["text"]["content"], "[BRIDGE_FAIL]")
  end

  test "钉钉业务错误会返回标准错误" do
    Application.put_env(:men, :dingtalk_robot_test_mode, :dingtalk_error)

    message = %FinalMessage{session_key: "dingtalk:u1", content: "hello", metadata: %{}}

    assert {:error, {:dingtalk_error, 310_000, "invalid user"}} =
             DingtalkRobotAdapter.send("dingtalk:u1", message)
  end

  test "HTTP 错误会返回标准错误" do
    Application.put_env(:men, :dingtalk_robot_test_mode, :http_error)

    message = %FinalMessage{session_key: "dingtalk:u1", content: "hello", metadata: %{}}

    assert {:error, {:http_status, 500, %{"error" => "server error"}}} =
             DingtalkRobotAdapter.send("dingtalk:u1", message)
  end

  test "缺少 webhook_url 时返回错误" do
    Application.put_env(:men, DingtalkRobotAdapter, transport: MockTransport, webhook_url: "")
    message = %FinalMessage{session_key: "dingtalk:u1", content: "hello", metadata: %{}}
    assert {:error, :missing_webhook_url} = DingtalkRobotAdapter.send("dingtalk:u1", message)
  end
end
