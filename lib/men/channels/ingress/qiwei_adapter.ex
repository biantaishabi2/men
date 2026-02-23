defmodule Men.Channels.Ingress.QiweiAdapter do
  @moduledoc """
  企微入站适配：将解密后的 XML 标准化为 dispatch inbound_event。
  """

  @channel "qiwei"

  @spec normalize(binary(), keyword()) :: {:ok, map()} | {:error, map()}
  def normalize(xml, opts \\ [])

  def normalize(xml, opts) when is_binary(xml) do
    with {:ok, msg_type} <- required_tag(xml, "MsgType", :msg_type),
         {:ok, from_user} <- required_tag(xml, "FromUserName", :from_user),
         {:ok, corp_id} <- required_tag(xml, "ToUserName", :corp_id),
         {:ok, agent_id} <- optional_integer(tag_value(xml, "AgentID")) do
      create_time = optional_integer_value(tag_value(xml, "CreateTime"))
      event_name = tag_value(xml, "Event")
      event_key = tag_value(xml, "EventKey")
      content = tag_value(xml, "Content")
      msg_id = tag_value(xml, "MsgId")

      at_user_ids =
        [
          list_tag_values(xml, "MentionedUserNameList", "item"),
          list_tag_values(xml, "MentionedUserList", "item"),
          repeated_tag_values(xml, "AtUserId")
        ]
        |> List.flatten()
        |> Enum.uniq()

      at_mobile_list =
        [
          list_tag_values(xml, "MentionedMobileList", "item"),
          repeated_tag_values(xml, "AtMobile")
        ]
        |> List.flatten()
        |> Enum.uniq()

      tenant_id =
        Keyword.get(opts, :tenant_resolver, &default_tenant_resolver/2)
        |> apply_resolver(corp_id, agent_id)

      payload = %{
        channel: @channel,
        msg_type: msg_type,
        content: content,
        event: event_name,
        event_key: event_key,
        from_user: from_user,
        corp_id: corp_id,
        tenant_id: tenant_id,
        agent_id: agent_id,
        msg_id: msg_id,
        create_time: create_time,
        at_user_ids: at_user_ids,
        at_mobile_list: at_mobile_list,
        raw_xml: xml
      }

      request_id =
        resolve_request_id(
          msg_id,
          from_user,
          create_time,
          msg_type,
          event_name,
          event_key
        )

      inbound_event = %{
        request_id: request_id,
        run_id: request_id,
        payload: payload,
        channel: @channel,
        user_id: from_user,
        metadata: %{
          channel: @channel,
          tenant_id: tenant_id,
          corp_id: corp_id,
          agent_id: agent_id,
          msg_type: msg_type,
          event: event_name,
          event_key: event_key,
          mention_required: true,
          mentioned: false
        }
      }

      {:ok, inbound_event}
    else
      {:error, reason} -> {:error, ingress_error(reason)}
    end
  end

  def normalize(_raw, _opts), do: {:error, ingress_error(:invalid_xml_payload)}

  @spec idempotency_fingerprint(map()) :: map()
  def idempotency_fingerprint(%{payload: payload}) when is_map(payload) do
    %{
      corp_id: payload[:corp_id],
      agent_id: payload[:agent_id],
      msg_id: payload[:msg_id],
      from_user: payload[:from_user],
      create_time: payload[:create_time],
      event: payload[:event],
      event_key: payload[:event_key]
    }
  end

  def idempotency_fingerprint(_), do: %{}

  defp required_tag(xml, tag, field) do
    case tag_value(xml, tag) do
      nil -> {:error, {:missing_field, field}}
      value -> {:ok, value}
    end
  end

  defp tag_value(xml, tag) do
    pattern = ~r/<#{tag}>\s*(?:<!\[CDATA\[(?<cdata>.*?)\]\]>|(?<plain>.*?))\s*<\/#{tag}>/us

    case Regex.named_captures(pattern, xml) do
      %{"cdata" => cdata, "plain" => plain} ->
        normalize_text(first_present(cdata, plain))

      _ ->
        nil
    end
  end

  defp repeated_tag_values(xml, tag) do
    pattern = ~r/<#{tag}>\s*(?:<!\[CDATA\[(?<cdata>.*?)\]\]>|(?<plain>.*?))\s*<\/#{tag}>/us

    pattern
    |> Regex.scan(xml, capture: :all_names)
    |> Enum.map(fn [cdata, plain] -> normalize_text(first_present(cdata, plain)) end)
    |> Enum.reject(&is_nil/1)
  end

  defp list_tag_values(xml, list_tag, item_tag) do
    pattern = ~r/<#{list_tag}>\s*(.*?)\s*<\/#{list_tag}>/us

    case Regex.run(pattern, xml) do
      [_, body] -> repeated_tag_values(body, item_tag)
      _ -> []
    end
  end

  defp optional_integer(nil), do: {:ok, nil}

  defp optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} -> {:ok, int_value}
      _ -> {:ok, nil}
    end
  end

  defp optional_integer(_), do: {:ok, nil}

  defp optional_integer_value(nil), do: nil

  defp optional_integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} -> int_value
      _ -> nil
    end
  end

  defp optional_integer_value(_), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp first_present(value_a, value_b) do
    if is_binary(value_a) and value_a != "", do: value_a, else: value_b
  end

  defp resolve_request_id(msg_id, _from_user, _create_time, _msg_type, _event_name, _event_key)
       when is_binary(msg_id) and msg_id != "" do
    msg_id
  end

  defp resolve_request_id(_msg_id, from_user, create_time, msg_type, event_name, event_key) do
    base =
      [
        from_user || "unknown",
        create_time || "0",
        msg_type || "unknown",
        event_name || "",
        event_key || ""
      ]
      |> Enum.map(&to_string/1)
      |> Enum.join(":")

    "qiwei-" <> Base.encode16(:crypto.hash(:sha256, base), case: :lower)
  end

  defp apply_resolver(resolver, corp_id, agent_id) when is_function(resolver, 2),
    do: resolver.(corp_id, agent_id)

  defp apply_resolver(_, corp_id, _agent_id), do: corp_id

  defp default_tenant_resolver(corp_id, _agent_id), do: corp_id

  defp ingress_error(reason) do
    %{
      code: "INVALID_XML",
      message: "invalid qiwei callback payload",
      details: %{reason: inspect(reason)}
    }
  end
end
