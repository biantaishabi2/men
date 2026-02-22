defmodule Men.Channels.Egress.DingtalkRobotAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.DingtalkRobotAdapter
  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}

  defmodule MockTransport do
    @behaviour Men.Channels.Egress.DingtalkRobotAdapter.HttpTransport

    @impl true
    def request(method, url, headers, body, _opts) do
      if pid = Application.get_env(:men, :dingtalk_robot_test_pid) do
        send(pid, {:transport_request, method, url, headers, body})
      end

      mode = Application.get_env(:men, :dingtalk_robot_test_mode, :ok)

      case {mode, method} do
        {:ok, :get} ->
          {:ok, %{status: 200, body: %{"errcode" => 0, "access_token" => "token-123"}}}

        {:ok, :post} ->
          {:ok, %{status: 200, body: %{"errcode" => 0, "errmsg" => "ok"}}}

        {:dingtalk_error, :post} ->
          {:ok, %{status: 200, body: %{"errcode" => 310_000, "errmsg" => "invalid user"}}}

        {:http_error, :post} ->
          {:ok, %{status: 500, body: %{"error" => "server error"}}}

        {:token_error, :get} ->
          {:ok, %{status: 200, body: %{"errcode" => 40013, "errmsg" => "invalid app"}}}

        {:network_error, _} ->
          {:error, :timeout}

        _ ->
          {:ok, %{status: 200, body: %{}}}
      end
    end
  end

  setup do
    DingtalkRobotAdapter.__reset_stream_state_for_test__()
    Application.put_env(:men, :dingtalk_robot_test_pid, self())
    Application.put_env(:men, :dingtalk_robot_test_mode, :ok)

    Application.put_env(:men, DingtalkRobotAdapter,
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=test-token",
      sign_enabled: false,
      stream_output_mode: :delta_only,
      transport: MockTransport
    )

    on_exit(fn ->
      DingtalkRobotAdapter.__reset_stream_state_for_test__()
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
    assert_receive {:transport_request, :post, url, headers, body}
    assert String.contains?(url, "access_token=test-token")
    assert {"content-type", "application/json"} in headers

    decoded = Jason.decode!(body)
    assert decoded["msgtype"] == "text"
    assert decoded["text"]["content"] == "done"
  end

  test "发送 ErrorMessage 成功并带 code" do
    message = %ErrorMessage{
      session_key: "dingtalk:u1",
      reason: "bridge failed",
      code: "BRIDGE_FAIL",
      metadata: %{request_id: "req-2", run_id: "run-2"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_request, :post, _url, _headers, body}
    decoded = Jason.decode!(body)
    assert decoded["text"]["content"] == "[BRIDGE_FAIL] bridge failed"
  end

  test "发送 EventMessage(delta) 成功" do
    message = %EventMessage{
      event_type: :delta,
      payload: %{text: "partial"},
      metadata: %{request_id: "req-delta-1", run_id: "run-delta-1", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_request, :post, _url, _headers, body}
    decoded = Jason.decode!(body)
    assert decoded["text"]["content"] == "partial"
  end

  test "delta_only 模式下 delta 后会抑制同 run_id 的 final，避免双回复" do
    delta = %EventMessage{
      event_type: :delta,
      payload: %{text: "part-1"},
      metadata: %{request_id: "req-s1", run_id: "run-s1", session_key: "dingtalk:u1"}
    }

    final = %FinalMessage{
      session_key: "dingtalk:u1",
      content: "full-text",
      metadata: %{request_id: "req-s1", run_id: "run-s1"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", delta)
    assert_receive {:transport_request, :post, _url, _headers, body1}
    assert Jason.decode!(body1)["text"]["content"] == "part-1"

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", final)
    refute_receive {:transport_request, :post, _url, _headers, _body}, 100
  end

  test "final_only 模式下会忽略 delta，仅发送 final" do
    Application.put_env(:men, DingtalkRobotAdapter,
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=test-token",
      sign_enabled: false,
      stream_output_mode: :final_only,
      transport: MockTransport
    )

    delta = %EventMessage{
      event_type: :delta,
      payload: %{text: "part-2"},
      metadata: %{request_id: "req-s2", run_id: "run-s2", session_key: "dingtalk:u1"}
    }

    final = %FinalMessage{
      session_key: "dingtalk:u1",
      content: "final-only",
      metadata: %{request_id: "req-s2", run_id: "run-s2"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", delta)
    refute_receive {:transport_request, :post, _url, _headers, _body}, 100

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", final)
    assert_receive {:transport_request, :post, _url, _headers, body}
    assert Jason.decode!(body)["text"]["content"] == "final-only"
  end

  test "delta_plus_final 模式下会同时发送 delta 与 final" do
    Application.put_env(:men, DingtalkRobotAdapter,
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=test-token",
      sign_enabled: false,
      stream_output_mode: :delta_plus_final,
      transport: MockTransport
    )

    delta = %EventMessage{
      event_type: :delta,
      payload: %{text: "part-3"},
      metadata: %{request_id: "req-s3", run_id: "run-s3", session_key: "dingtalk:u1"}
    }

    final = %FinalMessage{
      session_key: "dingtalk:u1",
      content: "final-plus",
      metadata: %{request_id: "req-s3", run_id: "run-s3"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", delta)
    assert_receive {:transport_request, :post, _url, _headers, body1}
    assert Jason.decode!(body1)["text"]["content"] == "part-3"

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", final)
    assert_receive {:transport_request, :post, _url, _headers, body2}
    assert Jason.decode!(body2)["text"]["content"] == "final-plus"
  end

  test "开启 trace 前缀后会携带 request_id/run_id" do
    Application.put_env(:men, DingtalkRobotAdapter,
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=test-token",
      sign_enabled: false,
      include_trace_prefix: true,
      transport: MockTransport
    )

    message = %FinalMessage{
      session_key: "dingtalk:u1",
      content: "with trace",
      metadata: %{request_id: "req-trace", run_id: "run-trace"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_request, :post, _url, _headers, body}
    decoded = Jason.decode!(body)
    assert String.contains?(decoded["text"]["content"], "request_id=req-trace")
    assert String.contains?(decoded["text"]["content"], "run_id=run-trace")
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

  test "app_robot 模式发送成功" do
    Application.put_env(:men, DingtalkRobotAdapter,
      mode: :app_robot,
      robot_code: "ding_robot_1",
      app_key: "app-key",
      app_secret: "app-secret",
      transport: MockTransport
    )

    message = %FinalMessage{
      session_key: "dingtalk:user123:g:cid",
      content: "hello",
      metadata: %{request_id: "req-3", run_id: "run-3"}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:user123:g:cid", message)
    assert_receive {:transport_request, :get, token_url, _headers, nil}
    assert String.contains?(token_url, "appkey=app-key")
    assert String.contains?(token_url, "appsecret=app-secret")

    assert_receive {:transport_request, :post, send_url, headers, body}
    assert send_url == "https://api.dingtalk.com/v1.0/robot/oToMessages/batchSend"
    assert {"x-acs-dingtalk-access-token", "token-123"} in headers

    decoded = Jason.decode!(body)
    assert decoded["robotCode"] == "ding_robot_1"
    assert decoded["userIds"] == ["user123"]
    assert decoded["msgKey"] == "sampleText"
  end

  test "app_robot 模式支持 markdown 消息" do
    Application.put_env(:men, DingtalkRobotAdapter,
      mode: :app_robot,
      robot_code: "ding_robot_1",
      app_key: "app-key",
      app_secret: "app-secret",
      msg_key: "sampleMarkdown",
      markdown_title: "Gong",
      transport: MockTransport
    )

    message = %FinalMessage{
      session_key: "dingtalk:user123",
      content: "# 标题\n- 列表",
      metadata: %{}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:user123", message)
    assert_receive {:transport_request, :post, _send_url, _headers, body}

    decoded = Jason.decode!(body)
    assert decoded["msgKey"] == "sampleMarkdown"

    msg_param = Jason.decode!(decoded["msgParam"])
    assert msg_param["title"] == "Gong"
    assert msg_param["text"] == "# 标题\n- 列表"
  end

  test "webhook 模式支持 markdown 消息" do
    Application.put_env(:men, DingtalkRobotAdapter,
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=test-token",
      msg_key: "sampleMarkdown",
      markdown_title: "Gong",
      sign_enabled: false,
      transport: MockTransport
    )

    message = %FinalMessage{
      session_key: "dingtalk:u1",
      content: "## hello",
      metadata: %{}
    }

    assert :ok = DingtalkRobotAdapter.send("dingtalk:u1", message)
    assert_receive {:transport_request, :post, _url, _headers, body}
    decoded = Jason.decode!(body)
    assert decoded["msgtype"] == "markdown"
    assert decoded["markdown"]["title"] == "Gong"
    assert decoded["markdown"]["text"] == "## hello"
  end

  test "app_robot 模式缺少 user_id 返回错误" do
    Application.put_env(:men, DingtalkRobotAdapter,
      mode: :app_robot,
      robot_code: "ding_robot_1",
      app_key: "app-key",
      app_secret: "app-secret",
      transport: MockTransport
    )

    message = %FinalMessage{session_key: "dingtalk:", content: "hello", metadata: %{}}
    assert {:error, :missing_user_id} = DingtalkRobotAdapter.send(%{}, message)
  end

  test "app_robot 模式 token 获取失败返回标准错误" do
    Application.put_env(:men, :dingtalk_robot_test_mode, :token_error)

    Application.put_env(:men, DingtalkRobotAdapter,
      mode: :app_robot,
      robot_code: "ding_robot_1",
      app_key: "app-key",
      app_secret: "app-secret",
      transport: MockTransport
    )

    message = %FinalMessage{session_key: "dingtalk:user123", content: "hello", metadata: %{}}

    assert {:error, {:dingtalk_error, 40013, "invalid app"}} =
             DingtalkRobotAdapter.send("dingtalk:user123", message)
  end
end
