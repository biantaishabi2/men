defmodule Men.Channels.Egress.FeishuAdapterTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Egress.FeishuAdapter
  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}

  defmodule MockTransport do
    @behaviour Men.Channels.Egress.FeishuAdapter.HttpTransport

    @impl true
    def post(url, headers, body, _opts) do
      if pid = Application.get_env(:men, :feishu_egress_test_pid) do
        send(pid, {:transport_post, url, headers, body})
      end

      case Application.get_env(:men, :feishu_egress_transport_mode, :ok) do
        :ok -> {:ok, %{status: 200, body: ~s({"code":0})}}
        {:status, code} -> {:ok, %{status: code, body: ~s({"code":999})}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  setup do
    Application.put_env(:men, :feishu_egress_test_pid, self())
    Application.put_env(:men, :feishu_egress_transport_mode, :ok)

    Application.put_env(:men, FeishuAdapter,
      base_url: "https://open.feishu.cn",
      transport: MockTransport,
      bots: %{
        "cli_test_bot" => %{access_token: "bot-token"}
      }
    )

    on_exit(fn ->
      Application.delete_env(:men, :feishu_egress_test_pid)
      Application.delete_env(:men, :feishu_egress_transport_mode)
      Application.delete_env(:men, FeishuAdapter)
    end)

    :ok
  end

  test "final_reply 按协议发送 text payload" do
    message = %FinalMessage{
      session_key: "feishu:ou_test_user",
      content: "final hello",
      metadata: %{
        "feishu_app_id" => "cli_test_bot",
        "reply_token" => "om_message_1"
      }
    }

    assert :ok = FeishuAdapter.send(message.session_key, message)

    assert_receive {:transport_post, url, headers, body}
    assert url == "https://open.feishu.cn/open-apis/im/v1/messages/om_message_1/reply"
    assert {"authorization", "Bearer bot-token"} in headers
    assert Jason.decode!(body) == %{"msg_type" => "text", "content" => %{"text" => "final hello"}}
  end

  test "error_reply 发送错误消息并包含错误码" do
    message = %ErrorMessage{
      session_key: "feishu:ou_test_user",
      reason: "bridge failed",
      code: "BRIDGE_FAIL",
      metadata: %{
        "feishu_app_id" => "cli_test_bot",
        "reply_token" => "om_message_2"
      }
    }

    assert :ok = FeishuAdapter.send(message.session_key, message)

    assert_receive {:transport_post, _url, _headers, body}
    decoded = Jason.decode!(body)
    assert decoded["msg_type"] == "text"
    assert decoded["content"]["text"] == "[ERROR][BRIDGE_FAIL] bridge failed"
  end

  test "发送失败时返回错误" do
    Application.put_env(:men, :feishu_egress_transport_mode, {:error, :timeout})

    message = %FinalMessage{
      session_key: "feishu:ou_test_user",
      content: "final hello",
      metadata: %{
        "feishu_app_id" => "cli_test_bot",
        "reply_token" => "om_message_3"
      }
    }

    assert {:error, :timeout} = FeishuAdapter.send(message.session_key, message)
  end
end
