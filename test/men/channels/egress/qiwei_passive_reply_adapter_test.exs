defmodule Men.Channels.Egress.QiweiPassiveReplyAdapterTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Egress.QiweiPassiveReplyAdapter

  setup do
    original = Application.get_env(:men, :qiwei, [])

    Application.put_env(:men, :qiwei,
      bot_user_id: "bot_user_1",
      bot_name: "men-bot",
      reply_require_mention: true,
      reply_max_chars: 20
    )

    on_exit(fn -> Application.put_env(:men, :qiwei, original) end)
    :ok
  end

  test "@ 命中优先级：结构化 at 命中 bot_user_id 时回复 XML" do
    event = %{
      payload: %{
        msg_type: "text",
        from_user: "u1",
        to_user: "corp1",
        content: "hello",
        at_list: ["bot_user_1"]
      }
    }

    dispatch = {:ok, %{payload: %{text: "final-reply"}}}

    assert {:xml, xml} = QiweiPassiveReplyAdapter.build(event, dispatch)
    assert xml =~ "<ToUserName><![CDATA[u1]]></ToUserName>"
    assert xml =~ "<FromUserName><![CDATA[corp1]]></FromUserName>"
    assert xml =~ "<MsgType><![CDATA[text]]></MsgType>"
    assert xml =~ "<Content><![CDATA[final-reply]]></Content>"
  end

  test "文本兜底：未命中结构化 at 但命中 @QIWEI_BOT_NAME 仍回复" do
    event = %{
      payload: %{
        msg_type: "text",
        from_user: "u2",
        to_user: "corp2",
        content: "@men-bot 你好",
        at_list: []
      }
    }

    dispatch = {:ok, %{payload: %{text: "hello-back"}}}

    assert {:xml, xml} = QiweiPassiveReplyAdapter.build(event, dispatch)
    assert xml =~ "hello-back"
  end

  test "非 @ 文本不回 XML，降级 success" do
    event = %{
      payload: %{
        msg_type: "text",
        from_user: "u3",
        to_user: "corp3",
        content: "普通消息",
        at_list: []
      }
    }

    dispatch = {:ok, %{payload: %{text: "should-not-send"}}}

    assert {:success} = QiweiPassiveReplyAdapter.build(event, dispatch)
  end

  test "非 text 不回 XML" do
    event = %{payload: %{msg_type: "image", from_user: "u4", to_user: "corp4"}}
    dispatch = {:ok, %{payload: %{text: "image-ack"}}}

    assert {:success} = QiweiPassiveReplyAdapter.build(event, dispatch)
  end

  test "内容长度裁剪：超长回复按 max_chars 截断" do
    event = %{
      payload: %{
        msg_type: "text",
        from_user: "u5",
        to_user: "corp5",
        content: "@men-bot long",
        at_list: []
      }
    }

    dispatch = {:ok, %{payload: %{text: "1234567890123456789012345"}}}

    assert {:xml, xml} = QiweiPassiveReplyAdapter.build(event, dispatch)
    assert xml =~ "12345678901234567890"
    refute xml =~ "123456789012345678901"
  end
end
