defmodule Men.Channels.Egress.DingtalkAdapter do
  @moduledoc """
  钉钉出站适配：统一实现 `send/2`，回写 final 或错误摘要。
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
    post_text(target, message.content)
  end

  def send(target, %ErrorMessage{} = message) do
    target = normalize_target(target, message.metadata)
    post_text(target, format_error_summary(message))
  end

  def send(_target, _message), do: {:error, :unsupported_message}

  defp format_error_summary(%ErrorMessage{code: code, reason: reason}) do
    case code do
      value when is_binary(value) and value != "" -> "[ERROR][#{value}] #{reason}"
      _ -> "[ERROR] #{reason}"
    end
  end

  defp post_text(target, content) do
    with {:ok, webhook_url} <- required_binary(target.webhook_url, :missing_webhook_url),
         {:ok, encoded_body} <- Jason.encode(text_payload(content)) do
      request = %{
        url: webhook_url,
        headers: [{"content-type", "application/json"}],
        body: encoded_body,
        transport: target.transport,
        request_opts: target.request_opts
      }

      do_post(request)
    end
  end

  defp text_payload(content) do
    %{
      "msgtype" => "text",
      "text" => %{"content" => content}
    }
  end

  defp do_post(request) do
    case request.transport.post(request.url, request.headers, request.body, request.request_opts) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_target(target, metadata) do
    target_map = if is_map(target), do: target, else: %{}
    cfg = Application.get_env(:men, __MODULE__, [])

    %{
      webhook_url:
        fetch_value(target_map, metadata, [
          "webhook_url",
          :webhook_url,
          "dingtalk_webhook_url",
          :dingtalk_webhook_url
        ]) || Keyword.get(cfg, :webhook_url),
      transport: Keyword.get(cfg, :transport, HttpTransport),
      request_opts: Keyword.get(cfg, :request_opts, [])
    }
  end

  defp fetch_value(target_map, metadata, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(target_map, key) || Map.get(metadata, key)
    end)
  end

  defp required_binary(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_, reason), do: {:error, reason}
end
