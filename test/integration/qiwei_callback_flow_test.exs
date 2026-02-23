defmodule Men.Integration.QiweiCallbackFlowTest do
  use MenWeb.ConnCase, async: false

  alias Men.Gateway.DispatchServer

  defmodule MockZcpgClient do
    def start_turn(prompt, context) do
      notify({:zcpg_called, prompt, context})

      case Jason.decode(prompt) do
        {:ok, %{"content" => "@MenBot timeout"}} ->
          {:error,
           %{
             type: :timeout,
             code: "timeout",
             message: "zcpg timeout",
             details: %{source: :qiwei_integration},
             fallback: true
           }}

        {:ok, %{"content" => "@MenBot hard_fail"}} ->
          {:error,
           %{
             type: :failed,
             code: "hard_fail",
             message: "zcpg hard fail",
             details: %{source: :qiwei_integration},
             fallback: false
           }}

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

      case Jason.decode(prompt) do
        {:ok, %{"content" => "@MenBot hard_fail"}} ->
          {:error,
           %{
             type: :failed,
             code: "legacy_fail",
             message: "legacy failed",
             details: %{source: :legacy_mock}
           }}

        _ ->
          {:ok, %{text: "legacy-final", meta: %{source: :legacy_mock}}}
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:men, :qiwei_integration_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule NoopEgress do
    @behaviour Men.Channels.Egress.Adapter
    @impl true
    def send(_target, _message), do: :ok
  end

  setup do
    Application.put_env(:men, :qiwei_integration_test_pid, self())

    original_cutover = Application.get_env(:men, :zcpg_cutover, [])

    Application.put_env(:men, :zcpg_cutover,
      enabled: true,
      tenant_whitelist: ["wwcorp_test"],
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
       egress_adapter: NoopEgress,
       session_coordinator_enabled: false}
    )

    Application.put_env(:men, MenWeb.Webhooks.QiweiController,
      callback_enabled: true,
      token: "qiwei-token",
      encoding_aes_key: "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
      receive_id: "wwcorp_test",
      bot_name: "MenBot",
      bot_user_id: "bot_user_id",
      reply_require_mention: true,
      dispatch_server: server_name,
      idempotency_ttl_seconds: 120
    )

    on_exit(fn ->
      Application.delete_env(:men, :qiwei_integration_test_pid)
      Application.delete_env(:men, MenWeb.Webhooks.QiweiController)
      Application.put_env(:men, :zcpg_cutover, original_cutover)
    end)

    :ok
  end

  test "callback->dispatch->zcpg->reply XML", %{conn: conn} do
    conn =
      post_signed_callback(
        conn,
        inbound_message_xml(msg_id: "flow-1", content: "@MenBot 你好"),
        "nonce-flow-1"
      )

    assert response(conn, 200) =~ "<![CDATA[zcpg-final]]>"
    assert_receive {:zcpg_called, _, _}
    refute_receive {:legacy_called, _, _}
  end

  test "下游失败降级 success", %{conn: conn} do
    conn =
      post_signed_callback(
        conn,
        inbound_message_xml(msg_id: "flow-2", content: "@MenBot hard_fail"),
        "nonce-flow-2"
      )

    assert response(conn, 200) == "success"
    assert_receive {:zcpg_called, _, _}
    refute_receive {:legacy_called, _, _}
  end

  test "灰度切流与回滚即时生效", %{conn: conn} do
    conn_1 =
      post_signed_callback(
        conn,
        inbound_message_xml(msg_id: "flow-3", content: "@MenBot timeout"),
        "nonce-flow-3"
      )

    assert response(conn_1, 200) == "success"
    assert_receive {:zcpg_called, _, _}
    refute_receive {:legacy_called, _, _}

    Application.put_env(:men, :zcpg_cutover,
      enabled: false,
      tenant_whitelist: [],
      env_override: false,
      timeout_ms: 2_000,
      breaker: [failure_threshold: 5, window_seconds: 30, cooldown_seconds: 60]
    )

    conn_2 =
      post_signed_callback(
        Phoenix.ConnTest.build_conn(),
        inbound_message_xml(msg_id: "flow-4", content: "@MenBot rollback"),
        "nonce-flow-4"
      )

    assert response(conn_2, 200) =~ "<![CDATA[legacy-final]]>"
    refute_receive {:zcpg_called, _, _}
    assert_receive {:legacy_called, _, _}
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
    msg_id = Keyword.fetch!(opts, :msg_id)
    content = Keyword.fetch!(opts, :content)

    """
    <xml>
      <ToUserName><![CDATA[wwcorp_test]]></ToUserName>
      <FromUserName><![CDATA[user_flow]]></FromUserName>
      <CreateTime>1700001111</CreateTime>
      <MsgType><![CDATA[text]]></MsgType>
      <Content><![CDATA[#{content}]]></Content>
      <MsgId>#{msg_id}</MsgId>
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
