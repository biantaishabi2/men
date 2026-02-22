defmodule Men.Channels.Egress.RouterAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.DingtalkRobotAdapter
  alias Men.Channels.Egress.Messages.{EventMessage, FinalMessage}
  alias Men.Channels.Egress.RouterAdapter

  defmodule MockTransport do
    @behaviour Men.Channels.Egress.DingtalkRobotAdapter.HttpTransport

    @impl true
    def post(url, headers, body, _opts) do
      if pid = Application.get_env(:men, :router_adapter_test_pid) do
        send(pid, {:transport_post, url, headers, body})
      end

      {:ok, %{status: 200, body: %{"errcode" => 0, "errmsg" => "ok"}}}
    end
  end

  setup do
    Application.put_env(:men, :router_adapter_test_pid, self())
    Application.put_env(:men, DingtalkRobotAdapter, transport: MockTransport, webhook_url: "")

    on_exit(fn ->
      Application.delete_env(:men, :router_adapter_test_pid)
      Application.delete_env(:men, DingtalkRobotAdapter)
    end)

    :ok
  end

  test "未知渠道返回错误" do
    message = %FinalMessage{session_key: "unknown:u1", content: "hi", metadata: %{}}
    assert {:error, :unsupported_channel} = RouterAdapter.send("unknown:u1", message)
  end

  test "map target 透传到 dingtalk adapter（webhook_url 生效）" do
    message = %EventMessage{event_type: :final, payload: %{text: "ok"}, metadata: %{session_key: "dingtalk:u1"}}

    target = %{
      session_key: "dingtalk:u1",
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=router-target-token"
    }

    assert :ok = RouterAdapter.send(target, message)
    assert_receive {:transport_post, url, _headers, _body}
    assert String.contains?(url, "access_token=router-target-token")
  end
end
