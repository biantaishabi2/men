defmodule Men.Channels.Egress.QiweiPassiveReplyAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.QiweiPassiveReplyAdapter

  test "at_list 命中 bot_user_id 优先回复" do
    event = %{
      payload: %{
        msg_type: "text",
        from_user: "user_1",
        corp_id: "wwcorp",
        content: "你好",
        at_user_ids: ["bot_user", "other"]
      }
    }

    assert {:xml, xml} =
             QiweiPassiveReplyAdapter.build(
               event,
               {:ok, %{payload: %{text: "reply-ok"}}},
               require_mention: true,
               bot_user_id: "bot_user"
             )

    assert xml =~ "<MsgType><![CDATA[text]]></MsgType>"
    assert xml =~ "<![CDATA[reply-ok]]>"
  end

  test "文本 @bot_name 兜底命中" do
    event = %{
      payload: %{
        msg_type: "text",
        from_user: "user_2",
        corp_id: "wwcorp",
        content: "@MenBot 帮我查下",
        at_user_ids: []
      }
    }

    assert QiweiPassiveReplyAdapter.mentioned?(event.payload, bot_name: "MenBot")
  end

  test "未命中 @ 规则返回 success" do
    event = %{
      payload: %{
        msg_type: "text",
        from_user: "user_3",
        corp_id: "wwcorp",
        content: "普通消息",
        at_user_ids: []
      }
    }

    assert :success =
             QiweiPassiveReplyAdapter.build(
               event,
               {:ok, %{payload: %{text: "reply-ok"}}},
               require_mention: true,
               bot_user_id: "bot_user",
               bot_name: "MenBot"
             )
  end

  test "非 text 不回 XML" do
    event = %{
      payload: %{
        msg_type: "image",
        from_user: "user_4",
        corp_id: "wwcorp",
        content: nil
      }
    }

    assert :success =
             QiweiPassiveReplyAdapter.build(event, {:ok, %{payload: %{text: "reply-ok"}}},
               require_mention: false
             )
  end

  test "回复内容长度裁剪" do
    long_text = String.duplicate("a", 2_000)

    event = %{
      payload: %{
        msg_type: "text",
        from_user: "user_5",
        corp_id: "wwcorp",
        content: "@MenBot hi",
        at_user_ids: []
      }
    }

    assert {:xml, xml} =
             QiweiPassiveReplyAdapter.build(
               event,
               {:ok, %{payload: %{text: long_text}}},
               require_mention: true,
               bot_name: "MenBot"
             )

    assert String.length(xml) < 1_400
  end
end
