defmodule Men.Channels.Egress.DingtalkCardAdapter do
  @moduledoc """
  钉钉流式卡片出站适配器。

  当前职责：
  - 按 run_id 维护卡片实例引用（ETS）
  - 处理 create/append/finalize API 调用
  - 失败时自动回退到文本通道（DingtalkRobotAdapter）
  """

  @behaviour Men.Channels.Egress.Adapter

  require Logger

  alias Men.Channels.Egress.Messages.{ErrorMessage, EventMessage, FinalMessage}
  alias Men.Gateway.StreamSessionStore

  @default_token_url "https://oapi.dingtalk.com/gettoken"
  @default_card_create_url "https://api.dingtalk.com/v1.0/card/instances/createAndDeliver"
  @default_card_append_url "https://api.dingtalk.com/v1.0/card/streaming"
  @default_card_finalize_url "https://api.dingtalk.com/v1.0/card/streaming"

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
  def send(target, %EventMessage{event_type: :delta} = message) do
    with {:ok, cfg} <- load_config(),
         {:ok, run_id} <- required_run_id(message.metadata),
         {:ok, card_ref} <- ensure_card_ref(cfg, target, message, run_id),
         :ok <- append_delta(cfg, card_ref, message, run_id) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("dingtalk_card_egress.delta_fallback",
          reason: inspect(reason),
          run_id: metadata_value(message.metadata, :run_id, nil),
          request_id: metadata_value(message.metadata, :request_id, nil)
        )

        fallback_send(target, message)
    end
  end

  def send(target, %FinalMessage{} = message) do
    with {:ok, cfg} <- load_config(),
         {:ok, run_id} <- required_run_id(message.metadata),
         {:ok, card_ref} <- ensure_card_ref(cfg, target, message, run_id),
         :ok <- finalize_card(cfg, card_ref, message, run_id) do
      :ok = StreamSessionStore.delete(run_id)
      :ok
    else
      {:error, reason} ->
        Logger.warning("dingtalk_card_egress.final_fallback",
          reason: inspect(reason),
          run_id: metadata_value(message.metadata, :run_id, nil),
          request_id: metadata_value(message.metadata, :request_id, nil)
        )

        fallback_send(target, message)
    end
  end

  def send(target, %ErrorMessage{} = message) do
    fallback_send(target, message)
  end

  def send(_target, _message), do: {:error, :unsupported_message}

  def enabled? do
    cfg = Application.get_env(:men, __MODULE__, [])

    Keyword.get(cfg, :enabled, false) ||
      System.get_env("DINGTALK_CARD_STREAM_ENABLED") in ~w(true TRUE 1)
  end

  defp load_config do
    cfg = Application.get_env(:men, __MODULE__, [])
    transport = Keyword.get(cfg, :transport, HttpTransport)
    request_opts = Keyword.get(cfg, :request_opts, [])

    with {:ok, app_key} <-
           required_binary(cfg_value(cfg, :app_key, "DINGTALK_APP_KEY"), :missing_app_key),
         {:ok, app_secret} <-
           required_binary(
             cfg_value(cfg, :app_secret, "DINGTALK_APP_SECRET"),
             :missing_app_secret
           ),
         {:ok, robot_code} <-
           required_binary(
             cfg_value(cfg, :robot_code, "DINGTALK_ROBOT_CODE"),
             :missing_robot_code
           ),
         {:ok, template_id} <-
           required_binary(
             cfg_value(cfg, :card_template_id, "DINGTALK_CARD_TEMPLATE_ID"),
             :missing_card_template_id
           ) do
      {:ok,
       %{
         app_key: app_key,
         app_secret: app_secret,
         robot_code: robot_code,
         card_template_id: template_id,
         last_message: cfg_value(cfg, :last_message, "DINGTALK_CARD_LAST_MESSAGE", "处理中..."),
         search_icon: cfg_value(cfg, :search_icon, "DINGTALK_CARD_SEARCH_ICON"),
         search_desc: cfg_value(cfg, :search_desc, "DINGTALK_CARD_SEARCH_DESC"),
         token_url: cfg_value(cfg, :token_url, "DINGTALK_TOKEN_URL", @default_token_url),
         card_create_url:
           cfg_value(cfg, :card_create_url, "DINGTALK_CARD_CREATE_URL", @default_card_create_url),
         card_append_url:
           cfg_value(cfg, :card_append_url, "DINGTALK_CARD_APPEND_URL", @default_card_append_url),
         card_finalize_url:
           cfg_value(
             cfg,
             :card_finalize_url,
             "DINGTALK_CARD_FINALIZE_URL",
             @default_card_finalize_url
           ),
         transport: transport,
         request_opts: request_opts
       }}
    end
  end

  defp required_run_id(metadata) do
    case metadata_value(metadata, :run_id, nil) do
      run_id when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      _ -> {:error, :missing_run_id}
    end
  end

  defp ensure_card_ref(cfg, target, message, run_id) do
    case StreamSessionStore.get(run_id) do
      {:ok, data} ->
        {:ok, data}

      :error ->
        create_card(cfg, target, message, run_id)
    end
  end

  defp create_card(cfg, target, message, run_id) do
    with {:ok, access_token} <- fetch_app_access_token(cfg),
         {:ok, user_ids} <- resolve_user_ids(target, message),
         {:ok, body} <- build_create_body(cfg, user_ids, message),
         {:ok, card_instance_id} <-
           do_post_and_extract_card_id(cfg, cfg.card_create_url, access_token, body) do
      ref = %{
        card_instance_id: card_instance_id,
        target: target,
        channel: "dingtalk",
        accumulated_text: "",
        updated_at_ms: System.monotonic_time(:millisecond)
      }

      :ok = StreamSessionStore.put(run_id, ref)

      Logger.info("dingtalk_card_egress.card_create",
        run_id: run_id,
        request_id: metadata_value(message.metadata, :request_id, nil),
        card_instance_id: card_instance_id
      )

      {:ok, ref}
    end
  end

  defp append_delta(cfg, card_ref, message, run_id) do
    delta_text = extract_text(message)
    next_text = to_string(Map.get(card_ref, :accumulated_text, "")) <> delta_text

    with {:ok, access_token} <- fetch_app_access_token(cfg),
         {:ok, body} <-
           build_append_body(card_ref.card_instance_id, delta_text, next_text, message),
         :ok <- do_request(cfg, :put, cfg.card_append_url, access_token, body) do
      :ok =
        StreamSessionStore.put(
          run_id,
          card_ref
          |> Map.put(:updated_at_ms, System.monotonic_time(:millisecond))
          |> Map.put(:accumulated_text, next_text)
        )

      Logger.info("dingtalk_card_egress.card_append",
        run_id: run_id,
        request_id: metadata_value(message.metadata, :request_id, nil),
        card_instance_id: card_ref.card_instance_id
      )

      :ok
    end
  end

  defp finalize_card(cfg, card_ref, message, run_id) do
    with {:ok, access_token} <- fetch_app_access_token(cfg),
         {:ok, body} <-
           build_finalize_body(
             card_ref.card_instance_id,
             message,
             to_string(Map.get(card_ref, :accumulated_text, ""))
           ),
         :ok <- do_request(cfg, :put, cfg.card_finalize_url, access_token, body) do
      Logger.info("dingtalk_card_egress.card_finalize",
        run_id: run_id,
        request_id: metadata_value(message.metadata, :request_id, nil),
        card_instance_id: card_ref.card_instance_id
      )

      :ok
    end
  end

  defp build_create_body(cfg, user_ids, message) do
    meta = card_meta(message.metadata)
    primary_user_id = List.first(user_ids)
    search_support = build_search_support(cfg)

    Jason.encode(%{
      "robotCode" => cfg.robot_code,
      "userId" => primary_user_id,
      "userIds" => user_ids,
      "cardTemplateId" => cfg.card_template_id,
      "outTrackId" => meta["runId"],
      "callbackType" => "STREAM",
      "openSpaceId" => "dtv1.card//im_robot.#{primary_user_id}",
      "userIdType" => 1,
      "imRobotOpenDeliverModel" => %{
        "spaceType" => "IM_ROBOT",
        "robotCode" => cfg.robot_code
      },
      "imRobotOpenSpaceModel" =>
        %{
          "supportForward" => true,
          "lastMessageI18n" => %{"ZH_CN" => cfg.last_message}
        }
        |> maybe_put_search_support(search_support),
      "cardData" => %{
        "stream" => %{
          "text" => "",
          "status" => "streaming",
          "updatedAt" => meta["updatedAt"]
        },
        "status" => status_block(message.metadata, "streaming"),
        "meta" => meta
      }
    })
  end

  defp build_append_body(card_instance_id, _delta_text, full_text, %EventMessage{} = message) do
    Jason.encode(%{
      "outTrackId" => card_instance_id,
      "guid" => metadata_value(message.metadata, :request_id, "men-stream"),
      "key" => "content",
      "content" => full_text,
      "isFull" => false,
      "isFinalize" => false
    })
  end

  defp build_finalize_body(card_instance_id, %FinalMessage{} = message, accumulated_text) do
    final_text =
      case String.trim(message.content || "") do
        "" -> accumulated_text
        text -> text
      end

    Jason.encode(%{
      "outTrackId" => card_instance_id,
      "guid" => metadata_value(message.metadata, :request_id, "men-final"),
      "key" => "content",
      "content" => final_text,
      "isFull" => true,
      "isFinalize" => true
    })
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

  defp do_post_and_extract_card_id(cfg, url, access_token, body) do
    with {:ok, resp_body} <- do_request_raw(cfg, :post, url, access_token, body),
         {:ok, card_instance_id} <- extract_card_instance_id(resp_body) do
      {:ok, card_instance_id}
    end
  end

  defp do_request(cfg, method, url, access_token, body) do
    case do_request_raw(cfg, method, url, access_token, body) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_request_raw(cfg, method, url, access_token, body) do
    headers = [
      {"content-type", "application/json"},
      {"x-acs-dingtalk-access-token", access_token}
    ]

    case cfg.transport.request(method, url, headers, body, cfg.request_opts) do
      {:ok, %{status: status, body: body_resp}} when status in 200..299 ->
        case body_resp do
          %{"errcode" => errcode, "errmsg" => errmsg} when errcode not in [0, nil] ->
            {:error, {:dingtalk_error, errcode, errmsg}}

          _ ->
            {:ok, body_resp}
        end

      {:ok, %{status: status, body: body_resp}} ->
        {:error, {:http_status, status, body_resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_card_instance_id(%{"cardInstanceId" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp extract_card_instance_id(%{"card_instance_id" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp extract_card_instance_id(%{"instanceId" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  # createAndDeliver 场景下，钉钉可能只回 outTrackId 到 result 字段。
  defp extract_card_instance_id(%{"result" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp extract_card_instance_id(%{"result" => %{"outTrackId" => id} = result})
       when is_binary(id) and id != "" do
    with :ok <- ensure_deliver_results_success(result) do
      {:ok, id}
    end
  end

  defp extract_card_instance_id(%{"result" => %{"out_track_id" => id}})
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp extract_card_instance_id(_), do: {:error, :missing_card_instance_id}

  defp ensure_deliver_results_success(%{"deliverResults" => results}) when is_list(results) do
    case Enum.find(results, fn item -> map_value(item, :success, true) == false end) do
      nil ->
        :ok

      failed_item ->
        {:error,
         {:deliver_failed,
          %{
            space_id: map_value(failed_item, :spaceId, map_value(failed_item, :space_id, nil)),
            message: map_value(failed_item, :errorMsg, map_value(failed_item, :error_msg, nil))
          }}}
    end
  end

  defp ensure_deliver_results_success(_), do: :ok

  defp resolve_user_ids(target, %FinalMessage{} = message),
    do: do_resolve_user_ids(target, message.session_key)

  defp resolve_user_ids(target, %EventMessage{} = message),
    do: do_resolve_user_ids(target, metadata_value(message.metadata, :session_key, nil))

  defp do_resolve_user_ids(target, session_key_fallback) do
    ids =
      [extract_user_ids(target), extract_user_ids(session_key_fallback)]
      |> List.flatten()
      |> Enum.uniq()

    case ids do
      [] -> {:error, :missing_user_id}
      list -> {:ok, list}
    end
  end

  defp extract_user_ids(%{} = target) do
    [
      Map.get(target, :user_ids) || Map.get(target, "user_ids"),
      Map.get(target, :user_id) || Map.get(target, "user_id"),
      Map.get(target, :session_key) || Map.get(target, "session_key")
    ]
    |> Enum.flat_map(&extract_user_ids/1)
    |> Enum.uniq()
  end

  defp extract_user_ids("dingtalk:" <> rest), do: extract_user_ids(rest)

  defp extract_user_ids(ids) when is_binary(ids) do
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

  defp extract_user_ids(ids) when is_list(ids), do: Enum.flat_map(ids, &extract_user_ids/1)
  defp extract_user_ids(_), do: []

  defp extract_text(%EventMessage{payload: payload}) when is_map(payload) do
    Map.get(payload, :text, Map.get(payload, "text", ""))
  end

  defp extract_text(%FinalMessage{content: content}) when is_binary(content), do: content
  defp extract_text(_), do: ""

  defp card_meta(metadata) do
    %{
      "runId" => metadata_value(metadata, :run_id, ""),
      "requestId" => metadata_value(metadata, :request_id, ""),
      "sessionKey" => metadata_value(metadata, :session_key, ""),
      "updatedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp status_block(metadata, phase) do
    %{
      "phase" => phase,
      "tool" => metadata_value(metadata, :tool_name, "idle"),
      "rate" => metadata_value(metadata, :rate_used_pct, "unknown"),
      "updatedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp build_search_support(cfg) do
    desc = cfg.search_desc
    icon = cfg.search_icon

    if is_binary(desc) and desc != "" do
      base = %{"searchDesc" => desc}
      if is_binary(icon) and icon != "", do: Map.put(base, "searchIcon", icon), else: base
    else
      nil
    end
  end

  defp maybe_put_search_support(space_model, nil), do: space_model

  defp maybe_put_search_support(space_model, search_support),
    do: Map.put(space_model, "searchSupport", search_support)

  defp fallback_send(target, message) do
    fallback_adapter =
      Application.get_env(:men, __MODULE__, [])
      |> Keyword.get(:fallback_adapter, Men.Channels.Egress.DingtalkRobotAdapter)

    fallback_adapter.send(target, message)
  end

  defp required_binary(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_, reason), do: {:error, reason}

  defp metadata_value(metadata, key, default) when is_map(metadata),
    do: Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))

  defp metadata_value(_metadata, _key, default), do: default

  defp map_value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp map_value(_map, _key, default), do: default

  defp cfg_value(app_cfg, key, env), do: Keyword.get(app_cfg, key) || System.get_env(env)

  defp cfg_value(app_cfg, key, env, default),
    do: Keyword.get(app_cfg, key) || System.get_env(env) || default

  defp append_query(url, extra_query) do
    uri = URI.parse(url)
    current = URI.decode_query(uri.query || "")
    merged = Map.merge(current, URI.decode_query(extra_query))
    %{uri | query: URI.encode_query(merged)} |> URI.to_string()
  end
end
