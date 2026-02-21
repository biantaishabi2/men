defmodule Men.Channels.Ingress.DingtalkAdapter do
  @moduledoc """
  钉钉入站适配：验签、时间窗校验、事件标准化。
  """

  @behaviour Men.Channels.Ingress.Adapter

  @channel "dingtalk"
  @default_window_seconds 300

  @impl true
  def normalize(%{headers: headers, body: body} = request) when is_map(headers) and is_map(body) do
    with {:ok, secret} <- fetch_secret(),
         {:ok, timestamp} <- fetch_timestamp(headers),
         :ok <- verify_timestamp_window(timestamp, fetch_window_seconds()),
         {:ok, signature} <- fetch_signature(headers),
         {:ok, raw_body} <- fetch_raw_body(request, body),
         :ok <- verify_signature(secret, timestamp, raw_body, signature),
         {:ok, event_type} <- fetch_required_binary(body, ["event_type", "type"], :event_type),
         {:ok, sender_id} <- fetch_required_binary(body, ["sender_id", "senderId", "userid"], :sender_id),
         {:ok, conversation_id} <-
           fetch_required_binary(body, ["conversation_id", "conversationId", "chat_id"], :conversation_id),
         {:ok, content} <- fetch_required_binary(body, ["content", "text"], :content) do
      standardized_payload = %{
        channel: @channel,
        event_type: event_type,
        sender_id: sender_id,
        conversation_id: conversation_id,
        content: content,
        raw_payload: body
      }

      inbound_event = %{
        request_id: resolve_request_id(body),
        payload: standardized_payload,
        channel: @channel,
        user_id: sender_id,
        metadata: %{
          channel: @channel,
          event_type: event_type,
          sender_id: sender_id,
          conversation_id: conversation_id,
          raw_payload: body,
          raw_body: raw_body
        }
      }

      {:ok, inbound_event}
    else
      {:error, error} ->
        {:error, attach_raw_payload(error, body)}
    end
  end

  def normalize(_raw_message) do
    {:error,
     %{
       code: "INVALID_REQUEST",
       message: "invalid dingtalk webhook request",
       details: %{reason: "request must contain headers/body map"}
     }}
  end

  defp fetch_secret do
    configured = Application.get_env(:men, __MODULE__, [])

    secret =
      case Keyword.get(configured, :secret) do
        value when is_binary(value) and value != "" -> value
        _ -> System.get_env("DINGTALK_WEBHOOK_SECRET")
      end

    if is_binary(secret) and secret != "" do
      {:ok, secret}
    else
      {:error,
       %{
         code: "MISSING_SECRET",
         message: "dingtalk webhook secret is missing",
         details: %{}
       }}
    end
  end

  defp fetch_window_seconds do
    configured = Application.get_env(:men, __MODULE__, [])
    Keyword.get(configured, :signature_window_seconds, @default_window_seconds)
  end

  defp fetch_timestamp(headers) do
    value = Map.get(headers, "x-dingtalk-timestamp") || Map.get(headers, "timestamp")

    case parse_unix_timestamp(value) do
      {:ok, timestamp} -> {:ok, timestamp}
      :error -> invalid_field(:timestamp, "missing or invalid timestamp")
    end
  end

  defp parse_unix_timestamp(value) when is_integer(value), do: normalize_timestamp(value)

  defp parse_unix_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} -> normalize_timestamp(int_value)
      _ -> :error
    end
  end

  defp parse_unix_timestamp(_), do: :error

  # 支持秒与毫秒时间戳，毫秒会归一化为秒。
  defp normalize_timestamp(value) when value >= 1_000_000_000_000, do: {:ok, div(value, 1_000)}
  defp normalize_timestamp(value) when value > 0, do: {:ok, value}
  defp normalize_timestamp(_value), do: :error

  defp verify_timestamp_window(timestamp, window_seconds) do
    now = System.system_time(:second)

    if abs(now - timestamp) <= window_seconds do
      :ok
    else
      {:error,
       %{
         code: "SIGNATURE_EXPIRED",
         message: "signature timestamp expired",
         details: %{timestamp: timestamp, now: now, window_seconds: window_seconds}
       }}
    end
  end

  defp fetch_signature(headers) do
    signature = Map.get(headers, "x-dingtalk-signature") || Map.get(headers, "sign")

    if is_binary(signature) and signature != "" do
      {:ok, signature}
    else
      invalid_signature("missing signature")
    end
  end

  defp fetch_raw_body(%{raw_body: raw_body}, _body) when is_binary(raw_body), do: {:ok, raw_body}

  defp fetch_raw_body(_request, _body) do
    {:error,
     %{
       code: "INVALID_REQUEST",
       message: "raw body is required for signature verification",
       details: %{field: :raw_body}
     }}
  end

  defp verify_signature(secret, timestamp, raw_body, signature) do
    sign_input = Integer.to_string(timestamp) <> "\n" <> raw_body

    expected_signature =
      :crypto.mac(:hmac, :sha256, secret, sign_input)
      |> Base.encode64()

    if Plug.Crypto.secure_compare(expected_signature, signature) do
      :ok
    else
      invalid_signature("invalid signature")
    end
  end

  defp fetch_required_binary(body, keys, field_name) do
    value =
      keys
      |> Enum.find_value(fn key ->
        case Map.get(body, key) do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end
      end)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      invalid_field(field_name, "missing required field")
    end
  end

  defp resolve_request_id(body) do
    case Map.get(body, "event_id") || Map.get(body, "msgId") || Map.get(body, "request_id") do
      value when is_binary(value) and value != "" -> value
      _ -> "dingtalk-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end
  end

  defp invalid_field(field, reason) do
    {:error,
     %{
       code: "MISSING_FIELD",
       message: "invalid or missing field",
       details: %{field: field, reason: reason}
     }}
  end

  defp invalid_signature(reason) do
    {:error,
     %{
       code: "INVALID_SIGNATURE",
       message: "invalid signature",
       details: %{field: :signature, reason: reason}
     }}
  end

  # 失败分支也保留原始 payload，便于排障。
  defp attach_raw_payload(%{details: details} = error, raw_payload) when is_map(details) do
    Map.put(error, :details, Map.put(details, :raw_payload, raw_payload))
  end

  defp attach_raw_payload(error, raw_payload) do
    Map.put(error, :raw_payload, raw_payload)
  end
end
