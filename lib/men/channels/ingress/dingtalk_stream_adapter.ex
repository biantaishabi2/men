defmodule Men.Channels.Ingress.DingtalkStreamAdapter do
  @moduledoc """
  钉钉 Stream 入站适配：将 sidecar 转发的事件转换为 men inbound_event。
  """

  @channel "dingtalk"

  @spec normalize(map()) :: {:ok, map()} | {:error, map()}
  def normalize(params) when is_map(params) do
    with {:ok, sender_id} <-
           fetch_required_binary(
             params,
             ["sender_staff_id", "senderStaffId", "sender_id", "senderId"],
             :sender_id
           ),
         {:ok, content} <- fetch_content(params),
         {:ok, conversation_id} <-
           fetch_optional_binary(params, [
             "conversation_id",
             "conversationId",
             "chat_id",
             "chatId"
           ]),
         {:ok, message_id} <- fetch_optional_binary(params, ["message_id", "msgId"]),
         {:ok, request_id} <- resolve_request_id(params, message_id),
         {:ok, run_id} <- resolve_run_id(params, message_id) do
      inbound_event = %{
        request_id: request_id,
        run_id: run_id,
        # Stream 会话以用户粒度聚合，避免 conversation_id 字符集导致 session_key 构建失败。
        session_key: "#{@channel}:#{sender_id}",
        payload: %{
          channel: @channel,
          content: content,
          sender_id: sender_id,
          conversation_id: conversation_id,
          message_id: message_id,
          raw_payload: Map.get(params, "raw_payload", params)
        },
        channel: @channel,
        user_id: sender_id,
        group_id: conversation_id,
        metadata: %{
          channel: @channel,
          sender_id: sender_id,
          conversation_id: conversation_id,
          message_id: message_id,
          mention_required: mention_required?(params),
          mentioned: mentioned?(params, content),
          source: "dingtalk_stream",
          raw_payload: Map.get(params, "raw_payload", params)
        }
      }

      {:ok, inbound_event}
    end
  end

  def normalize(_params), do: invalid_request("request must be map")

  defp fetch_content(params) do
    candidates = [
      Map.get(params, "content"),
      get_in(params, ["text", "content"]),
      get_in(params, ["text", "text"]),
      get_in(params, ["msg", "content", "text"]),
      get_in(params, ["msg", "text"])
    ]

    value = Enum.find(candidates, &(is_binary(&1) and String.trim(&1) != ""))

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      invalid_field(:content, "missing text content")
    end
  end

  defp fetch_required_binary(params, keys, field_name) do
    value =
      keys
      |> Enum.map(&Map.get(params, &1))
      |> Enum.find(&(is_binary(&1) and &1 != ""))

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      invalid_field(field_name, "missing required field")
    end
  end

  defp fetch_optional_binary(params, keys) do
    value =
      keys
      |> Enum.map(&Map.get(params, &1))
      |> Enum.find(&(is_binary(&1) and &1 != ""))

    {:ok, value}
  end

  defp resolve_request_id(params, message_id) do
    request_id =
      Map.get(params, "request_id") ||
        Map.get(params, "requestId") ||
        message_id ||
        "stream-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    {:ok, request_id}
  end

  defp resolve_run_id(params, message_id) do
    case Map.get(params, "run_id") || Map.get(params, "runId") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        suffix = message_id || Integer.to_string(System.unique_integer([:positive, :monotonic]))
        {:ok, "run-stream-" <> suffix}
    end
  end

  # 钉钉 Stream 私聊默认不要求 @，群聊保持 @ 门禁，避免群内噪音触发。
  defp mention_required?(params) when is_map(params) do
    raw = Map.get(params, "raw_payload", params)
    conversation_type = Map.get(raw, "conversationType") || Map.get(raw, "conversation_type")

    case conversation_type do
      value when value in ["2", 2, "group"] -> true
      _ -> false
    end
  end

  defp mention_required?(_), do: false

  defp mentioned?(params, content) when is_map(params) do
    raw = Map.get(params, "raw_payload", params)

    case Map.get(raw, "isInAtList") do
      value when is_boolean(value) ->
        value

      _ ->
        String.contains?(content, "@")
    end
  end

  defp mentioned?(_params, content), do: String.contains?(content, "@")

  defp invalid_request(reason) do
    {:error,
     %{
       code: "INVALID_REQUEST",
       message: "invalid dingtalk stream request",
       details: %{reason: reason}
     }}
  end

  defp invalid_field(field, reason) do
    {:error,
     %{
       code: "MISSING_FIELD",
       message: "invalid or missing field",
       details: %{field: field, reason: reason}
     }}
  end
end
