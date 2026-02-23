defmodule MenWeb.Webhooks.QiweiControllerTest do
  use MenWeb.ConnCase, async: false

  alias Men.Channels.Ingress.QiweiIdempotency

  @corp_id "ww-test-corp"
  @token "qiwei-token"

  setup do
    original_qiwei = Application.get_env(:men, :qiwei, [])
    original_controller = Application.get_env(:men, MenWeb.Webhooks.QiweiController, [])

    Application.put_env(:men, :qiwei,
      callback_enabled: true,
      token: @token,
      encoding_aes_key: encoding_aes_key(),
      corp_id: @corp_id,
      bot_user_id: "bot_user_1",
      bot_name: "men-bot",
      reply_require_mention: true,
      idempotency_ttl_seconds: 120,
      callback_timeout_ms: 2_000
    )

    Application.put_env(:men, :qiwei_controller_test_pid, self())

    on_exit(fn ->
      Application.put_env(:men, :qiwei, original_qiwei)
      Application.put_env(:men, MenWeb.Webhooks.QiweiController, original_controller)
      Application.delete_env(:men, :qiwei_controller_test_pid)
    end)

    :ok
  end

  test "GET 握手成功：返回解密后明文", %{conn: conn} do
    echostr = encrypt_payload("verify-ok")

    query = signed_query(echostr)

    conn = get(conn, "/webhooks/qiwei", query)

    assert response(conn, 200) == "verify-ok"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/plain"
  end

  test "GET 握手失败：非法签名返回 401", %{conn: conn} do
    echostr = encrypt_payload("verify-fail")

    conn =
      get(conn, "/webhooks/qiwei", %{
        "msg_signature" => "broken",
        "timestamp" => "1700000000",
        "nonce" => "nonce-1",
        "echostr" => echostr
      })

    assert json_response(conn, 401) == %{"status" => "error", "code" => "UNAUTHORIZED"}
  end

  test "POST text + @ 命中：返回 reply XML 且 dispatch 被调用", %{conn: conn} do
    Application.put_env(:men, MenWeb.Webhooks.QiweiController,
      dispatch_fun: fn inbound_event ->
        notify({:dispatch_called, inbound_event})
        {:ok, %{payload: %{text: "reply-from-dispatch"}}}
      end
    )

    plain_xml =
      """
      <xml>
        <ToUserName><![CDATA[#{@corp_id}]]></ToUserName>
        <FromUserName><![CDATA[user-1]]></FromUserName>
        <CreateTime>1700000001</CreateTime>
        <MsgType><![CDATA[text]]></MsgType>
        <Content><![CDATA[@men-bot 你好]]></Content>
        <MsgId>msg-1</MsgId>
        <AgentID>100001</AgentID>
        <AtUser><![CDATA[bot_user_1]]></AtUser>
      </xml>
      """

    conn = post_callback(conn, plain_xml)

    body = response(conn, 200)
    assert body =~ "<xml>"
    assert body =~ "reply-from-dispatch"

    assert_receive {:dispatch_called, inbound_event}
    assert inbound_event.payload.msg_type == "text"
    assert inbound_event.metadata.mentioned == true
  end

  test "POST text + 非@：200 success（仍可 dispatch，不回 XML）", %{conn: conn} do
    Application.put_env(:men, MenWeb.Webhooks.QiweiController,
      dispatch_fun: fn inbound_event ->
        notify({:dispatch_called, inbound_event})
        {:ok, %{payload: %{text: "should-not-reply"}}}
      end
    )

    plain_xml =
      """
      <xml>
        <ToUserName><![CDATA[#{@corp_id}]]></ToUserName>
        <FromUserName><![CDATA[user-2]]></FromUserName>
        <CreateTime>1700000002</CreateTime>
        <MsgType><![CDATA[text]]></MsgType>
        <Content><![CDATA[普通消息]]></Content>
        <MsgId>msg-2</MsgId>
        <AgentID>100001</AgentID>
      </xml>
      """

    conn = post_callback(conn, plain_xml)

    assert response(conn, 200) == "success"
    assert_receive {:dispatch_called, _}
  end

  test "POST 非 text/事件：200 success，入链路不回 XML", %{conn: conn} do
    Application.put_env(:men, MenWeb.Webhooks.QiweiController,
      dispatch_fun: fn inbound_event ->
        notify({:dispatch_called, inbound_event})
        {:ok, %{payload: %{text: "ignored"}}}
      end
    )

    plain_xml =
      """
      <xml>
        <ToUserName><![CDATA[#{@corp_id}]]></ToUserName>
        <FromUserName><![CDATA[user-3]]></FromUserName>
        <CreateTime>1700000003</CreateTime>
        <MsgType><![CDATA[image]]></MsgType>
        <MsgId>msg-3</MsgId>
        <AgentID>100001</AgentID>
      </xml>
      """

    conn = post_callback(conn, plain_xml)

    assert response(conn, 200) == "success"
    assert_receive {:dispatch_called, inbound_event}
    assert inbound_event.payload.msg_type == "image"
  end

  test "POST 验签失败：401 且不 dispatch", %{conn: conn} do
    plain_xml =
      """
      <xml>
        <ToUserName><![CDATA[#{@corp_id}]]></ToUserName>
        <FromUserName><![CDATA[user-4]]></FromUserName>
        <CreateTime>1700000004</CreateTime>
        <MsgType><![CDATA[text]]></MsgType>
        <Content><![CDATA[@men-bot hi]]></Content>
        <MsgId>msg-4</MsgId>
        <AgentID>100001</AgentID>
      </xml>
      """

    encrypt = encrypt_payload(plain_xml)
    body = wrap_encrypt(encrypt)

    conn =
      conn
      |> put_req_header("content-type", "application/xml")
      |> post(
        "/webhooks/qiwei?msg_signature=broken&timestamp=1700000000&nonce=nonce-1",
        body
      )

    assert json_response(conn, 401) == %{"status" => "error", "code" => "UNAUTHORIZED"}
    refute_receive {:dispatch_called, _}
  end

  test "POST 解密失败：401 且不 dispatch", %{conn: conn} do
    bad_encrypt = Base.encode64("not-valid-cipher")

    query = signed_query(bad_encrypt)

    conn =
      conn
      |> put_req_header("content-type", "application/xml")
      |> post("/webhooks/qiwei?" <> URI.encode_query(query), wrap_encrypt(bad_encrypt))

    assert json_response(conn, 401) == %{"status" => "error", "code" => "UNAUTHORIZED"}
    refute_receive {:dispatch_called, _}
  end

  test "下游超时/5xx：统一 200 success", %{conn: conn} do
    Application.put_env(:men, MenWeb.Webhooks.QiweiController,
      dispatch_fun: fn inbound_event ->
        notify({:dispatch_called, inbound_event})

        {:error,
         %{code: "timeout", reason: "zcpg timeout", metadata: %{type: :timeout, upstream: 504}}}
      end
    )

    plain_xml =
      """
      <xml>
        <ToUserName><![CDATA[#{@corp_id}]]></ToUserName>
        <FromUserName><![CDATA[user-5]]></FromUserName>
        <CreateTime>1700000005</CreateTime>
        <MsgType><![CDATA[text]]></MsgType>
        <Content><![CDATA[@men-bot timeout]]></Content>
        <MsgId>msg-5</MsgId>
        <AgentID>100001</AgentID>
        <AtUser><![CDATA[bot_user_1]]></AtUser>
      </xml>
      """

    conn = post_callback(conn, plain_xml)

    assert response(conn, 200) == "success"
    assert_receive {:dispatch_called, _}
  end

  test "幂等重复投递：120s 内不重复 side effect，响应与首次一致", %{conn: conn} do
    Application.put_env(:men, MenWeb.Webhooks.QiweiController,
      idempotency: QiweiIdempotency,
      dispatch_fun: fn inbound_event ->
        notify({:dispatch_called, inbound_event})
        {:ok, %{payload: %{text: "idem-reply"}}}
      end
    )

    plain_xml =
      """
      <xml>
        <ToUserName><![CDATA[#{@corp_id}]]></ToUserName>
        <FromUserName><![CDATA[user-6]]></FromUserName>
        <CreateTime>1700000006</CreateTime>
        <MsgType><![CDATA[text]]></MsgType>
        <Content><![CDATA[@men-bot idem]]></Content>
        <MsgId>msg-idem-1</MsgId>
        <AgentID>100001</AgentID>
        <AtUser><![CDATA[bot_user_1]]></AtUser>
      </xml>
      """

    conn1 = post_callback(conn, plain_xml)
    conn2 = post_callback(build_conn(), plain_xml)

    body1 = response(conn1, 200)
    body2 = response(conn2, 200)

    assert body1 == body2
    assert_receive {:dispatch_called, _}
    refute_receive {:dispatch_called, _}
  end

  defp post_callback(conn, plain_xml) do
    encrypt = encrypt_payload(plain_xml)
    query = signed_query(encrypt)

    conn
    |> put_req_header("content-type", "application/xml")
    |> post("/webhooks/qiwei?" <> URI.encode_query(query), wrap_encrypt(encrypt))
  end

  defp wrap_encrypt(encrypt) do
    "<xml><ToUserName><![CDATA[#{@corp_id}]]></ToUserName><Encrypt><![CDATA[#{encrypt}]]></Encrypt></xml>"
  end

  defp signed_query(encrypt) do
    timestamp = "1700000000"
    nonce = "nonce-1"

    %{
      "msg_signature" => signature(@token, timestamp, nonce, encrypt),
      "timestamp" => timestamp,
      "nonce" => nonce,
      "echostr" => encrypt
    }
  end

  defp signature(token, timestamp, nonce, encrypt) do
    [token, timestamp, nonce, encrypt]
    |> Enum.sort()
    |> Enum.join("")
    |> then(&:crypto.hash(:sha, &1))
    |> Base.encode16(case: :lower)
  end

  defp encrypt_payload(plain) do
    aes_key = decode_aes_key()
    random = :binary.copy(<<1>>, 16)
    payload = random <> <<byte_size(plain)::unsigned-integer-size(32)>> <> plain <> @corp_id
    padded = pkcs7_pad(payload)

    :crypto.crypto_one_time(:aes_256_cbc, aes_key, binary_part(aes_key, 0, 16), padded, true)
    |> Base.encode64()
  end

  defp pkcs7_pad(data) do
    block_size = 32
    pad = block_size - rem(byte_size(data), block_size)
    data <> :binary.copy(<<pad>>, pad)
  end

  defp decode_aes_key do
    Base.decode64!(encoding_aes_key() <> "=")
  end

  defp encoding_aes_key do
    :crypto.hash(:sha256, "qiwei-test-key")
    |> binary_part(0, 32)
    |> Base.encode64(padding: false)
  end

  defp notify(message) do
    if pid = Application.get_env(:men, :qiwei_controller_test_pid) do
      send(pid, message)
    end
  end
end
