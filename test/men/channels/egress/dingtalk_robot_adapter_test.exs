defmodule Men.Channels.Egress.DingtalkRobotAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.DingtalkRobotAdapter
  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}

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

  test "发送 delta EventMessage 成功且包含 run/session" do
    message = %EventMessage{
      event_type: :delta,
      payload: %{text: "chunk-a"},
      metadata: %{request_id: "req-delta", run_id: "run-delta", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_post, url, headers, body}
    assert String.contains?(url, "access_token=test-token")
    assert {"content-type", "application/json"} in headers

    decoded = Jason.decode!(body)
    content = decoded["text"]["content"]

    assert decoded["msgtype"] == "text"
    assert String.contains?(content, "[delta]")
    assert String.contains?(content, "run_id=run-delta")
    assert String.contains?(content, "session_key=dingtalk:u1")
    assert String.contains?(content, "chunk-a")
  end

  test "发送 final EventMessage 成功且保留前缀兼容" do
    message = %EventMessage{
      event_type: :final,
      payload: %{text: "done"},
      metadata: %{request_id: "req-final", run_id: "run-final", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_post, _url, _headers, body}

    decoded = Jason.decode!(body)
    content = decoded["text"]["content"]

    assert String.contains?(content, "request_id=req-final")
    assert String.contains?(content, "run_id=run-final")
    assert String.contains?(content, "session_key=dingtalk:u1")
    assert String.contains?(content, "done")
  end

  test "发送 error EventMessage 成功并标准化错误文本" do
    message = %EventMessage{
      event_type: :error,
      payload: %{reason: "timeout", code: "CLI_TIMEOUT"},
      metadata: %{request_id: "req-error", run_id: "run-error", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_post, _url, _headers, body}

    decoded = Jason.decode!(body)
    content = decoded["text"]["content"]

    assert String.contains?(content, "[ERROR][CLI_TIMEOUT]")
    assert String.contains?(content, "timeout")
    assert String.contains?(content, "run_id=run-error")
    assert String.contains?(content, "session_key=dingtalk:u1")
  end

  test "发送 error EventMessage 时 code/reason 为结构化值不会崩溃" do
    message = %EventMessage{
      event_type: :error,
      payload: %{reason: %{kind: "timeout"}, code: {:upstream, :timeout}},
      metadata: %{request_id: "req-error-struct", run_id: "run-error-struct", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_post, _url, _headers, body}

    decoded = Jason.decode!(body)
    content = decoded["text"]["content"]

    assert String.contains?(content, "[ERROR][{:upstream, :timeout}]")
    assert String.contains?(content, "%{kind: \"timeout\"}")
    assert String.contains?(content, "run_id=run-error-struct")
    assert String.contains?(content, "session_key=dingtalk:u1")
  end

  test "兼容发送 FinalMessage 成功" do
    message = %FinalMessage{
      session_key: "dingtalk:u1",
      content: "done",
      metadata: %{request_id: "req-legacy-final", run_id: "run-legacy-final", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_post, _url, _headers, body}

    decoded = Jason.decode!(body)
    assert String.contains?(decoded["text"]["content"], "run_id=run-legacy-final")
  end

  test "兼容发送 ErrorMessage 成功" do
    message = %ErrorMessage{
      session_key: "dingtalk:u1",
      reason: "bridge failed",
      code: "BRIDGE_FAIL",
      metadata: %{request_id: "req-legacy-error", run_id: "run-legacy-error", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_post, _url, _headers, body}

    decoded = Jason.decode!(body)
    assert String.contains?(decoded["text"]["content"], "[ERROR][BRIDGE_FAIL]")
  end

  test "钉钉业务错误会返回标准错误" do
    Application.put_env(:men, :dingtalk_robot_test_mode, :dingtalk_error)

    message = %EventMessage{event_type: :final, payload: %{text: "hello"}, metadata: %{}}

    assert {:error, {:dingtalk_error, 310_000, "invalid user"}} =
             DingtalkRobotAdapter.send("dingtalk:u1", message)
  end

  test "HTTP 错误会返回标准错误" do
    Application.put_env(:men, :dingtalk_robot_test_mode, :http_error)

    message = %EventMessage{event_type: :final, payload: %{text: "hello"}, metadata: %{}}

    assert {:error, {:http_status, 500, %{"error" => "server error"}}} =
             DingtalkRobotAdapter.send("dingtalk:u1", message)
  end

  test "缺少 webhook_url 时返回错误" do
    Application.put_env(:men, DingtalkRobotAdapter, transport: MockTransport, webhook_url: "")

    message = %EventMessage{event_type: :final, payload: %{text: "hello"}, metadata: %{}}

    assert {:error, :missing_webhook_url} = DingtalkRobotAdapter.send("dingtalk:u1", message)
  end

  test "target map 中 webhook_url 可覆盖全局配置" do
    message = %EventMessage{event_type: :final, payload: %{text: "hello"}, metadata: %{}}

    target = %{
      session_key: "dingtalk:u1",
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=target-token"
    }

    assert :ok = DingtalkRobotAdapter.send(target, message)
    assert_receive {:transport_post, url, _headers, _body}
    assert String.contains?(url, "access_token=target-token")
  end
end
