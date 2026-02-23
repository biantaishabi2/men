defmodule Men.Channels.Ingress.QiweiAdapterTest do
  use ExUnit.Case, async: false

  alias Men.Channels.Ingress.QiweiAdapter

  setup do
    original = Application.get_env(:men, :qiwei, [])

    Application.put_env(:men, :qiwei,
      bot_user_id: "bot_user_1",
      bot_name: "men-bot",
      reply_require_mention: true
    )

    on_exit(fn ->
      Application.put_env(:men, :qiwei, original)
    end)

    :ok
  end

  test "text 消息标准化：tenant/msg_id/at_list 字段完整" do
    xml = """
    <xml>
      <ToUserName><![CDATA[corp-1]]></ToUserName>
      <FromUserName><![CDATA[user-1]]></FromUserName>
      <CreateTime>1700000000</CreateTime>
      <MsgType><![CDATA[text]]></MsgType>
      <Content><![CDATA[@men-bot hello]]></Content>
      <MsgId>msg-1</MsgId>
      <AgentID>100001</AgentID>
      <AtUser><![CDATA[bot_user_1]]></AtUser>
    </xml>
    """

    assert {:ok, event} = QiweiAdapter.normalize(%{xml: xml})

    assert event.request_id == "msg-1"
    assert event.channel == "qiwei"
    assert event.user_id == "user-1"
    assert event.payload.msg_type == "text"
    assert event.payload.tenant_id == "corp-1"
    assert event.payload.content == "@men-bot hello"
    assert event.payload.at_list == ["bot_user_1"]
    assert event.metadata.mention_required == true
    assert event.metadata.mentioned == true
  end

  test "事件消息标准化：用 from_user+create_time+event+event_key 生成 request_id" do
    xml = """
    <xml>
      <ToUserName><![CDATA[corp-1]]></ToUserName>
      <FromUserName><![CDATA[user-2]]></FromUserName>
      <CreateTime>1700000001</CreateTime>
      <MsgType><![CDATA[event]]></MsgType>
      <Event><![CDATA[enter_agent]]></Event>
      <EventKey><![CDATA[key-1]]></EventKey>
      <AgentID>100001</AgentID>
    </xml>
    """

    assert {:ok, event} = QiweiAdapter.normalize(%{xml: xml})

    assert event.payload.msg_type == "event"
    assert event.payload.event == "enter_agent"
    assert event.payload.event_key == "key-1"
    assert event.request_id == "event:user-2:1700000001:enter_agent:key-1"
  end

  test "非 text/事件类型也可入链路（image 示例）" do
    xml = """
    <xml>
      <ToUserName><![CDATA[corp-2]]></ToUserName>
      <FromUserName><![CDATA[user-3]]></FromUserName>
      <CreateTime>1700000002</CreateTime>
      <MsgType><![CDATA[image]]></MsgType>
      <PicUrl><![CDATA[https://img.example.com/a.png]]></PicUrl>
      <MsgId>msg-image-1</MsgId>
      <AgentID>100002</AgentID>
    </xml>
    """

    assert {:ok, event} = QiweiAdapter.normalize(%{xml: xml})
    assert event.payload.msg_type == "image"
    assert event.request_id == "msg-image-1"
    assert event.metadata.mentioned == false
  end

  test "mention 兼容解析：结构化 at 不命中时走文本 @bot_name 兜底" do
    xml = """
    <xml>
      <ToUserName><![CDATA[corp-3]]></ToUserName>
      <FromUserName><![CDATA[user-4]]></FromUserName>
      <CreateTime>1700000003</CreateTime>
      <MsgType><![CDATA[text]]></MsgType>
      <Content><![CDATA[@men-bot fallback mention]]></Content>
      <MsgId>msg-3</MsgId>
      <AgentID>100003</AgentID>
    </xml>
    """

    assert {:ok, event} = QiweiAdapter.normalize(%{xml: xml})
    assert event.metadata.mentioned == true
  end
end
