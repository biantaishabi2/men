defmodule Men.Channels.Ingress.DingtalkStreamAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Ingress.DingtalkStreamAdapter

  test "标准化成功（直接 content）" do
    params = %{
      "request_id" => "req-1",
      "run_id" => "run-1",
      "sender_staff_id" => "user-1",
      "conversation_id" => "cid-1",
      "content" => "hello"
    }

    assert {:ok, event} = DingtalkStreamAdapter.normalize(params)
    assert event.request_id == "req-1"
    assert event.run_id == "run-1"
    assert event.channel == "dingtalk"
    assert event.user_id == "user-1"
    assert event.group_id == "cid-1"
    assert event.session_key == "dingtalk:user-1"
    assert event.payload.content == "hello"
  end

  test "标准化成功（text.content）" do
    params = %{
      "senderStaffId" => "user-2",
      "chatId" => "cid-2",
      "msgId" => "msg-2",
      "text" => %{"content" => "hello from text"}
    }

    assert {:ok, event} = DingtalkStreamAdapter.normalize(params)
    assert event.request_id == "msg-2"
    assert event.run_id == "run-stream-msg-2"
    assert event.session_key == "dingtalk:user-2"
    assert event.payload.content == "hello from text"
  end

  test "conversation_id 包含特殊字符也可标准化" do
    params = %{
      "senderStaffId" => "user-3",
      "conversationId" => "cid3xGYPRfVbgk+8Aqz5W3FktoC80ojZluBPa0JMxfifuk=",
      "msgId" => "msg-3",
      "text" => %{"content" => "hello special"}
    }

    assert {:ok, event} = DingtalkStreamAdapter.normalize(params)
    assert event.session_key == "dingtalk:user-3"
    assert event.group_id == "cid3xGYPRfVbgk+8Aqz5W3FktoC80ojZluBPa0JMxfifuk="
  end

  test "缺少 sender 返回错误" do
    params = %{"content" => "hello"}

    assert {:error, error} = DingtalkStreamAdapter.normalize(params)
    assert error.code == "MISSING_FIELD"
    assert error.details.field == :sender_id
  end

  test "缺少 content 返回错误" do
    params = %{"sender_staff_id" => "user-1"}

    assert {:error, error} = DingtalkStreamAdapter.normalize(params)
    assert error.code == "MISSING_FIELD"
    assert error.details.field == :content
  end
end
