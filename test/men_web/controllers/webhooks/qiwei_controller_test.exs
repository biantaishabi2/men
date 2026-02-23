defmodule MenWeb.Webhooks.QiweiControllerTest do
  use MenWeb.ConnCase, async: false

  defmodule MockDispatchServer do
    def dispatch(_server, event) do
      if pid = Application.get_env(:men, :qiwei_controller_test_pid) do
        send(pid, {:dispatch_called, event})
      end

      content = get_in(event, [:payload, :content]) || ""

      cond do
        String.contains?(content, "timeout") ->
          {:error, %{code: "TIMEOUT", reason: "downstream timeout"}}

        true ->
          {:ok,
           %{
             session_key: "qiwei:test",
             run_id: event.run_id,
             request_id: event.request_id,
             payload: %{text: "reply:" <> content},
             metadata: %{}
           }}
      end
    end
  end

  setup do
    Application.put_env(:men, :qiwei_controller_test_pid, self())

    Application.put_env(:men, MenWeb.Webhooks.QiweiController,
      callback_enabled: true,
      token: "qiwei-token",
      encoding_aes_key: "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
      receive_id: "wwcorp_test",
      bot_name: "MenBot",
      bot_user_id: "bot_user_id",
      reply_require_mention: true,
      dispatch_server: MockDispatchServer,
      idempotency_ttl_seconds: 120
    )

    on_exit(fn ->
      Application.delete_env(:men, :qiwei_controller_test_pid)
      Application.delete_env(:men, MenWeb.Webhooks.QiweiController)
    end)

    :ok
  end

  test "GET 握手成功返回解密明文", %{conn: conn} do
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = "nonce-get-ok"
    echostr = encrypt_payload("echo-ok")
    signature = sign("qiwei-token", timestamp, nonce, echostr)

    conn =
      get(conn, "/webhooks/qiwei", %{
        "timestamp" => timestamp,
        "nonce" => nonce,
        "echostr" => echostr,
        "msg_signature" => signature
      })

    assert response(conn, 200) == "echo-ok"
  end

  test "GET 握手验签失败返回 401", %{conn: conn} do
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = "nonce-get-bad"
    echostr = encrypt_payload("echo-bad")

    conn =
      get(conn, "/webhooks/qiwei", %{
        "timestamp" => timestamp,
        "nonce" => nonce,
        "echostr" => echostr,
        "msg_signature" => "broken"
      })

    assert json_response(conn, 401) == %{"status" => "error", "code" => "UNAUTHORIZED"}
  end

  test "POST text + @ 命中返回 reply XML 且调用 dispatch", %{conn: conn} do
    message_xml =
      inbound_message_xml(
        msg_type: "text",
        from_user: "user_1",
        content: "@MenBot 你好",
        msg_id: "msg-1",
        create_time: 1_700_000_001
      )

    conn = post_signed_callback(conn, message_xml, "nonce-post-1")

    assert response(conn, 200) =~ "<xml>"
    assert response(conn, 200) =~ "<![CDATA[reply:@MenBot 你好]]>"

    assert_receive {:dispatch_called, event}
    assert event.payload.msg_type == "text"
    assert event.metadata.mentioned == true
  end

  test "POST text 非 @ 返回 success，仍可调用 dispatch", %{conn: conn} do
    message_xml =
      inbound_message_xml(
        msg_type: "text",
        from_user: "user_2",
        content: "普通消息",
        msg_id: "msg-2",
        create_time: 1_700_000_002
      )

    conn = post_signed_callback(conn, message_xml, "nonce-post-2")

    assert response(conn, 200) == "success"
    assert_receive {:dispatch_called, event}
    assert event.metadata.mentioned == false
  end

  test "POST 非 text/事件返回 success", %{conn: conn} do
    message_xml =
      inbound_message_xml(
        msg_type: "event",
        from_user: "user_3",
        event: "enter_agent",
        msg_id: nil,
        create_time: 1_700_000_003
      )

    conn = post_signed_callback(conn, message_xml, "nonce-post-3")

    assert response(conn, 200) == "success"
    assert_receive {:dispatch_called, event}
    assert event.payload.msg_type == "event"
  end

  test "POST 验签失败返回 401 且不调用 dispatch", %{conn: conn} do
    message_xml = inbound_message_xml(msg_type: "text", from_user: "user_4", msg_id: "msg-4")
    encrypt = encrypt_payload(message_xml)
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = "nonce-post-bad-sign"

    conn =
      conn
      |> put_req_header("content-type", "text/xml")
      |> post(
        "/webhooks/qiwei?timestamp=#{timestamp}&nonce=#{nonce}&msg_signature=broken",
        callback_outer_xml(encrypt)
      )

    assert json_response(conn, 401) == %{"status" => "error", "code" => "UNAUTHORIZED"}
    refute_receive {:dispatch_called, _}
  end

  test "POST 解密失败返回 401 且不调用 dispatch", %{conn: conn} do
    encrypt = Base.encode64("invalid-cipher")
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = "nonce-post-bad-decrypt"
    signature = sign("qiwei-token", timestamp, nonce, encrypt)

    conn =
      conn
      |> put_req_header("content-type", "text/xml")
      |> post(
        "/webhooks/qiwei?timestamp=#{timestamp}&nonce=#{nonce}&msg_signature=#{signature}",
        callback_outer_xml(encrypt)
      )

    assert json_response(conn, 401) == %{"status" => "error", "code" => "UNAUTHORIZED"}
    refute_receive {:dispatch_called, _}
  end

  test "POST 下游超时/失败降级 success", %{conn: conn} do
    message_xml =
      inbound_message_xml(
        msg_type: "text",
        from_user: "user_5",
        content: "@MenBot timeout",
        msg_id: "msg-5",
        create_time: 1_700_000_005
      )

    conn = post_signed_callback(conn, message_xml, "nonce-post-5")

    assert response(conn, 200) == "success"
    assert_receive {:dispatch_called, _}
  end

  test "POST 幂等重复投递返回首次一致响应且不重复 side effect", %{conn: conn} do
    message_xml =
      inbound_message_xml(
        msg_type: "text",
        from_user: "user_6",
        content: "@MenBot 幂等",
        msg_id: "msg-idempotent",
        create_time: 1_700_000_006
      )

    conn1 = post_signed_callback(conn, message_xml, "nonce-post-idem-1")
    body1 = response(conn1, 200)

    conn2 = post_signed_callback(Phoenix.ConnTest.build_conn(), message_xml, "nonce-post-idem-2")
    body2 = response(conn2, 200)

    assert body1 == body2
    assert_receive {:dispatch_called, _}
    refute_receive {:dispatch_called, _}
  end

  defp post_signed_callback(conn, message_xml, nonce) do
    encrypt = encrypt_payload(message_xml)
    timestamp = Integer.to_string(System.system_time(:second))
    signature = sign("qiwei-token", timestamp, nonce, encrypt)

    conn
    |> put_req_header("content-type", "text/xml")
    |> post(
      "/webhooks/qiwei?timestamp=#{timestamp}&nonce=#{nonce}&msg_signature=#{signature}",
      callback_outer_xml(encrypt)
    )
  end

  defp callback_outer_xml(encrypt) do
    """
    <xml>
      <ToUserName><![CDATA[wwcorp_test]]></ToUserName>
      <Encrypt><![CDATA[#{encrypt}]]></Encrypt>
    </xml>
    """
    |> String.trim()
  end

  defp inbound_message_xml(opts) do
    msg_type = Keyword.get(opts, :msg_type, "text")
    from_user = Keyword.get(opts, :from_user, "user")
    msg_id = Keyword.get(opts, :msg_id, "msg-default")
    content = Keyword.get(opts, :content, "")
    event = Keyword.get(opts, :event)
    create_time = Keyword.get(opts, :create_time, System.system_time(:second))

    msg_id_xml = if is_binary(msg_id), do: "<MsgId>#{msg_id}</MsgId>", else: ""

    event_xml =
      if is_binary(event) do
        "<Event><![CDATA[#{event}]]></Event>"
      else
        ""
      end

    content_xml =
      if is_binary(content) do
        "<Content><![CDATA[#{content}]]></Content>"
      else
        ""
      end

    """
    <xml>
      <ToUserName><![CDATA[wwcorp_test]]></ToUserName>
      <FromUserName><![CDATA[#{from_user}]]></FromUserName>
      <CreateTime>#{create_time}</CreateTime>
      <MsgType><![CDATA[#{msg_type}]]></MsgType>
      #{content_xml}
      #{event_xml}
      #{msg_id_xml}
      <AgentID>1000002</AgentID>
    </xml>
    """
    |> String.trim()
  end

  defp encrypt_payload(plain_text) do
    key = aes_key()
    iv = binary_part(key, 0, 16)
    random = :crypto.strong_rand_bytes(16)
    msg_len = byte_size(plain_text)
    packed = random <> <<msg_len::32-big-unsigned-integer>> <> plain_text <> "wwcorp_test"
    cipher = :crypto.crypto_one_time(:aes_256_cbc, key, iv, pkcs7_pad(packed), true)
    Base.encode64(cipher)
  end

  defp aes_key do
    {:ok, key} = Base.decode64("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG=")
    key
  end

  defp pkcs7_pad(content) do
    block_size = 32
    padding = block_size - rem(byte_size(content), block_size)
    content <> :binary.copy(<<padding>>, padding)
  end

  defp sign(token, timestamp, nonce, encrypted) do
    [token, timestamp, nonce, encrypted]
    |> Enum.sort()
    |> Enum.join()
    |> then(&:crypto.hash(:sha, &1))
    |> Base.encode16(case: :lower)
  end
end
