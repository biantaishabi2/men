defmodule MenWeb.Webhooks.QiweiController do
  @moduledoc """
  企微 callback ingress 控制器：处理握手、回调验签解密与被动回复。
  """

  use MenWeb, :controller

  require Logger

  alias Men.Channels.Egress.QiweiPassiveReplyAdapter
  alias Men.Channels.Ingress.QiweiAdapter
  alias Men.Channels.Ingress.QiweiIdempotency
  alias Men.Gateway.DispatchServer

  @unauthorized %{status: "error", code: "UNAUTHORIZED"}

  def verify(conn, params) do
    if callback_enabled?() do
      with {:ok, query} <- fetch_signed_query(params),
           {:ok, _} <-
             verify_signature(query.msg_signature, query.timestamp, query.nonce, query.echostr),
           {:ok, plain_echo} <- decrypt_payload(query.echostr) do
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, plain_echo)
      else
        {:error, :unauthorized} -> unauthorized(conn)
        {:error, _} -> success(conn)
      end
    else
      success(conn)
    end
  end

  def callback(conn, params) do
    if callback_enabled?() do
      {conn, raw_body} = resolve_raw_body(conn)

      with {:ok, query} <- fetch_signed_query(params),
           {:ok, encrypt} <- extract_encrypt(raw_body),
           {:ok, _} <-
             verify_signature(query.msg_signature, query.timestamp, query.nonce, encrypt),
           {:ok, plain_xml} <- decrypt_payload(encrypt),
           {:ok, inbound_event} <- normalize_event(plain_xml, query),
           response <- handle_idempotent(inbound_event) do
        respond_callback(conn, response)
      else
        {:error, :unauthorized} -> unauthorized(conn)
        {:error, _reason} -> success(conn)
      end
    else
      success(conn)
    end
  end

  defp normalize_event(plain_xml, query) do
    adapter = Keyword.get(config(), :ingress_adapter, QiweiAdapter)

    adapter.normalize(%{
      xml: plain_xml,
      query: %{timestamp: query.timestamp, nonce: query.nonce, msg_signature: query.msg_signature}
    })
  end

  defp handle_idempotent(inbound_event) do
    idempotency = Keyword.get(config(), :idempotency, QiweiIdempotency)

    {_, response} =
      idempotency.fetch_or_store(
        inbound_event,
        fn ->
          dispatch_result = dispatch_with_timeout(inbound_event)

          reply_adapter = Keyword.get(config(), :reply_adapter, QiweiPassiveReplyAdapter)

          reply_adapter.build(inbound_event, dispatch_result,
            require_mention: qiwei_config() |> Keyword.get(:reply_require_mention, true),
            bot_user_id: qiwei_config() |> Keyword.get(:bot_user_id),
            bot_name: qiwei_config() |> Keyword.get(:bot_name),
            max_chars: qiwei_config() |> Keyword.get(:reply_max_chars, 600)
          )
        end,
        ttl_seconds: qiwei_config() |> Keyword.get(:idempotency_ttl_seconds, 120)
      )

    response
  rescue
    error ->
      Logger.warning("qiwei.callback.idempotency_failed", reason: inspect(error))
      {:success}
  end

  defp dispatch_with_timeout(inbound_event) do
    timeout_ms = qiwei_config() |> Keyword.get(:callback_timeout_ms, 4_000)

    task =
      Task.async(fn ->
        dispatch_event(inbound_event)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Logger.warning("qiwei.callback.dispatch_timeout",
          request_id: Map.get(inbound_event, :request_id),
          timeout_ms: timeout_ms
        )

        {:error,
         %{
           code: "DISPATCH_TIMEOUT",
           reason: "dispatch timeout",
           metadata: %{timeout_ms: timeout_ms}
         }}
    end
  end

  defp dispatch_event(inbound_event) do
    case Keyword.get(config(), :dispatch_fun) do
      fun when is_function(fun, 1) ->
        fun.(inbound_event)

      _ ->
        dispatch_server = Keyword.get(config(), :dispatch_server, DispatchServer)
        DispatchServer.dispatch(dispatch_server, inbound_event)
    end
  rescue
    error ->
      Logger.warning("qiwei.callback.dispatch_failed",
        request_id: Map.get(inbound_event, :request_id),
        reason: inspect(error)
      )

      {:error,
       %{
         code: "DISPATCH_FAILED",
         reason: "dispatch failed",
         metadata: %{error: inspect(error)}
       }}
  end

  defp respond_callback(conn, {:xml, body}) when is_binary(body) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, body)
  end

  defp respond_callback(conn, _), do: success(conn)

  defp success(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "success")
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(@unauthorized)
  end

  defp fetch_signed_query(params) when is_map(params) do
    with {:ok, msg_signature} <- fetch_required_binary(params, "msg_signature"),
         {:ok, timestamp} <- fetch_required_binary(params, "timestamp"),
         {:ok, nonce} <- fetch_required_binary(params, "nonce") do
      {:ok,
       %{
         msg_signature: msg_signature,
         timestamp: timestamp,
         nonce: nonce,
         echostr: Map.get(params, "echostr")
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp fetch_signed_query(_), do: {:error, :unauthorized}

  defp extract_encrypt(xml) when is_binary(xml) do
    case extract_xml_value(xml, "Encrypt") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :unauthorized}
    end
  end

  defp verify_signature(signature, timestamp, nonce, encrypt)
       when is_binary(signature) and is_binary(timestamp) and is_binary(nonce) and
              is_binary(encrypt) do
    token = qiwei_config() |> Keyword.get(:token)

    with true <- is_binary(token) and token != "",
         expected <- signature_sha1([token, timestamp, nonce, encrypt]),
         true <- Plug.Crypto.secure_compare(expected, signature) do
      {:ok, :verified}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp verify_signature(_, _, _, _), do: {:error, :unauthorized}

  defp decrypt_payload(encrypt) when is_binary(encrypt) do
    with {:ok, aes_key} <- decode_aes_key(),
         {:ok, cipher_text} <- decode_base64(encrypt),
         {:ok, plain} <- safe_decrypt(aes_key, cipher_text),
         {:ok, unpadded} <- pkcs7_unpad(plain),
         {:ok, content, receive_id} <- extract_content(unpadded),
         :ok <- verify_receive_id(receive_id) do
      {:ok, content}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp decode_aes_key do
    case qiwei_config() |> Keyword.get(:encoding_aes_key) do
      value when is_binary(value) and byte_size(value) == 43 ->
        with {:ok, decoded} <- decode_base64(value <> "="),
             true <- byte_size(decoded) == 32 do
          {:ok, decoded}
        else
          _ -> {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  # 统一兜底 crypto 异常，避免畸形密文触发 500。
  defp safe_decrypt(aes_key, cipher_text) do
    iv = binary_part(aes_key, 0, 16)
    plain = :crypto.crypto_one_time(:aes_256_cbc, aes_key, iv, cipher_text, false)
    {:ok, plain}
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :unauthorized}
    end
  end

  defp pkcs7_unpad(<<>>), do: {:error, :unauthorized}

  defp pkcs7_unpad(data) when is_binary(data) do
    pad = :binary.last(data)
    size = byte_size(data)

    cond do
      pad <= 0 or pad > 32 or pad > size ->
        {:error, :unauthorized}

      true ->
        <<content::binary-size(size - pad), padding::binary-size(pad)>> = data

        if padding == :binary.copy(<<pad>>, pad) do
          {:ok, content}
        else
          {:error, :unauthorized}
        end
    end
  end

  defp extract_content(
         <<_random::binary-size(16), msg_len::unsigned-integer-size(32), rest::binary>>
       )
       when byte_size(rest) >= msg_len do
    <<content::binary-size(msg_len), receive_id::binary>> = rest
    {:ok, content, receive_id}
  end

  defp extract_content(_), do: {:error, :unauthorized}

  defp verify_receive_id(receive_id) do
    configured = qiwei_config() |> Keyword.get(:corp_id)

    case configured do
      nil -> :ok
      "" -> :ok
      corp_id when is_binary(corp_id) and corp_id == receive_id -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp signature_sha1(items) do
    items
    |> Enum.sort()
    |> Enum.join("")
    |> then(&:crypto.hash(:sha, &1))
    |> Base.encode16(case: :lower)
  end

  defp extract_xml_value(xml, tag) do
    cdata_pattern = ~r/<#{tag}><!\[CDATA\[(.*?)\]\]><\/#{tag}>/s
    plain_pattern = ~r/<#{tag}>([^<]*)<\/#{tag}>/s

    case Regex.run(cdata_pattern, xml, capture: :all_but_first) do
      [value] ->
        String.trim(value)

      _ ->
        case Regex.run(plain_pattern, xml, capture: :all_but_first) do
          [value] -> String.trim(value)
          _ -> nil
        end
    end
  end

  defp fetch_required_binary(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing}
    end
  end

  defp callback_enabled? do
    qiwei_config() |> Keyword.get(:callback_enabled, false)
  end

  # XML body 在未命中 Plug.Parsers 时不会自动进入 assigns，这里兜底主动读取一次。
  defp resolve_raw_body(conn) do
    case conn.assigns[:raw_body] do
      raw when is_binary(raw) ->
        {conn, raw}

      _ ->
        case do_read_body(conn, []) do
          {:ok, raw, conn_after_read} -> {conn_after_read, raw}
          {:error, _reason, conn_after_error} -> {conn_after_error, ""}
        end
    end
  end

  defp do_read_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        do_read_body(conn, [chunk | acc])

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp qiwei_config do
    Application.get_env(:men, :qiwei, [])
  end

  defp config do
    Application.get_env(:men, __MODULE__, [])
  end
end
