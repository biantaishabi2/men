defmodule Men.Channels.Egress.AdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}

  defmodule MockEgressAdapter do
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, %FinalMessage{}), do: :ok

    def send(_target, %ErrorMessage{}), do: :ok

    def send(_target, _message), do: {:error, :unsupported_message}
  end

  test "FinalMessage 结构体可构造" do
    msg = %FinalMessage{session_key: "feishu:u1", content: "done", metadata: %{trace: "t1"}}

    assert msg.session_key == "feishu:u1"
    assert msg.content == "done"
    assert msg.metadata == %{trace: "t1"}
  end

  test "ErrorMessage 结构体可构造" do
    msg = %ErrorMessage{
      session_key: "feishu:u1",
      reason: "bad request",
      code: "bad_request",
      metadata: %{detail: "missing field"}
    }

    assert msg.session_key == "feishu:u1"
    assert msg.reason == "bad request"
    assert msg.code == "bad_request"
    assert msg.metadata == %{detail: "missing field"}
  end

  test "mock adapter 满足 behaviour 并支持 Final/Error 消息" do
    final_msg = %FinalMessage{session_key: "feishu:u1", content: "ok"}
    error_msg = %ErrorMessage{session_key: "feishu:u1", reason: "failed"}

    assert :ok = MockEgressAdapter.send(:user_target, final_msg)
    assert :ok = MockEgressAdapter.send(:user_target, error_msg)
    assert {:error, :unsupported_message} = MockEgressAdapter.send(:user_target, %{content: "raw"})
  end
end
