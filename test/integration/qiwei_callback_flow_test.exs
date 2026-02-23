defmodule Men.Integration.QiweiCallbackFlowTest do
  use MenWeb.ConnCase, async: false

  alias Men.Gateway.DispatchServer

  @corp_id "ww-integration"
  @token "qiwei-integration-token"

  defmodule MockZcpgClient do
    def start_turn(prompt, context) do
      notify({:zcpg_called, prompt, context})

      case Jason.decode(prompt) do
        {:ok, %{"content" => content}} when is_binary(content) ->
          cond do
            String.contains?(content, "error_no_fallback") ->
              {:error,
               %{
                 type: :failed,
                 code: "runtime_error",
                 message: "upstream failed",
                 details: %{status: 500},
                 fallback: false
               }}

            true ->
              {:ok, %{text: "zcpg-final", meta: %{source: :zcpg_mock}}}
          end

        _ ->
          {:ok, %{text: "zcpg-final", meta: %{source: :zcpg_mock}}}
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :qiwei_integration_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockLegacyBridge do
    @behaviour Men.RuntimeBridge.Bridge

    @impl true
    def start_turn(prompt, context) do
      notify({:legacy_called, prompt, context})
      {:ok, %{text: "legacy-final", meta: %{source: :legacy_mock}}}
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :qiwei_integration_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule MockEgress do
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(_target, _message), do: :ok
  end

  setup do
    Application.put_env(:men, :qiwei_integration_test_pid, self())

    original_qiwei = Application.get_env(:men, :qiwei, [])
    original_controller = Application.get_env(:men, MenWeb.Webhooks.QiweiController, [])
    original_cutover = Application.get_env(:men, :zcpg_cutover, [])

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

    Application.put_env(:men, :zcpg_cutover,
      enabled: true,
      tenant_whitelist: [@corp_id],
      env_override: false,
      timeout_ms: 2_000,
      breaker: [failure_threshold: 5, window_seconds: 30, cooldown_seconds: 60]
    )

    server_name = {:global, {__MODULE__, self(), make_ref()}}

    start_supervised!(
      {DispatchServer,
       name: server_name,
       legacy_bridge_adapter: MockLegacyBridge,
       zcpg_client: MockZcpgClient,
       egress_adapter: MockEgress,
       session_coordinator_enabled: false}
    )

    Application.put_env(:men, MenWeb.Webhooks.QiweiController, dispatch_server: server_name)

    on_exit(fn ->
      Application.delete_env(:men, :qiwei_integration_test_pid)
      Application.put_env(:men, :qiwei, original_qiwei)
      Application.put_env(:men, MenWeb.Webhooks.QiweiController, original_controller)
      Application.put_env(:men, :zcpg_cutover, original_cutover)
    end)

    {:ok, server: server_name}
  end

  test "callback->dispatch->zcpg->reply：@ 且白名单命中返回 XML", %{conn: conn} do
    xml =
      text_xml(
        msg_id: "msg-flow-1",
        from_user: "user-flow-1",
        content: "@men-bot hello",
        at_user: "bot_user_1"
      )

    conn = post_callback(conn, xml)
    body = response(conn, 200)

    assert body =~ "<xml>"
    assert body =~ "zcpg-final"
    assert_receive {:zcpg_called, _, _}
    refute_receive {:legacy_called, _, _}
  end

  test "下游失败降级：fallback=false 时回 success，不返回 500", %{conn: conn} do
    xml =
      text_xml(
        msg_id: "msg-flow-2",
        from_user: "user-flow-2",
        content: "@men-bot error_no_fallback",
        at_user: "bot_user_1"
      )

    conn = post_callback(conn, xml)

    assert response(conn, 200) == "success"
    assert_receive {:zcpg_called, _, _}
  end

  test "非@文本：200 success，不回 XML", %{conn: conn} do
    xml =
      text_xml(
        msg_id: "msg-flow-3",
        from_user: "user-flow-3",
        content: "普通消息",
        at_user: nil
      )

    conn = post_callback(conn, xml)

    assert response(conn, 200) == "success"
    refute_receive {:zcpg_called, _, _}
    refute_receive {:legacy_called, _, _}
  end

  test "灰度切流与回滚：关闭开关后分钟级恢复 legacy 路径", %{conn: conn} do
    xml1 =
      text_xml(
        msg_id: "msg-flow-4",
        from_user: "user-flow-4",
        content: "@men-bot before rollback",
        at_user: "bot_user_1"
      )

    conn1 = post_callback(conn, xml1)
    assert response(conn1, 200) =~ "zcpg-final"
    assert_receive {:zcpg_called, _, _}

    Application.put_env(:men, :zcpg_cutover,
      enabled: false,
      tenant_whitelist: [],
      env_override: false,
      timeout_ms: 2_000,
      breaker: [failure_threshold: 5, window_seconds: 30, cooldown_seconds: 60]
    )

    xml2 =
      text_xml(
        msg_id: "msg-flow-5",
        from_user: "user-flow-4",
        content: "@men-bot after rollback",
        at_user: "bot_user_1"
      )

    conn2 = post_callback(build_conn(), xml2)
    assert response(conn2, 200) =~ "<xml>"
    refute_receive {:zcpg_called, _, _}
    assert_receive {:legacy_called, _, _}
  end

  defp text_xml(opts) do
    msg_id = Keyword.fetch!(opts, :msg_id)
    from_user = Keyword.fetch!(opts, :from_user)
    content = Keyword.fetch!(opts, :content)
    at_user = Keyword.get(opts, :at_user)

    at_xml = if is_binary(at_user), do: "<AtUser><![CDATA[#{at_user}]]></AtUser>", else: ""

    """
    <xml>
      <ToUserName><![CDATA[#{@corp_id}]]></ToUserName>
      <FromUserName><![CDATA[#{from_user}]]></FromUserName>
      <CreateTime>1700000100</CreateTime>
      <MsgType><![CDATA[text]]></MsgType>
      <Content><![CDATA[#{content}]]></Content>
      <MsgId>#{msg_id}</MsgId>
      <AgentID>100001</AgentID>
      #{at_xml}
    </xml>
    """
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
    :crypto.hash(:sha256, "qiwei-integration-test-key")
    |> binary_part(0, 32)
    |> Base.encode64(padding: false)
  end
end
