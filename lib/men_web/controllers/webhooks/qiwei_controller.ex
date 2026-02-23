defmodule MenWeb.Webhooks.QiweiController do
  @moduledoc """
  企微 callback ingress 控制器：仅负责协议校验、解密与统一响应语义。
  """

  use MenWeb, :controller

  require Logger

  alias Men.Channels.Egress.QiweiPassiveReplyAdapter
  alias Men.Channels.Ingress.QiweiAdapter
  alias Men.Channels.Ingress.QiweiIdempotency
  alias Men.Gateway.DispatchServer

  @success_text "success"
  @unauthorized_code "UNAUTHORIZED"

  def verify(conn, params) do
    config = config()

    with :ok <- ensure_callback_enabled(config),
         {:ok, timestamp} <- required_param(params, "timestamp"),
         {:ok, nonce} <- required_param(params, "nonce"),
         {:ok, signature} <- required_param(params, "msg_signature"),
         {:ok, echostr} <- required_param(params, "echostr"),
         :ok <- verify_signature(config.token, timestamp, nonce, echostr, signature),
         {:ok, plain} <- decrypt(echostr, config.encoding_aes_key, config.receive_id) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, plain)
    else
      {:error, :disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", code: "DISABLED"})

      {:error, {:unauthorized, _reason}} ->
        unauthorized(conn)

      {:error, reason} ->
        Logger.warning("qiwei.verify.failed", reason: inspect(reason))

        conn
        |> put_status(:ok)
        |> text(@success_text)
    end
  end

  def callback(conn, params) do
    config = config()

    with :ok <- ensure_callback_enabled(config),
         {:ok, raw_body} <- fetch_raw_body(conn),
         {:ok, encrypt} <- fetch_encrypt(raw_body),
         {:ok, timestamp} <- required_param(params, "timestamp"),
         {:ok, nonce} <- required_param(params, "nonce"),
         {:ok, signature} <- required_param(params, "msg_signature"),
         :ok <- verify_signature(config.token, timestamp, nonce, encrypt, signature),
         {:ok, decrypted_xml} <- decrypt(encrypt, config.encoding_aes_key, config.receive_id),
         {:ok, inbound_event} <-
           config.ingress_adapter.normalize(decrypted_xml,
             tenant_resolver: config.tenant_resolver
           ) do
      reply_opts = [
        require_mention: config.reply_require_mention,
        bot_user_id: config.bot_user_id,
        bot_name: config.bot_name
      ]

      inbound_event = enrich_mention_flags(inbound_event, config.reply_adapter, reply_opts)

      response_payload =
        config.idempotency.with_idempotency(
          inbound_event,
          fn -> run_dispatch(inbound_event, config, reply_opts) end,
          backend: config.idempotency_backend,
          ttl_seconds: config.idempotency_ttl_seconds
        )

      respond(conn, response_payload)
    else
      {:error, :disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", code: "DISABLED"})

      {:error, {:unauthorized, _reason}} ->
        unauthorized(conn)

      {:error, reason} ->
        Logger.warning("qiwei.callback.failed", reason: inspect(reason))

        conn
        |> put_status(:ok)
        |> text(@success_text)
    end
  end

  defp run_dispatch(inbound_event, config, reply_opts) do
    dispatch_result =
      try do
        case dispatch(config.dispatch_server, inbound_event) do
          {:ok, result} -> {:ok, result}
          {:error, error} -> {:error, error}
          _ -> {:error, %{code: "DISPATCH_UNKNOWN", reason: "unknown dispatch result"}}
        end
      catch
        :exit, reason ->
          Logger.warning("qiwei.dispatch.exit", reason: inspect(reason))
          {:error, %{code: "DISPATCH_UNAVAILABLE", reason: "dispatch server unavailable"}}
      end

    case config.reply_adapter.build(inbound_event, dispatch_result, reply_opts) do
      {:xml, body} when is_binary(body) and body != "" -> %{type: :xml, body: body}
      _ -> %{type: :success}
    end
  end

  defp dispatch(server_or_module, inbound_event) when is_atom(server_or_module) do
    if function_exported?(server_or_module, :dispatch, 2) do
      server_or_module.dispatch(server_or_module, inbound_event)
    else
      DispatchServer.dispatch(server_or_module, inbound_event)
    end
  end

  defp dispatch(server_name, inbound_event) do
    DispatchServer.dispatch(server_name, inbound_event)
  end

  defp enrich_mention_flags(inbound_event, reply_adapter, reply_opts) do
    payload = Map.get(inbound_event, :payload, %{})
    metadata = Map.get(inbound_event, :metadata, %{})
    msg_type = Map.get(payload, :msg_type)

    mentioned =
      if msg_type == "text" do
        reply_adapter.mentioned?(payload, reply_opts)
      else
        false
      end

    mention_required = Keyword.get(reply_opts, :require_mention, true)

    inbound_event
    |> Map.put(:payload, Map.put(payload, :mentioned, mentioned))
    |> Map.put(
      :metadata,
      Map.merge(metadata, %{
        mentioned: mentioned,
        mention_required: mention_required,
        disable_legacy_fallback: true
      })
    )
  end

  defp respond(conn, %{type: :xml, body: body}) when is_binary(body) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, body)
  end

  defp respond(conn, _payload) do
    conn
    |> put_status(:ok)
    |> text(@success_text)
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{status: "error", code: @unauthorized_code})
  end

  defp fetch_raw_body(conn) do
    case conn.assigns[:raw_body] || conn.private[:raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _ -> read_raw_body(conn, "")
    end
  end

  defp read_raw_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, chunk, _conn} ->
        body = acc <> chunk
        if body == "", do: {:error, :missing_raw_body}, else: {:ok, body}

      {:more, chunk, conn} ->
        read_raw_body(conn, acc <> chunk)

      {:error, _reason} ->
        {:error, :missing_raw_body}
    end
  end

  defp fetch_encrypt(raw_body) do
    case tag_value(raw_body, "Encrypt") do
      encrypt when is_binary(encrypt) and encrypt != "" -> {:ok, encrypt}
      _ -> {:error, :missing_encrypt}
    end
  end

  defp tag_value(xml, tag) when is_binary(xml) do
    pattern = ~r/<#{tag}>\s*(?:<!\[CDATA\[(?<cdata>.*?)\]\]>|(?<plain>.*?))\s*<\/#{tag}>/us

    case Regex.named_captures(pattern, xml) do
      %{"cdata" => cdata, "plain" => plain} ->
        (first_present(cdata, plain) || "")
        |> to_string()
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  defp first_present(value_a, value_b) do
    if is_binary(value_a) and value_a != "", do: value_a, else: value_b
  end

  defp required_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:unauthorized, {:missing_param, key}}}
    end
  end

  defp verify_signature(token, timestamp, nonce, encrypted, signature)
       when is_binary(token) and token != "" do
    expected =
      [token, timestamp, nonce, encrypted]
      |> Enum.sort()
      |> Enum.join()
      |> then(&:crypto.hash(:sha, &1))
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, {:unauthorized, :invalid_signature}}
    end
  end

  defp verify_signature(_, _, _, _, _), do: {:error, {:unauthorized, :missing_token}}

  # 企微密文结构：16B随机串 + 4B网络序长度 + 明文 + receive_id。
  defp decrypt(encrypted, encoding_aes_key, receive_id) do
    with {:ok, aes_key} <- decode_aes_key(encoding_aes_key),
         {:ok, cipher_text} <- decode_base64(encrypted),
         iv <- binary_part(aes_key, 0, 16),
         {:ok, plain_padded} <- decrypt_cipher_text(aes_key, iv, cipher_text),
         {:ok, plain} <- pkcs7_unpad(plain_padded),
         {:ok, xml, recv_id} <- unpack_plain_text(plain),
         :ok <- verify_receive_id(recv_id, receive_id) do
      {:ok, xml}
    else
      {:error, reason} -> {:error, {:unauthorized, reason}}
      _ -> {:error, {:unauthorized, :decrypt_failed}}
    end
  end

  # 兼容畸形密文导致的底层异常，统一按鉴权失败处理，避免 500。
  defp decrypt_cipher_text(aes_key, iv, cipher_text) do
    try do
      {:ok, :crypto.crypto_one_time(:aes_256_cbc, aes_key, iv, cipher_text, false)}
    rescue
      _ -> {:error, :decrypt_failed}
    catch
      _, _ -> {:error, :decrypt_failed}
    end
  end

  defp decode_aes_key(value) when is_binary(value) and value != "" do
    with {:ok, decoded} <- decode_base64(value <> "="),
         :ok <- validate_aes_key(decoded) do
      {:ok, decoded}
    end
  end

  defp decode_aes_key(_), do: {:error, :missing_encoding_aes_key}

  defp validate_aes_key(decoded) when is_binary(decoded) and byte_size(decoded) == 32, do: :ok
  defp validate_aes_key(_), do: {:error, :invalid_encoding_aes_key}

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp pkcs7_unpad(<<>>), do: {:error, :invalid_padding}

  defp pkcs7_unpad(content) do
    padding = :binary.last(content)

    cond do
      padding < 1 or padding > 32 ->
        {:error, :invalid_padding}

      byte_size(content) < padding ->
        {:error, :invalid_padding}

      true ->
        <<data::binary-size(byte_size(content) - padding), pad::binary-size(padding)>> = content

        if pad == :binary.copy(<<padding>>, padding) do
          {:ok, data}
        else
          {:error, :invalid_padding}
        end
    end
  end

  defp unpack_plain_text(
         <<_random::binary-size(16), msg_len::32-big-unsigned-integer, rest::binary>>
       ) do
    if byte_size(rest) >= msg_len do
      <<xml::binary-size(msg_len), recv_id::binary>> = rest
      {:ok, xml, recv_id}
    else
      {:error, :invalid_plain_text}
    end
  end

  defp unpack_plain_text(_), do: {:error, :invalid_plain_text}

  defp verify_receive_id(_actual, nil), do: :ok
  defp verify_receive_id(_actual, ""), do: :ok

  defp verify_receive_id(actual, expected) when is_binary(actual) and is_binary(expected) do
    if Plug.Crypto.secure_compare(actual, expected), do: :ok, else: {:error, :receive_id_mismatch}
  end

  defp verify_receive_id(_, _), do: {:error, :receive_id_mismatch}

  defp ensure_callback_enabled(%{callback_enabled: true}), do: :ok
  defp ensure_callback_enabled(_), do: {:error, :disabled}

  defp config do
    app_config = Application.get_env(:men, __MODULE__, [])

    %{
      callback_enabled: Keyword.get(app_config, :callback_enabled, false),
      token: Keyword.get(app_config, :token, System.get_env("QIWEI_CALLBACK_TOKEN")),
      encoding_aes_key:
        Keyword.get(
          app_config,
          :encoding_aes_key,
          System.get_env("QIWEI_CALLBACK_ENCODING_AES_KEY")
        ),
      receive_id: Keyword.get(app_config, :receive_id, System.get_env("QIWEI_RECEIVE_ID")),
      bot_name: Keyword.get(app_config, :bot_name, System.get_env("QIWEI_BOT_NAME")),
      bot_user_id: Keyword.get(app_config, :bot_user_id, System.get_env("QIWEI_BOT_USER_ID")),
      reply_require_mention: Keyword.get(app_config, :reply_require_mention, true),
      dispatch_server: Keyword.get(app_config, :dispatch_server, DispatchServer),
      ingress_adapter: Keyword.get(app_config, :ingress_adapter, QiweiAdapter),
      reply_adapter: Keyword.get(app_config, :reply_adapter, QiweiPassiveReplyAdapter),
      idempotency: Keyword.get(app_config, :idempotency, QiweiIdempotency),
      idempotency_backend:
        Keyword.get(app_config, :idempotency_backend, QiweiIdempotency.Backend.ETS),
      idempotency_ttl_seconds: Keyword.get(app_config, :idempotency_ttl_seconds, 120),
      tenant_resolver: Keyword.get(app_config, :tenant_resolver, &default_tenant_resolver/2)
    }
  end

  defp default_tenant_resolver(corp_id, _agent_id), do: corp_id
end
