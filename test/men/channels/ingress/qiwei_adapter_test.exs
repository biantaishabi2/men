defmodule Men.Channels.Ingress.QiweiAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Ingress.QiweiAdapter

  test "text 消息标准化" do
    xml = """
    <xml>
      <ToUserName><![CDATA[wwcorp]]></ToUserName>
      <FromUserName><![CDATA[user_a]]></FromUserName>
      <CreateTime>1700000001</CreateTime>
      <MsgType><![CDATA[text]]></MsgType>
      <Content><![CDATA[@助手 你好]]></Content>
      <MsgId>123456</MsgId>
      <AgentID>1000002</AgentID>
      <MentionedUserNameList>
        <item><![CDATA[bot_user_id]]></item>
      </MentionedUserNameList>
    </xml>
    """

    assert {:ok, event} =
             QiweiAdapter.normalize(xml,
               tenant_resolver: fn corp_id, agent_id -> "#{corp_id}:#{agent_id}" end
             )

    assert event.request_id == "123456"
    assert event.channel == "qiwei"
    assert event.user_id == "user_a"
    assert event.payload.msg_type == "text"
    assert event.payload.content == "@助手 你好"
    assert event.payload.corp_id == "wwcorp"
    assert event.payload.agent_id == 1_000_002
    assert event.payload.tenant_id == "wwcorp:1000002"
    assert event.payload.at_user_ids == ["bot_user_id"]
  end

  test "事件消息标准化" do
    xml = """
    <xml>
      <ToUserName><![CDATA[wwcorp]]></ToUserName>
      <FromUserName><![CDATA[user_b]]></FromUserName>
      <CreateTime>1700000002</CreateTime>
      <MsgType><![CDATA[event]]></MsgType>
      <Event><![CDATA[enter_agent]]></Event>
      <EventKey><![CDATA[key1]]></EventKey>
      <AgentID>1000003</AgentID>
    </xml>
    """

    assert {:ok, event} = QiweiAdapter.normalize(xml)
    assert event.payload.msg_type == "event"
    assert event.payload.event == "enter_agent"
    assert event.payload.event_key == "key1"
    assert String.starts_with?(event.request_id, "qiwei-")
  end

  test "非 text 消息标准化" do
    xml = """
    <xml>
      <ToUserName><![CDATA[wwcorp]]></ToUserName>
      <FromUserName><![CDATA[user_c]]></FromUserName>
      <CreateTime>1700000003</CreateTime>
      <MsgType><![CDATA[image]]></MsgType>
      <PicUrl><![CDATA[https://example.com/a.png]]></PicUrl>
      <MsgId>987654</MsgId>
      <AgentID>1000004</AgentID>
    </xml>
    """

    assert {:ok, event} = QiweiAdapter.normalize(xml)
    assert event.payload.msg_type == "image"
    assert event.payload.content == nil
    assert event.request_id == "987654"
  end

  test "缺少关键字段返回错误" do
    xml = """
    <xml>
      <FromUserName><![CDATA[user_d]]></FromUserName>
      <MsgType><![CDATA[text]]></MsgType>
    </xml>
    """

    assert {:error, error} = QiweiAdapter.normalize(xml)
    assert error.code == "INVALID_XML"
  end

  test "幂等指纹提取" do
    event = %{
      payload: %{
        corp_id: "wwcorp",
        agent_id: 1_000_001,
        msg_id: "mid-1",
        from_user: "u1",
        create_time: 1_700_000_000,
        event: "enter_agent",
        event_key: "k1"
      }
    }

    fp = QiweiAdapter.idempotency_fingerprint(event)

    assert fp.corp_id == "wwcorp"
    assert fp.agent_id == 1_000_001
    assert fp.msg_id == "mid-1"
    assert fp.from_user == "u1"
  end
end
