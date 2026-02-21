defmodule Men.Channels.Ingress.FeishuAdapter do
  @moduledoc """
  飞书入站适配：验签、时间窗、重放校验与事件标准化。
  """

  @behaviour Men.Channels.Ingress.Adapter

  @strict_window_sec 300
  @compat_window_sec 900

  @unauthorized_reasons [
    :missing_signature,
    :missing_timestamp,
    :missing_nonce,
    :invalid_timestamp,
    :timestamp_expired,
    :invalid_signature,
    :replay_detected
  ]

  @type sign_mode :: :strict | :compat

  defmodule ReplayBackend do
    @moduledoc false

    @callback seen_nonce?(binary(), non_neg_integer()) :: boolean()
  end

  defmodule ReplayBackend.ETS do
    @moduledoc false
    @behaviour Men.Channels.Ingress.FeishuAdapter.ReplayBackend

    @table :men_feishu_nonce_replay

    @impl true
    def seen_nonce?(nonce_key, ttl_sec) when is_binary(nonce_key) and ttl_sec > 0 do
      now = System.system_time(:second)
      ensure_table!()
      cleanup_expired(now)

      case :ets.lookup(@table, nonce_key) do
        [{^nonce_key, expires_at}] when expires_at > now ->
          true

        _ ->
          :ets.insert(@table, {nonce_key, now + ttl_sec})
          false
      end
    end

    defp ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          try do
            :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          rescue
            ArgumentError -> :ok
          end

        _tid ->
          :ok
      end
    end

    defp cleanup_expired(now) do
      :ets.select_delete(@table, [{{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}])
      :ok
    end
  end

  @impl true
  def normalize(%{headers: headers, body: body}) when is_map(headers) and is_binary(body) do
    with {:ok, payload} <- decode_body(body),
         {:ok, bot_id} <- resolve_bot_id(payload),
         config <- config_for_bot(bot_id),
         :ok <- validate_signature(headers, body, config),
         {:ok, event} <- to_inbound_event(payload, bot_id, config) do
      {:ok, event}
    end
  end

  def normalize(_), do: {:error, :invalid_raw_message}

  @spec unauthorized_reason?(term()) :: boolean()
  def unauthorized_reason?(reason), do: reason in @unauthorized_reasons

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp resolve_bot_id(payload) do
    case get_in(payload, ["header", "app_id"]) || payload["app_id"] do
      bot_id when is_binary(bot_id) and bot_id != "" -> {:ok, bot_id}
      _ -> {:error, :missing_app_id}
    end
  end

  defp validate_signature(headers, body, config) do
    with {:ok, timestamp} <- fetch_header(headers, "x-lark-request-timestamp", :missing_timestamp),
         {:ok, nonce} <- fetch_header(headers, "x-lark-nonce", :missing_nonce),
         {:ok, signature} <- fetch_header(headers, "x-lark-signature", :missing_signature),
         {:ok, timestamp_int} <- parse_timestamp(timestamp),
         :ok <- verify_timestamp(timestamp_int, config),
         :ok <- verify_signature(timestamp, nonce, body, signature, config),
         :ok <- verify_replay(timestamp, nonce, config) do
      :ok
    end
  end

  defp fetch_header(headers, key, missing_reason) do
    case Map.get(headers, key) || Map.get(headers, String.downcase(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, missing_reason}
    end
  end

  defp parse_timestamp(value) do
    case Integer.parse(value) do
      {ts, ""} -> {:ok, ts}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp verify_timestamp(timestamp, config) do
    window_sec = Map.fetch!(config, :time_window_sec)
    now = System.system_time(:second)

    if abs(now - timestamp) <= window_sec, do: :ok, else: {:error, :timestamp_expired}
  end

  defp verify_signature(timestamp, nonce, body, signature, config) do
    secret = Map.fetch!(config, :signing_secret)
    base = timestamp <> "\n" <> nonce <> "\n" <> body

    expected =
      :crypto.mac(:hmac, :sha256, secret, base)
      |> Base.encode64()

    if Plug.Crypto.secure_compare(expected, signature), do: :ok, else: {:error, :invalid_signature}
  end

  defp verify_replay(_timestamp, _nonce, %{sign_mode: :compat}), do: :ok

  defp verify_replay(timestamp, nonce, config) do
    backend = Map.fetch!(config, :replay_backend)
    key = timestamp <> ":" <> nonce
    ttl_sec = Map.fetch!(config, :time_window_sec)
    if backend.seen_nonce?(key, ttl_sec), do: {:error, :replay_detected}, else: :ok
  end

  defp to_inbound_event(payload, bot_id, config) do
    event_id = get_in(payload, ["header", "event_id"]) || payload["event_id"] || unique_request_id()
    message = get_in(payload, ["event", "message"]) || %{}
    sender = get_in(payload, ["event", "sender"]) || %{}

    with {:ok, user_id} <- extract_user_id(sender),
         {:ok, content} <- extract_content(message),
         {:ok, create_time} <- parse_create_time(payload) do
      chat_type = message["chat_type"]
      chat_id = message["chat_id"]
      thread_id = message["thread_id"] || message["root_id"]

      event = %{
        request_id: event_id,
        run_id: event_id,
        payload: content,
        channel: "feishu",
        user_id: user_id,
        group_id: group_id_from_chat(chat_type, chat_id),
        thread_id: thread_id,
        metadata: %{
          "feishu_app_id" => bot_id,
          "event_type" => get_in(payload, ["header", "event_type"]),
          "chat_id" => chat_id,
          "chat_type" => chat_type,
          "message_id" => message["message_id"],
          "reply_token" => message["message_id"],
          "create_time" => create_time,
          "sign_mode" => Atom.to_string(Map.fetch!(config, :sign_mode))
        }
      }

      {:ok, event}
    end
  end

  defp extract_user_id(sender) do
    user_id =
      get_in(sender, ["sender_id", "open_id"]) ||
        get_in(sender, ["sender_id", "user_id"]) ||
        sender["open_id"]

    case user_id do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_user_id}
    end
  end

  defp extract_content(message) do
    case message["content"] do
      content when is_binary(content) ->
        decode_message_content(content)

      _ ->
        {:error, :missing_content}
    end
  end

  defp decode_message_content(content) do
    case Jason.decode(content) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      {:ok, _} -> {:error, :unsupported_content}
      {:error, _} -> {:error, :invalid_content_json}
    end
  end

  defp parse_create_time(payload) do
    create_time = get_in(payload, ["header", "create_time"])

    case Integer.parse(to_string(create_time || "")) do
      {millis, ""} -> {:ok, millis}
      _ -> {:error, :invalid_create_time}
    end
  end

  defp group_id_from_chat("group", chat_id) when is_binary(chat_id) and chat_id != "", do: chat_id
  defp group_id_from_chat(_, _), do: nil

  defp unique_request_id do
    "feishu-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp config_for_bot(bot_id) do
    app_config = Application.get_env(:men, __MODULE__, [])
    base = base_config(app_config)

    bot_override =
      app_config
      |> Keyword.get(:bots, %{})
      |> Map.get(bot_id, %{})
      |> normalize_keyword_map()

    merged = Map.merge(base, bot_override)
    sign_mode = Map.fetch!(merged, :sign_mode)

    Map.merge(merged, %{time_window_sec: resolve_time_window(sign_mode, merged[:time_window_sec])})
  end

  defp base_config(app_config) do
    sign_mode = normalize_sign_mode(Keyword.get(app_config, :sign_mode, :strict))

    %{
      signing_secret: Keyword.fetch!(app_config, :signing_secret),
      sign_mode: sign_mode,
      replay_backend: Keyword.get(app_config, :replay_backend, ReplayBackend.ETS),
      time_window_sec: resolve_time_window(sign_mode, Keyword.get(app_config, :time_window_sec))
    }
  end

  defp normalize_keyword_map(value) when is_map(value), do: value
  defp normalize_keyword_map(value) when is_list(value), do: Enum.into(value, %{})
  defp normalize_keyword_map(_), do: %{}

  defp normalize_sign_mode(:strict), do: :strict
  defp normalize_sign_mode(:compat), do: :compat
  defp normalize_sign_mode("strict"), do: :strict
  defp normalize_sign_mode("compat"), do: :compat
  defp normalize_sign_mode(_), do: :strict

  defp resolve_time_window(:strict, nil), do: @strict_window_sec
  defp resolve_time_window(:compat, nil), do: @compat_window_sec
  defp resolve_time_window(_, value) when is_integer(value) and value > 0, do: value
  defp resolve_time_window(:strict, _), do: @strict_window_sec
  defp resolve_time_window(:compat, _), do: @compat_window_sec
end
