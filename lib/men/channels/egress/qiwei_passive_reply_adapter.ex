defmodule Men.Channels.Egress.QiweiPassiveReplyAdapter do
  @moduledoc """
  企微被动回复适配：基于 inbound_event 与 dispatch 结果决定是否回 XML。
  """

  @max_reply_len 1_024

  @spec build(map(), {:ok, map()} | {:error, map()} | term(), keyword()) ::
          {:xml, binary()} | :success
  def build(inbound_event, dispatch_result, opts \\ [])

  def build(inbound_event, dispatch_result, opts) when is_map(inbound_event) do
    payload = Map.get(inbound_event, :payload, %{})
    msg_type = Map.get(payload, :msg_type)

    if msg_type == "text" and allow_reply?(payload, opts) do
      content = dispatch_content(dispatch_result, opts)

      if is_binary(content) and content != "" do
        {:xml, build_text_reply_xml(payload, trim_reply(content))}
      else
        :success
      end
    else
      :success
    end
  end

  def build(_inbound_event, _dispatch_result, _opts), do: :success

  @spec mentioned?(map(), keyword()) :: boolean()
  def mentioned?(payload, opts \\ [])

  def mentioned?(payload, opts) when is_map(payload) do
    bot_user_id = Keyword.get(opts, :bot_user_id)
    bot_name = Keyword.get(opts, :bot_name)

    structured_hit =
      case bot_user_id do
        value when is_binary(value) and value != "" ->
          at_user_ids = Map.get(payload, :at_user_ids, [])
          Enum.any?(at_user_ids, &(&1 == value))

        _ ->
          false
      end

    fallback_hit =
      case {Map.get(payload, :content), bot_name} do
        {content, name} when is_binary(content) and is_binary(name) and name != "" ->
          String.contains?(content, "@" <> name)

        _ ->
          false
      end

    structured_hit or fallback_hit
  end

  def mentioned?(_payload, _opts), do: false

  defp allow_reply?(payload, opts) do
    require_mention = Keyword.get(opts, :require_mention, true)
    not require_mention or mentioned?(payload, opts)
  end

  defp dispatch_content({:ok, %{payload: %{text: text}}}, _opts) when is_binary(text), do: text

  defp dispatch_content({:ok, %{payload: payload}}, _opts) when is_map(payload) do
    case Map.get(payload, :text) do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  defp dispatch_content({:ok, _}, opts), do: Keyword.get(opts, :fallback_text)

  # callback 失败时默认不回错误 XML，避免触发企微重试风暴。
  defp dispatch_content({:error, _}, _opts), do: nil

  defp dispatch_content(_other, opts), do: Keyword.get(opts, :fallback_text)

  defp build_text_reply_xml(payload, content) do
    to_user = Map.get(payload, :from_user, "")
    from_user = Map.get(payload, :corp_id, "")
    create_time = System.system_time(:second)

    """
    <xml>
    <ToUserName><![CDATA[#{escape_cdata(to_user)}]]></ToUserName>
    <FromUserName><![CDATA[#{escape_cdata(from_user)}]]></FromUserName>
    <CreateTime>#{create_time}</CreateTime>
    <MsgType><![CDATA[text]]></MsgType>
    <Content><![CDATA[#{escape_cdata(content)}]]></Content>
    </xml>
    """
    |> String.trim()
  end

  defp trim_reply(content) do
    if String.length(content) <= @max_reply_len do
      content
    else
      String.slice(content, 0, @max_reply_len)
    end
  end

  defp escape_cdata(content) do
    String.replace(content, "]]>", "]] ]><![CDATA[>")
  end
end
