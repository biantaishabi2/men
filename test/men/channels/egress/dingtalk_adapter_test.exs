defmodule Men.Channels.Egress.DingtalkAdapterTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Egress.DingtalkAdapter
  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}

  defmodule MockTransport do
    @behaviour Men.Channels.Egress.DingtalkAdapter.HttpTransport

    @impl true
    def post(url, headers, body, _opts) do
      if pid = Application.get_env(:men, :dingtalk_egress_test_pid) do
        send(pid, {:transport_post, url, headers, body})
      end

      {:ok, %{status: 200, body: ~s({"errcode":0})}}
    end
  end

  setup do
    Application.put_env(:men, :dingtalk_egress_test_pid, self())

    Application.put_env(:men, DingtalkAdapter,
      webhook_url: "https://oapi.dingtalk.com/robot/send?access_token=token",
      transport: MockTransport
    )

    on_exit(fn ->
      Application.delete_env(:men, :dingtalk_egress_test_pid)
      Application.delete_env(:men, DingtalkAdapter)
    end)

    :ok
  end

  test "send/2 支持 final 回写" do
    message = %FinalMessage{session_key: "dingtalk:u1", content: "done", metadata: %{}}

    assert :ok = DingtalkAdapter.send(%{}, message)
    assert_receive {:transport_post, url, _headers, body}
    assert url =~ "oapi.dingtalk.com/robot/send"
    assert Jason.decode!(body) == %{"msgtype" => "text", "text" => %{"content" => "done"}}
  end

  test "send/2 支持错误摘要回写" do
    message = %ErrorMessage{session_key: "dingtalk:u1", reason: "bridge fail", code: "bridge_error"}

    assert :ok = DingtalkAdapter.send(%{}, message)
    assert_receive {:transport_post, _url, _headers, body}
    assert Jason.decode!(body)["text"]["content"] == "[ERROR][bridge_error] bridge fail"
  end

  test "缺失 webhook_url 返回错误" do
    Application.put_env(:men, DingtalkAdapter, transport: MockTransport)
    message = %FinalMessage{session_key: "dingtalk:u1", content: "done", metadata: %{}}

    assert {:error, :missing_webhook_url} = DingtalkAdapter.send(%{}, message)
  end
end
