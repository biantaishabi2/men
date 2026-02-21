defmodule Men.Channels.Egress.DingtalkRobotAdapter do
  @moduledoc """
  钉钉机器人出站适配：将最终消息主动发送到钉钉机器人 webhook。
  """

  @behaviour Men.Channels.Egress.Adapter

  alias Men.Channels.Egress.Messages.{ErrorMessage, FinalMessage}

  defmodule HttpTransport do
    @moduledoc false

    @callback post(binary(), [{binary(), binary()}], binary(), keyword()) ::
                {:ok, %{status: non_neg_integer(), body: term()}} | {:error, term()}

    @behaviour __MODULE__

    @impl true
    def post(url, headers, body, opts) do
      finch_name = Keyword.get(opts, :finch, Men.Finch)
      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, finch_name) do
        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          decoded_body =
            case Jason.decode(resp_body) do
              {:ok, json} -> json
              _ -> resp_body
            end

          {:ok, %{status: status, body: decoded_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def send(_target, %FinalMessage{} = message) do
    send_text(build_final_text(message))
  end

  def send(_target, %ErrorMessage{} = message) do
    send_text(build_error_text(message))
  end

  def send(_target, _message), do: {:error, :unsupported_message}

  defp send_text(content) do
    with {:ok, cfg} <- load_config(),
         {:ok, url} <- build_url(cfg),
         {:ok, body} <- Jason.encode(%{"msgtype" => "text", "text" => %{"content" => content}}),
         :ok <- do_post(cfg, url, body) do
      :ok
    end
  end

  defp do_post(cfg, url, body) do
    headers = [{"content-type", "application/json"}]

    case cfg.transport.post(url, headers, body, cfg.request_opts) do
      {:ok, %{status: 200, body: %{"errcode" => 0}}} ->
        :ok

      {:ok, %{status: 200, body: %{"errcode" => errcode, "errmsg" => errmsg}}} ->
        {:error, {:dingtalk_error, errcode, errmsg}}

      {:ok, %{status: status, body: body_resp}} ->
        {:error, {:http_status, status, body_resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_config do
    app_cfg = Application.get_env(:men, __MODULE__, [])

    webhook_url =
      Keyword.get(app_cfg, :webhook_url) ||
        System.get_env("DINGTALK_ROBOT_WEBHOOK_URL")

    if is_binary(webhook_url) and webhook_url != "" do
      {:ok,
       %{
         webhook_url: webhook_url,
         secret: Keyword.get(app_cfg, :secret) || System.get_env("DINGTALK_ROBOT_SECRET"),
         sign_enabled:
           Keyword.get(app_cfg, :sign_enabled, false) or
             System.get_env("DINGTALK_ROBOT_SIGN_ENABLED") in ~w(true TRUE 1),
         transport: Keyword.get(app_cfg, :transport, HttpTransport),
         request_opts: Keyword.get(app_cfg, :request_opts, [])
       }}
    else
      {:error, :missing_webhook_url}
    end
  end

  defp build_url(%{sign_enabled: true, secret: secret, webhook_url: url})
       when is_binary(secret) and secret != "" do
    timestamp = System.system_time(:millisecond)
    string_to_sign = "#{timestamp}\n#{secret}"

    sign =
      :crypto.mac(:hmac, :sha256, secret, string_to_sign)
      |> Base.encode64()

    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    new_query = Map.merge(query, %{"timestamp" => Integer.to_string(timestamp), "sign" => sign})

    {:ok, %{uri | query: URI.encode_query(new_query)} |> URI.to_string()}
  end

  defp build_url(%{webhook_url: url}), do: {:ok, url}

  defp build_final_text(%FinalMessage{} = message) do
    request_id = metadata_value(message.metadata, :request_id, "unknown_request")
    run_id = metadata_value(message.metadata, :run_id, "unknown_run")
    "[request_id=#{request_id} run_id=#{run_id}] #{message.content}"
  end

  defp build_error_text(%ErrorMessage{} = message) do
    request_id = metadata_value(message.metadata, :request_id, "unknown_request")
    run_id = metadata_value(message.metadata, :run_id, "unknown_run")
    code = if is_binary(message.code) and message.code != "", do: "[#{message.code}] ", else: ""
    "[request_id=#{request_id} run_id=#{run_id}] #{code}#{message.reason}"
  end

  defp metadata_value(metadata, key, default) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  end

  defp metadata_value(_metadata, _key, default), do: default
end
