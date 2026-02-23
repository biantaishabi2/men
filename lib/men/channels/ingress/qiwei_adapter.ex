defmodule Men.Channels.Ingress.QiweiAdapter do
  @moduledoc """
  企微回调入站适配：将解密后的 XML 标准化为 dispatch inbound_event。
  """

  @behaviour Men.Channels.Ingress.Adapter

  @channel "qiwei"

  @impl true
  def normalize(%{xml: xml} = attrs) when is_binary(xml) do
    msg_type = xml_value(xml, "MsgType") |> downcase_default("unknown")
    to_user = xml_value(xml, "ToUserName") || ""
    from_user = xml_value(xml, "FromUserName") || ""
    create_time = xml_integer(xml, "CreateTime")
    msg_id = xml_value(xml, "MsgId")
    agent_id = xml_value(xml, "AgentID")
    event = xml_value(xml, "Event") |> downcase_default("")
    event_key = xml_value(xml, "EventKey") || ""
    content = xml_value(xml, "Content") || ""

    tenant_id =
      xml_value(xml, "CorpId") ||
        to_user ||
        map_value(attrs, :tenant_id, nil) ||
        "default_tenant"

    at_list = extract_at_list(xml)

    payload = %{
      channel: @channel,
      tenant_id: tenant_id,
      corp_id: to_user,
      from_user: from_user,
      to_user: to_user,
      create_time: create_time,
      agent_id: agent_id,
      msg_id: msg_id,
      msg_type: msg_type,
      content: content,
      at_list: at_list,
      event: event,
      event_key: event_key,
      raw_xml: xml,
      raw_query: Map.get(attrs, :query, %{})
    }

    request_id = resolve_request_id(payload)

    mentioned = mentioned?(payload)
    mention_required = reply_require_mention?()

    inbound_event = %{
      request_id: request_id,
      run_id: request_id,
      payload: payload,
      channel: @channel,
      user_id: from_user,
      metadata: %{
        channel: @channel,
        tenant_id: tenant_id,
        corp_id: to_user,
        agent_id: agent_id,
        msg_type: msg_type,
        event: event,
        event_key: event_key,
        mention_required: mention_required,
        mentioned: if(mention_required, do: mentioned, else: true),
        source: :qiwei_callback
      }
    }

    {:ok, inbound_event}
  end

  def normalize(_raw_message) do
    {:error,
     %{
       code: "INVALID_REQUEST",
       message: "invalid qiwei webhook request",
       details: %{}
     }}
  end

  defp resolve_request_id(payload) do
    msg_id = map_value(payload, :msg_id, nil)

    cond do
      is_binary(msg_id) and msg_id != "" ->
        msg_id

      map_value(payload, :msg_type, "") == "event" ->
        [
          "event",
          map_value(payload, :from_user, "unknown"),
          Integer.to_string(map_value(payload, :create_time, 0)),
          map_value(payload, :event, "unknown"),
          map_value(payload, :event_key, "")
        ]
        |> Enum.join(":")

      true ->
        "qiwei-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end
  end

  defp extract_at_list(xml) do
    direct_tags = ["AtUser", "AtUserId", "MentionedUser", "MentionUser"]

    from_direct =
      direct_tags
      |> Enum.flat_map(&xml_values(xml, &1))
      |> Enum.filter(&(&1 != ""))

    parent_tags = ["AtUsers", "AtUserList", "MentionedUserList", "MentionedList"]

    from_parent_items =
      parent_tags
      |> Enum.flat_map(fn parent ->
        xml
        |> xml_values(parent)
        |> Enum.flat_map(&extract_item_values/1)
      end)

    (from_direct ++ from_parent_items)
    |> Enum.uniq()
  end

  defp extract_item_values(block) when is_binary(block) do
    xml_values(block, "Item")
  end

  defp extract_item_values(_), do: []

  defp mentioned?(payload) do
    at_list = map_value(payload, :at_list, [])
    content = map_value(payload, :content, "")
    bot_user_id = qiwei_config() |> Keyword.get(:bot_user_id)
    bot_name = qiwei_config() |> Keyword.get(:bot_name)

    cond do
      is_binary(bot_user_id) and bot_user_id != "" and Enum.member?(at_list, bot_user_id) ->
        true

      is_binary(bot_name) and bot_name != "" and String.contains?(content, "@" <> bot_name) ->
        true

      true ->
        false
    end
  end

  defp reply_require_mention? do
    qiwei_config()
    |> Keyword.get(:reply_require_mention, true)
  end

  defp qiwei_config do
    Application.get_env(:men, :qiwei, [])
  end

  defp xml_value(xml, tag) do
    case xml_values(xml, tag) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp xml_values(xml, tag) when is_binary(xml) and is_binary(tag) do
    cdata_pattern = ~r/<#{tag}><!\[CDATA\[(.*?)\]\]><\/#{tag}>/s
    plain_pattern = ~r/<#{tag}>([^<]*)<\/#{tag}>/s

    cdata_values =
      Regex.scan(cdata_pattern, xml, capture: :all_but_first)
      |> Enum.map(&List.first/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if cdata_values != [] do
      cdata_values
    else
      Regex.scan(plain_pattern, xml, capture: :all_but_first)
      |> Enum.map(&List.first/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp xml_values(_xml, _tag), do: []

  defp xml_integer(xml, tag) do
    case xml_value(xml, tag) do
      nil -> 0
      value -> parse_integer(value)
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp parse_integer(_), do: 0

  defp downcase_default(nil, default), do: default
  defp downcase_default(value, _default), do: String.downcase(to_string(value))

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default
end
