defmodule Men.Channels.Egress.DingtalkRobotAdapter do
  @moduledoc """
  钉钉机器人出站适配。

  支持两种出站模式：
  - `:webhook`：传统群 webhook 机器人。
  - `:app_robot`：基于 `robotCode + appKey/appSecret` 的单聊机器人发送接口。
  """

  @behaviour Men.Channels.Egress.Adapter

  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}
  require Logger

  @stream_state_table :men_dingtalk_stream_state
  @default_stream_state_ttl_ms 300_000

  defmodule HttpTransport do
    @moduledoc false

    @callback request(:get | :post, binary(), [{binary(), binary()}], binary() | nil, keyword()) ::
                {:ok, %{status: non_neg_integer(), body: term()}} | {:error, term()}

    @behaviour __MODULE__

    @impl true
    def request(method, url, headers, body, opts) when method in [:get, :post] do
      finch_name = Keyword.get(opts, :finch, Men.Finch)
      request = Finch.build(method, url, headers, body)

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
  def send(target, %FinalMessage{} = message) do
    with {:ok, cfg} <- load_config() do
      maybe_send_final(target, message, cfg)
    end
  end

  def send(target, %ErrorMessage{} = message) do
    send_text(target, build_error_text(message))
  end

  def send(target, %EventMessage{} = message) do
    with {:ok, cfg} <- load_config() do
      maybe_send_event(target, message, cfg)
    end
  end

  def send(_target, _message), do: {:error, :unsupported_message}

  defp send_text(target, content) do
    with {:ok, cfg} <- load_config() do
      do_send(target, content, cfg)
    end
  end

  # 钉钉普通机器人不支持同消息增量更新，默认 delta_only 防止出现“分片 + 最终”双回复。
  defp maybe_send_final(target, %FinalMessage{} = message, cfg) do
    run_id = metadata_value(message.metadata, :run_id, nil)
    log_meta = stream_log_meta(target, message.metadata, message.session_key)

    if suppress_final?(cfg, run_id) do
      Logger.info("dingtalk_robot_egress.final_suppress",
        stream_output_mode: cfg.stream_output_mode,
        run_id: log_meta.run_id,
        request_id: log_meta.request_id,
        session_key: log_meta.session_key
      )

      clear_stream_state(run_id)
      :ok
    else
      Logger.info("dingtalk_robot_egress.final_emit",
        stream_output_mode: cfg.stream_output_mode,
        run_id: log_meta.run_id,
        request_id: log_meta.request_id,
        session_key: log_meta.session_key
      )

      do_send(target, build_final_text(message), cfg)
    end
  end

  defp maybe_send_event(target, %EventMessage{event_type: :delta} = message, %{stream_output_mode: :final_only} = cfg) do
    log_meta = stream_log_meta(target, message.metadata, nil)

    Logger.info("dingtalk_robot_egress.delta_drop",
      stream_output_mode: cfg.stream_output_mode,
      run_id: log_meta.run_id,
      request_id: log_meta.request_id,
      session_key: log_meta.session_key
    )

    :ok
  end

  defp maybe_send_event(target, %EventMessage{} = message, cfg) do
    content = build_event_text(message)
    result = do_send(target, content, cfg)

    case {result, message.event_type} do
      {:ok, :delta} ->
        run_id = metadata_value(message.metadata, :run_id, nil)
        mark_stream_delta_sent(run_id, cfg.stream_state_ttl_ms)

        log_meta = stream_log_meta(target, message.metadata, nil)

        Logger.info("dingtalk_robot_egress.delta_emit",
          stream_output_mode: cfg.stream_output_mode,
          content_len: String.length(content),
          run_id: log_meta.run_id,
          request_id: log_meta.request_id,
          session_key: log_meta.session_key
        )

        :ok

      _ ->
        result
    end
  end

  defp stream_log_meta(target, metadata, fallback_session_key) do
    %{
      run_id: metadata_value(metadata, :run_id, nil),
      request_id: metadata_value(metadata, :request_id, nil),
      session_key:
        metadata_value(metadata, :session_key, fallback_session_key) || to_string(target || "")
    }
  end

  defp do_send(_target, content, %{mode: :webhook} = cfg) do
    with {:ok, url} <- build_webhook_url(cfg),
         {:ok, body} <- build_webhook_body(content, cfg),
         :ok <- do_post_webhook(cfg, url, body) do
      :ok
    end
  end

  defp do_send(target, content, %{mode: :app_robot} = cfg) do
    with {:ok, user_ids} <- resolve_user_ids(target),
         {:ok, access_token} <- fetch_app_access_token(cfg),
         {:ok, body} <- build_app_robot_body(cfg.robot_code, user_ids, content, cfg),
         :ok <- do_post_app_robot(cfg, access_token, body) do
      :ok
    end
  end

  defp do_post_webhook(cfg, url, body) do
    headers = [{"content-type", "application/json"}]

    case cfg.transport.request(:post, url, headers, body, cfg.request_opts) do
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

  defp do_post_app_robot(cfg, access_token, body) do
    headers = [
      {"content-type", "application/json"},
      {"x-acs-dingtalk-access-token", access_token}
    ]

    case cfg.transport.request(:post, cfg.app_send_url, headers, body, cfg.request_opts) do
      {:ok, %{status: status, body: %{"errcode" => errcode, "errmsg" => errmsg}}}
      when status in 200..299 and errcode not in [0, nil] ->
        {:error, {:dingtalk_error, errcode, errmsg}}

      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body_resp}} ->
        {:error, {:http_status, status, body_resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_config do
    app_cfg = Application.get_env(:men, __MODULE__, [])
    transport = Keyword.get(app_cfg, :transport, HttpTransport)
    request_opts = Keyword.get(app_cfg, :request_opts, [])

    webhook_url =
      Keyword.get(app_cfg, :webhook_url) || System.get_env("DINGTALK_ROBOT_WEBHOOK_URL")

    mode =
      case Keyword.get(app_cfg, :mode) || System.get_env("DINGTALK_ROBOT_MODE") do
        :app_robot -> :app_robot
        "app_robot" -> :app_robot
        :webhook -> :webhook
        "webhook" -> :webhook
        _ -> infer_mode(webhook_url, app_cfg)
      end

    case mode do
      :webhook ->
        if is_binary(webhook_url) and webhook_url != "" do
          {:ok,
           %{
             mode: :webhook,
             webhook_url: webhook_url,
             secret: Keyword.get(app_cfg, :secret) || System.get_env("DINGTALK_ROBOT_SECRET"),
             sign_enabled:
               Keyword.get(app_cfg, :sign_enabled, false) or
                 System.get_env("DINGTALK_ROBOT_SIGN_ENABLED") in ~w(true TRUE 1),
             msg_key: normalize_msg_key(cfg_value(app_cfg, :msg_key, "DINGTALK_ROBOT_MSG_KEY")),
             markdown_title:
               cfg_value(
                 app_cfg,
                 :markdown_title,
                 "DINGTALK_ROBOT_MARKDOWN_TITLE",
                 "Men"
               ),
             stream_output_mode:
               parse_stream_output_mode(
                 cfg_value(app_cfg, :stream_output_mode, "DINGTALK_STREAM_OUTPUT_MODE")
               ),
             stream_state_ttl_ms:
               parse_positive_integer(
                 cfg_value(app_cfg, :stream_state_ttl_ms, "DINGTALK_STREAM_STATE_TTL_MS"),
                 @default_stream_state_ttl_ms
               ),
             transport: transport,
             request_opts: request_opts
           }}
        else
          {:error, :missing_webhook_url}
        end

      :app_robot ->
        with {:ok, robot_code} <-
               required_binary(
                 cfg_value(app_cfg, :robot_code, "DINGTALK_ROBOT_CODE"),
                 :missing_robot_code
               ),
             {:ok, app_key} <-
               required_binary(cfg_value(app_cfg, :app_key, "DINGTALK_APP_KEY"), :missing_app_key),
             {:ok, app_secret} <-
               required_binary(
                 cfg_value(app_cfg, :app_secret, "DINGTALK_APP_SECRET"),
                 :missing_app_secret
               ) do
          {:ok,
           %{
             mode: :app_robot,
             robot_code: robot_code,
             app_key: app_key,
             app_secret: app_secret,
             msg_key: normalize_msg_key(cfg_value(app_cfg, :msg_key, "DINGTALK_ROBOT_MSG_KEY")),
             markdown_title:
               cfg_value(
                 app_cfg,
                 :markdown_title,
                 "DINGTALK_ROBOT_MARKDOWN_TITLE",
                 "Men"
               ),
             token_url:
               cfg_value(
                 app_cfg,
                 :token_url,
                 "DINGTALK_TOKEN_URL",
                 "https://oapi.dingtalk.com/gettoken"
               ),
             app_send_url:
               cfg_value(
                 app_cfg,
                 :app_send_url,
                 "DINGTALK_ROBOT_OTO_SEND_URL",
                 "https://api.dingtalk.com/v1.0/robot/oToMessages/batchSend"
               ),
             stream_output_mode:
               parse_stream_output_mode(
                 cfg_value(app_cfg, :stream_output_mode, "DINGTALK_STREAM_OUTPUT_MODE")
               ),
             stream_state_ttl_ms:
               parse_positive_integer(
                 cfg_value(app_cfg, :stream_state_ttl_ms, "DINGTALK_STREAM_STATE_TTL_MS"),
                 @default_stream_state_ttl_ms
               ),
             transport: transport,
             request_opts: request_opts
           }}
        end
    end
  end

  defp parse_stream_output_mode(value) when value in [:delta_plus_final, :delta_only, :final_only],
    do: value

  defp parse_stream_output_mode(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "delta_plus_final" -> :delta_plus_final
      "final_only" -> :final_only
      _ -> :delta_only
    end
  end

  # 纯文本机器人默认 final_only，避免视觉上刷屏；真正流式卡片能力单独实现。
  defp parse_stream_output_mode(_), do: :final_only

  defp parse_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp build_webhook_body(content, cfg) do
    case cfg.msg_key do
      "sampleMarkdown" ->
        Jason.encode(%{
          "msgtype" => "markdown",
          "markdown" => %{"title" => cfg.markdown_title, "text" => content}
        })

      _ ->
        Jason.encode(%{"msgtype" => "text", "text" => %{"content" => content}})
    end
  end

  defp infer_mode(webhook_url, app_cfg) do
    has_app_cfg =
      has_binary?(cfg_value(app_cfg, :robot_code, "DINGTALK_ROBOT_CODE")) and
        has_binary?(cfg_value(app_cfg, :app_key, "DINGTALK_APP_KEY")) and
        has_binary?(cfg_value(app_cfg, :app_secret, "DINGTALK_APP_SECRET"))

    cond do
      has_app_cfg -> :app_robot
      is_binary(webhook_url) and webhook_url != "" -> :webhook
      true -> :webhook
    end
  end

  defp suppress_final?(%{stream_output_mode: :delta_plus_final}, _run_id), do: false
  defp suppress_final?(%{stream_output_mode: :final_only}, _run_id), do: false
  defp suppress_final?(%{stream_output_mode: :delta_only}, run_id), do: delta_seen_recently?(run_id)
  defp suppress_final?(_cfg, _run_id), do: false

  defp mark_stream_delta_sent(run_id, ttl_ms) when is_binary(run_id) and run_id != "" do
    ensure_stream_state_table!()
    expire_at_ms = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@stream_state_table, {run_id, expire_at_ms})
    :ok
  end

  defp mark_stream_delta_sent(_run_id, _ttl_ms), do: :ok

  defp delta_seen_recently?(run_id) when is_binary(run_id) and run_id != "" do
    ensure_stream_state_table!()
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@stream_state_table, run_id) do
      [{^run_id, expire_at_ms}] when is_integer(expire_at_ms) and expire_at_ms > now_ms ->
        true

      [{^run_id, _expire_at_ms}] ->
        :ets.delete(@stream_state_table, run_id)
        false

      _ ->
        false
    end
  end

  defp delta_seen_recently?(_run_id), do: false

  defp clear_stream_state(run_id) when is_binary(run_id) and run_id != "" do
    if :ets.whereis(@stream_state_table) != :undefined do
      :ets.delete(@stream_state_table, run_id)
    end

    :ok
  end

  defp clear_stream_state(_run_id), do: :ok

  defp ensure_stream_state_table! do
    case :ets.whereis(@stream_state_table) do
      :undefined ->
        _ = :ets.new(@stream_state_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  @doc false
  def __reset_stream_state_for_test__ do
    if :ets.whereis(@stream_state_table) != :undefined do
      :ets.delete_all_objects(@stream_state_table)
    end

    :ok
  end

  defp fetch_app_access_token(cfg) do
    params = URI.encode_query(%{"appkey" => cfg.app_key, "appsecret" => cfg.app_secret})
    token_url = append_query(cfg.token_url, params)

    case cfg.transport.request(:get, token_url, [], nil, cfg.request_opts) do
      {:ok, %{status: 200, body: %{"access_token" => access_token}}}
      when is_binary(access_token) and access_token != "" ->
        {:ok, access_token}

      {:ok, %{status: 200, body: %{"errcode" => errcode, "errmsg" => errmsg}}} ->
        {:error, {:dingtalk_error, errcode, errmsg}}

      {:ok, %{status: status, body: body_resp}} ->
        {:error, {:http_status, status, body_resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_app_robot_body(robot_code, user_ids, content, cfg) do
    with {:ok, msg_param} <- build_app_robot_msg_param(content, cfg),
         {:ok, body} <-
           Jason.encode(%{
             "robotCode" => robot_code,
             "userIds" => user_ids,
             "msgKey" => cfg.msg_key,
             "msgParam" => msg_param
           }) do
      {:ok, body}
    end
  end

  defp build_app_robot_msg_param(content, %{msg_key: "sampleMarkdown", markdown_title: title}) do
    Jason.encode(%{"title" => title, "text" => content})
  end

  defp build_app_robot_msg_param(content, _cfg) do
    Jason.encode(%{"content" => content})
  end

  defp resolve_user_ids(target) do
    case extract_user_ids(target) do
      [] -> {:error, :missing_user_id}
      user_ids -> {:ok, user_ids}
    end
  end

  defp extract_user_ids(%{} = target) do
    from_list = normalize_id_list(Map.get(target, :user_ids) || Map.get(target, "user_ids"))
    from_single = normalize_id_list(Map.get(target, :user_id) || Map.get(target, "user_id"))

    from_session =
      target
      |> Map.get(:session_key, Map.get(target, "session_key"))
      |> normalize_id_list()

    (from_list ++ from_single ++ from_session) |> Enum.uniq()
  end

  defp extract_user_ids(target), do: normalize_id_list(target)

  defp normalize_id_list(ids) when is_list(ids) do
    ids
    |> Enum.flat_map(&normalize_id_list/1)
    |> Enum.uniq()
  end

  defp normalize_id_list("dingtalk:" <> rest) do
    rest
    |> String.split(":")
    |> List.first("")
    |> normalize_id_list()
  end

  defp normalize_id_list(ids) when is_binary(ids) do
    ids
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(fn id ->
      case String.split(id, ":") do
        [head | _] -> head
        _ -> id
      end
    end)
  end

  defp normalize_id_list(_), do: []

  defp build_webhook_url(%{sign_enabled: true, secret: secret, webhook_url: url})
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

  defp build_webhook_url(%{webhook_url: url}), do: {:ok, url}

  defp append_query(url, extra_query) do
    uri = URI.parse(url)
    current = URI.decode_query(uri.query || "")
    merged = Map.merge(current, URI.decode_query(extra_query))
    %{uri | query: URI.encode_query(merged)} |> URI.to_string()
  end

  defp cfg_value(app_cfg, key, env), do: Keyword.get(app_cfg, key) || System.get_env(env)

  defp cfg_value(app_cfg, key, env, default),
    do: Keyword.get(app_cfg, key) || System.get_env(env) || default

  defp required_binary(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_, reason), do: {:error, reason}
  defp has_binary?(value), do: is_binary(value) and value != ""
  defp normalize_msg_key("sampleMarkdown"), do: "sampleMarkdown"
  defp normalize_msg_key(_), do: "sampleText"

  defp build_final_text(%FinalMessage{} = message) do
    if include_trace_prefix?() do
      request_id = metadata_value(message.metadata, :request_id, "unknown_request")
      run_id = metadata_value(message.metadata, :run_id, "unknown_run")
      "[request_id=#{request_id} run_id=#{run_id}] #{message.content}"
    else
      message.content
    end
  end

  defp build_error_text(%ErrorMessage{} = message) do
    code = if is_binary(message.code) and message.code != "", do: "[#{message.code}] ", else: ""

    if include_trace_prefix?() do
      request_id = metadata_value(message.metadata, :request_id, "unknown_request")
      run_id = metadata_value(message.metadata, :run_id, "unknown_run")
      "[request_id=#{request_id} run_id=#{run_id}] #{code}#{message.reason}"
    else
      "#{code}#{message.reason}"
    end
  end

  defp build_event_text(%EventMessage{event_type: :delta, payload: payload, metadata: metadata}) do
    text =
      case payload do
        %{text: value} when is_binary(value) -> value
        %{"text" => value} when is_binary(value) -> value
        value when is_binary(value) -> value
        _ -> ""
      end

    if include_trace_prefix?() do
      request_id = metadata_value(metadata, :request_id, "unknown_request")
      run_id = metadata_value(metadata, :run_id, "unknown_run")
      "[request_id=#{request_id} run_id=#{run_id}] #{text}"
    else
      text
    end
  end

  defp build_event_text(%EventMessage{event_type: :error, payload: payload, metadata: metadata}) do
    reason =
      case payload do
        %{reason: value} when is_binary(value) -> value
        %{"reason" => value} when is_binary(value) -> value
        _ -> "runtime stream error"
      end

    if include_trace_prefix?() do
      request_id = metadata_value(metadata, :request_id, "unknown_request")
      run_id = metadata_value(metadata, :run_id, "unknown_run")
      "[request_id=#{request_id} run_id=#{run_id}] #{reason}"
    else
      reason
    end
  end

  defp build_event_text(%EventMessage{payload: payload}) do
    case payload do
      %{text: value} when is_binary(value) -> value
      %{"text" => value} when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp include_trace_prefix? do
    app_cfg = Application.get_env(:men, __MODULE__, [])

    Keyword.get(app_cfg, :include_trace_prefix, false) or
      System.get_env("DINGTALK_ROBOT_INCLUDE_TRACE_PREFIX") in ~w(true TRUE 1)
  end

  defp metadata_value(metadata, key, default) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  end

  defp metadata_value(_metadata, _key, default), do: default
end
