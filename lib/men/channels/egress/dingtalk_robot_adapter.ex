defmodule Men.Channels.Egress.DingtalkRobotAdapter do
  @moduledoc """
  钉钉机器人出站适配：将统一事件主动发送到钉钉机器人 webhook。
  """

  @behaviour Men.Channels.Egress.Adapter

  alias Men.Channels.Egress.Messages
  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}

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
  def send(target, %EventMessage{} = message) do
    send_text(target, build_event_text(message))
  end

  def send(target, %FinalMessage{} = message) do
    message
    |> final_to_event_message()
    |> build_event_text()
    |> then(&send_text(target, &1))
  end

  def send(target, %ErrorMessage{} = message) do
    message
    |> error_to_event_message()
    |> build_event_text()
    |> then(&send_text(target, &1))
  end

  def send(_target, _message), do: {:error, :unsupported_message}

  defp send_text(target, content) do
    with {:ok, cfg} <- load_config(target),
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

  defp load_config(target) do
    app_cfg = Application.get_env(:men, __MODULE__, [])
    target_cfg = normalize_target_config(target)

    webhook_url =
      target_cfg.webhook_url ||
        Keyword.get(app_cfg, :webhook_url) ||
        System.get_env("DINGTALK_ROBOT_WEBHOOK_URL")

    if is_binary(webhook_url) and webhook_url != "" do
      {:ok,
       %{
         webhook_url: webhook_url,
         secret:
           target_cfg.secret ||
             Keyword.get(app_cfg, :secret) ||
             System.get_env("DINGTALK_ROBOT_SECRET"),
         sign_enabled:
           target_cfg.sign_enabled || Keyword.get(app_cfg, :sign_enabled, false) or
             System.get_env("DINGTALK_ROBOT_SIGN_ENABLED") in ~w(true TRUE 1),
         transport: target_cfg.transport || Keyword.get(app_cfg, :transport, HttpTransport),
         request_opts: target_cfg.request_opts || Keyword.get(app_cfg, :request_opts, [])
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

  defp final_to_event_message(%FinalMessage{} = message) do
    %EventMessage{event_type: :final, payload: %{text: message.content}, metadata: message.metadata || %{}}
  end

  defp error_to_event_message(%ErrorMessage{} = message) do
    %EventMessage{
      event_type: :error,
      payload: %{reason: message.reason, code: message.code},
      metadata: message.metadata || %{}
    }
  end

  defp build_event_text(%EventMessage{event_type: :delta} = message) do
    run_id = metadata_value(message.metadata, :run_id, "unknown_run")
    session_key = metadata_value(message.metadata, :session_key, "unknown_session")
    "[delta][run_id=#{run_id} session_key=#{session_key}] #{payload_text(message.payload)}"
  end

  # final 保留 request/run 前缀格式，同时追加 session_key 归属信息。
  defp build_event_text(%EventMessage{event_type: :final} = message) do
    request_id = metadata_value(message.metadata, :request_id, "unknown_request")
    run_id = metadata_value(message.metadata, :run_id, "unknown_run")
    session_key = metadata_value(message.metadata, :session_key, "unknown_session")

    "[request_id=#{request_id} run_id=#{run_id} session_key=#{session_key}] #{payload_text(message.payload)}"
  end

  defp build_event_text(%EventMessage{event_type: :error} = message) do
    request_id = metadata_value(message.metadata, :request_id, "unknown_request")
    run_id = metadata_value(message.metadata, :run_id, "unknown_run")
    session_key = metadata_value(message.metadata, :session_key, "unknown_session")

    code =
      message.payload
      |> payload_value(:code)
      |> normalize_error_code()

    reason =
      (payload_value(message.payload, :reason) ||
         payload_value(message.payload, :message) ||
         "dispatch failed")
      |> stringify_error_field("dispatch failed")

    prefix = if code == "", do: "[ERROR]", else: "[ERROR][#{code}]"

    "[request_id=#{request_id} run_id=#{run_id} session_key=#{session_key}] #{prefix} #{reason}"
  end

  defp build_event_text(%EventMessage{} = message) do
    run_id = metadata_value(message.metadata, :run_id, "unknown_run")
    session_key = metadata_value(message.metadata, :session_key, "unknown_session")
    "[event=#{message.event_type} run_id=#{run_id} session_key=#{session_key}] #{inspect(message.payload)}"
  end

  defp payload_text(payload) when is_binary(payload), do: payload

  defp payload_text(payload) when is_map(payload) do
    payload_value(payload, :text) ||
      payload_value(payload, :content) ||
      payload_value(payload, :message) ||
      inspect(payload)
  end

  defp payload_text(payload), do: inspect(payload)

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_value(_payload, _key), do: nil

  defp normalize_error_code(nil), do: ""

  defp normalize_error_code(code) when is_atom(code) do
    code
    |> Atom.to_string()
    |> String.trim()
  end

  defp normalize_error_code(code) when is_binary(code), do: String.trim(code)
  defp normalize_error_code(code), do: stringify_error_field(code, "") |> String.trim()

  # 错误字段可能是结构化类型，统一安全转字符串，避免 String.Chars 协议崩溃。
  defp stringify_error_field(nil, default), do: default
  defp stringify_error_field(value, _default) when is_binary(value), do: value
  defp stringify_error_field(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp stringify_error_field(value, _default) when is_integer(value), do: Integer.to_string(value)
  defp stringify_error_field(value, _default) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp stringify_error_field(value, _default), do: inspect(value)

  defp metadata_value(metadata, key, default), do: Messages.metadata_value(metadata, key, default)

  defp normalize_target_config(target) when is_map(target) do
    %{
      webhook_url: map_value(target, :webhook_url),
      secret: map_value(target, :secret),
      sign_enabled: map_value(target, :sign_enabled) == true,
      transport: map_value(target, :transport),
      request_opts: map_value(target, :request_opts)
    }
  end

  defp normalize_target_config(_target) do
    %{webhook_url: nil, secret: nil, sign_enabled: false, transport: nil, request_opts: nil}
  end

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
