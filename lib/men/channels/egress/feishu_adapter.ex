defmodule Men.Channels.Egress.FeishuAdapter do
  @moduledoc """
  飞书出站适配：将 Final/Error 消息协议化回写到飞书接口。
  """

  @behaviour Men.Channels.Egress.Adapter

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}

  defmodule HttpTransport do
    @moduledoc false

    @callback post(binary(), [{binary(), binary()}], binary(), keyword()) ::
                {:ok, %{status: non_neg_integer(), body: binary()}} | {:error, term()}

    @behaviour __MODULE__

    @impl true
    def post(url, headers, body, opts) do
      finch_name = Keyword.get(opts, :finch, Men.Finch)
      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, finch_name) do
        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          {:ok, %{status: status, body: resp_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def send(target, %FinalMessage{} = message) do
    target = normalize_target(target, message.metadata)
    final_reply(target, message)
  end

  def send(target, %ErrorMessage{} = message) do
    target = normalize_target(target, message.metadata)

    error_reply(
      target,
      message.reason,
      code: message.code,
      metadata: message.metadata
    )
  end

  def send(_target, _message), do: {:error, :unsupported_message}

  @spec final_reply(map(), FinalMessage.t()) :: :ok | {:error, term()}
  def final_reply(target, %FinalMessage{} = message) do
    with {:ok, request} <- build_request(target, final_payload(message.content), message.metadata),
         :ok <- do_post(request) do
      :ok
    end
  end

  @spec error_reply(map(), binary(), keyword()) :: :ok | {:error, term()}
  def error_reply(target, reason, opts \\ []) when is_binary(reason) do
    metadata = Keyword.get(opts, :metadata, %{})
    code = Keyword.get(opts, :code)

    text =
      case code do
        value when is_binary(value) and value != "" -> "[ERROR][#{value}] #{reason}"
        _ -> "[ERROR] #{reason}"
      end

    with {:ok, request} <- build_request(target, final_payload(text), metadata),
         :ok <- do_post(request) do
      :ok
    end
  end

  defp final_payload(content) do
    %{
      "msg_type" => "text",
      "content" => %{"text" => content}
    }
  end

  defp normalize_target(target, metadata) do
    target_map = if is_map(target), do: target, else: %{}

    %{
      "reply_token" =>
        target_map["reply_token"] || target_map[:reply_token] || metadata["reply_token"] ||
          metadata[:reply_token] || metadata["message_id"] || metadata[:message_id],
      "app_id" =>
        target_map["app_id"] || target_map[:app_id] || metadata["feishu_app_id"] ||
          metadata[:feishu_app_id]
    }
  end

  defp build_request(target, payload, _metadata) do
    with {:ok, reply_token} <- required_binary(target["reply_token"], :missing_reply_token),
         {:ok, app_id} <- required_binary(target["app_id"], :missing_app_id),
         config <- config_for_bot(app_id),
         {:ok, access_token} <- required_binary(config.access_token, :missing_access_token),
         {:ok, encoded_body} <- Jason.encode(payload) do
      url = build_url(config.base_url, reply_token)

      headers = [
        {"content-type", "application/json"},
        {"authorization", "Bearer " <> access_token}
      ]

      {:ok,
       %{
         url: url,
         headers: headers,
         body: encoded_body,
         transport: config.transport,
         request_opts: config.request_opts
       }}
    end
  end

  defp required_binary(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_, reason), do: {:error, reason}

  defp do_post(request) do
    case request.transport.post(request.url, request.headers, request.body, request.request_opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp config_for_bot(app_id) do
    app_config = Application.get_env(:men, __MODULE__, [])
    bot_overrides = app_config |> Keyword.get(:bots, %{}) |> Map.get(app_id, %{}) |> to_map()

    base =
      %{
        base_url: Keyword.get(app_config, :base_url, "https://open.feishu.cn"),
        access_token: Keyword.get(app_config, :bot_access_token),
        transport: Keyword.get(app_config, :transport, HttpTransport),
        request_opts: Keyword.get(app_config, :request_opts, [])
      }

    Map.merge(base, bot_overrides)
  end

  defp to_map(value) when is_map(value), do: value
  defp to_map(value) when is_list(value), do: Enum.into(value, %{})
  defp to_map(_), do: %{}

  defp build_url(base_url, reply_token) do
    String.trim_trailing(base_url, "/") <> "/open-apis/im/v1/messages/" <> reply_token <> "/reply"
  end
end
