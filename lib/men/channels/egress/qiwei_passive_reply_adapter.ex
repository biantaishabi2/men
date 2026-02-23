defmodule Men.Channels.Egress.QiweiPassiveReplyAdapter do
  @moduledoc """
  企微被动回复适配：判定是否需要回复并生成被动回复 XML。
  """

  @type reply_result :: {:success} | {:xml, binary()}

  @spec build(map(), term(), keyword()) :: reply_result()
  def build(inbound_event, dispatch_result, opts \\ []) when is_map(inbound_event) do
    payload = Map.get(inbound_event, :payload, %{})

    if should_reply?(inbound_event, opts) do
      case reply_content(dispatch_result) do
        nil ->
          {:success}

        content ->
          truncated = truncate_content(content, max_chars(opts))

          if truncated == "" do
            {:success}
          else
            {:xml,
             build_text_xml(
               map_value(payload, :from_user, ""),
               map_value(payload, :to_user, ""),
               truncated
             )}
          end
      end
    else
      {:success}
    end
  end

  @spec should_reply?(map(), keyword()) :: boolean()
  def should_reply?(inbound_event, opts \\ []) when is_map(inbound_event) do
    payload = Map.get(inbound_event, :payload, %{})
    msg_type = map_value(payload, :msg_type, "")

    if msg_type != "text" do
      false
    else
      if require_mention?(opts) do
        mentioned_by_structured_at?(payload, bot_user_id(opts)) or
          mentioned_by_name?(payload, bot_name(opts))
      else
        true
      end
    end
  end

  defp reply_content({:ok, %{} = result}) do
    result
    |> Map.get(:payload, %{})
    |> map_value(:text, nil)
    |> normalize_content()
  end

  defp reply_content(_), do: nil

  defp normalize_content(content) when is_binary(content), do: String.trim(content)
  defp normalize_content(content) when is_atom(content), do: Atom.to_string(content)
  defp normalize_content(_), do: nil

  defp mentioned_by_structured_at?(payload, bot_user_id)
       when is_binary(bot_user_id) and bot_user_id != "" do
    payload
    |> map_value(:at_list, [])
    |> Enum.member?(bot_user_id)
  end

  defp mentioned_by_structured_at?(_payload, _bot_user_id), do: false

  defp mentioned_by_name?(payload, bot_name) when is_binary(bot_name) and bot_name != "" do
    content = map_value(payload, :content, "")
    String.contains?(content, "@" <> bot_name)
  end

  defp mentioned_by_name?(_payload, _bot_name), do: false

  defp truncate_content(content, max_chars) when is_binary(content) and is_integer(max_chars) do
    if String.length(content) <= max_chars do
      content
    else
      String.slice(content, 0, max_chars)
    end
  end

  defp build_text_xml(to_user, from_user, content) do
    safe_content = escape_cdata(content)

    [
      "<xml>",
      "<ToUserName><![CDATA[",
      to_user,
      "]]></ToUserName>",
      "<FromUserName><![CDATA[",
      from_user,
      "]]></FromUserName>",
      "<CreateTime>",
      Integer.to_string(System.system_time(:second)),
      "</CreateTime>",
      "<MsgType><![CDATA[text]]></MsgType>",
      "<Content><![CDATA[",
      safe_content,
      "]]></Content>",
      "</xml>"
    ]
    |> IO.iodata_to_binary()
  end

  # 避免内容中出现 CDATA 结束标记导致 XML 非法。
  defp escape_cdata(content) when is_binary(content) do
    String.replace(content, "]]>", "]]]]><![CDATA[>")
  end

  defp max_chars(opts) do
    Keyword.get(opts, :max_chars, qiwei_config() |> Keyword.get(:reply_max_chars, 600))
  end

  defp require_mention?(opts) do
    Keyword.get(
      opts,
      :require_mention,
      qiwei_config() |> Keyword.get(:reply_require_mention, true)
    )
  end

  defp bot_user_id(opts) do
    Keyword.get(opts, :bot_user_id, qiwei_config() |> Keyword.get(:bot_user_id))
  end

  defp bot_name(opts) do
    Keyword.get(opts, :bot_name, qiwei_config() |> Keyword.get(:bot_name))
  end

  defp qiwei_config do
    Application.get_env(:men, :qiwei, [])
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default
end
