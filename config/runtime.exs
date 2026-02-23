import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

runtime_bridge_impl =
  case System.get_env("RUNTIME_BRIDGE_IMPL") do
    "mock" -> Men.RuntimeBridge.Mock
    "gong_rpc" -> Men.RuntimeBridge.GongRPC
    "zcpg_rpc" -> Men.RuntimeBridge.ZcpgRPC
    _ -> Men.RuntimeBridge.GongCLI
  end

parse_positive_integer_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} when parsed > 0 -> parsed
        _ -> default
      end
  end
end

parse_non_negative_integer_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} when parsed >= 0 -> parsed
        _ -> default
      end
  end
end

parse_boolean_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] ->
      true

    value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] ->
      false

    _ ->
      default
  end
end

parse_string_list_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end
end

parse_invalidation_codes_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      parsed =
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.downcase/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn
          "runtime_session_not_found" -> :runtime_session_not_found
          code -> code
        end)

      if parsed == [], do: default, else: parsed
  end
end

parse_module_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      case String.downcase(String.trim(value)) do
        "ets" -> Men.Channels.Ingress.QiweiIdempotency.Backend.ETS
        "redis" -> Men.Channels.Ingress.QiweiIdempotency.Backend.Redis
        _ -> default
      end
  end
end

config :men, :runtime_bridge,
  # 支持仅通过配置切换 bridge 实现，不做运行时动态开关。
  bridge_impl: runtime_bridge_impl,
  command: System.get_env("RUNTIME_BRIDGE_COMMAND"),
  timeout_ms: parse_positive_integer_env.("RUNTIME_BRIDGE_TIMEOUT_MS", 30_000),
  max_concurrency: parse_positive_integer_env.("RUNTIME_BRIDGE_MAX_CONCURRENCY", 10),
  backpressure_strategy: :reject

config :men, Men.Gateway.SessionCoordinator,
  enabled: parse_boolean_env.("GATEWAY_SESSION_COORDINATOR_ENABLED", true),
  ttl_ms: parse_positive_integer_env.("GATEWAY_SESSION_COORDINATOR_TTL_MS", 300_000),
  gc_interval_ms:
    parse_positive_integer_env.("GATEWAY_SESSION_COORDINATOR_GC_INTERVAL_MS", 60_000),
  max_entries: parse_positive_integer_env.("GATEWAY_SESSION_COORDINATOR_MAX_ENTRIES", 10_000),
  invalidation_codes:
    parse_invalidation_codes_env.(
      "GATEWAY_SESSION_COORDINATOR_INVALIDATION_CODES",
      [:runtime_session_not_found]
    )

config :men, Men.Gateway.DispatchServer, bridge_adapter: runtime_bridge_impl

config :men, :zcpg_cutover,
  enabled:
    parse_boolean_env.(
      "QIWEI_CUTOVER_ENABLED",
      parse_boolean_env.("ZCPG_CUTOVER_ENABLED", false)
    ),
  tenant_whitelist:
    parse_string_list_env.(
      "QIWEI_CUTOVER_TENANT_WHITELIST",
      parse_string_list_env.("ZCPG_CUTOVER_TENANT_WHITELIST", [])
    ),
  env_override: parse_boolean_env.("ZCPG_CUTOVER_ENV_OVERRIDE", false),
  timeout_ms:
    parse_positive_integer_env.(
      "QIWEI_CALLBACK_TIMEOUT_MS",
      parse_positive_integer_env.("ZCPG_CUTOVER_TIMEOUT_MS", 8_000)
    ),
  breaker: [
    failure_threshold: parse_positive_integer_env.("ZCPG_CUTOVER_BREAKER_FAILURE_THRESHOLD", 5),
    window_seconds: parse_positive_integer_env.("ZCPG_CUTOVER_BREAKER_WINDOW_SECONDS", 30),
    cooldown_seconds: parse_positive_integer_env.("ZCPG_CUTOVER_BREAKER_COOLDOWN_SECONDS", 60)
  ]

config :men, MenWeb.Webhooks.QiweiController,
  callback_enabled: parse_boolean_env.("QIWEI_CALLBACK_ENABLED", false),
  token: System.get_env("QIWEI_CALLBACK_TOKEN"),
  encoding_aes_key: System.get_env("QIWEI_CALLBACK_ENCODING_AES_KEY"),
  receive_id: System.get_env("QIWEI_RECEIVE_ID"),
  bot_name: System.get_env("QIWEI_BOT_NAME"),
  bot_user_id: System.get_env("QIWEI_BOT_USER_ID"),
  reply_require_mention: parse_boolean_env.("QIWEI_REPLY_REQUIRE_MENTION", true),
  idempotency_ttl_seconds: parse_positive_integer_env.("QIWEI_IDEMPOTENCY_TTL_SECONDS", 120),
  idempotency_backend:
    parse_module_env.(
      "QIWEI_IDEMPOTENCY_BACKEND",
      Men.Channels.Ingress.QiweiIdempotency.Backend.Redis
    )

config :men, Men.Channels.Ingress.QiweiIdempotency.Backend.Redis,
  url: System.get_env("QIWEI_IDEMPOTENCY_REDIS_URL") || System.get_env("REDIS_URL"),
  host: System.get_env("QIWEI_IDEMPOTENCY_REDIS_HOST") || "127.0.0.1",
  port: parse_positive_integer_env.("QIWEI_IDEMPOTENCY_REDIS_PORT", 6379),
  password: System.get_env("QIWEI_IDEMPOTENCY_REDIS_PASSWORD"),
  database: parse_non_negative_integer_env.("QIWEI_IDEMPOTENCY_REDIS_DB", 0),
  timeout_ms: parse_positive_integer_env.("QIWEI_IDEMPOTENCY_REDIS_TIMEOUT_MS", 1_000)

gong_rpc_node_start_type =
  case System.get_env("GONG_RPC_NODE_START_TYPE") do
    "shortnames" -> :shortnames
    _ -> :longnames
  end

config :men, Men.RuntimeBridge.GongRPC,
  gong_node: System.get_env("GONG_RPC_NODE"),
  local_node: System.get_env("GONG_RPC_LOCAL_NODE"),
  node_start_type: gong_rpc_node_start_type,
  cookie: System.get_env("GONG_RPC_COOKIE"),
  rpc_timeout_ms: parse_positive_integer_env.("GONG_RPC_TIMEOUT_MS", 30_000),
  completion_timeout_ms: parse_positive_integer_env.("GONG_RPC_COMPLETION_TIMEOUT_MS", 60_000),
  model: System.get_env("GONG_RPC_MODEL") || "deepseek:deepseek-chat"

config :men, Men.RuntimeBridge.ZcpgRPC,
  base_url: System.get_env("ZCPG_RPC_BASE_URL") || "http://127.0.0.1:4015",
  path: System.get_env("ZCPG_RPC_PATH") || "/v1/runtime/bridge/prompt",
  token: System.get_env("ZCPG_RPC_TOKEN"),
  timeout: parse_positive_integer_env.("ZCPG_RPC_TIMEOUT_MS", 30_000)

# 钉钉机器人回发配置（支持 webhook 与 app_robot 两种模式）。
dingtalk_mode =
  case System.get_env("DINGTALK_ROBOT_MODE") do
    "app_robot" -> :app_robot
    "webhook" -> :webhook
    _ -> nil
  end

dingtalk_webhook_url = System.get_env("DINGTALK_ROBOT_WEBHOOK_URL")
dingtalk_robot_code = System.get_env("DINGTALK_ROBOT_CODE")
dingtalk_app_key = System.get_env("DINGTALK_APP_KEY")
dingtalk_app_secret = System.get_env("DINGTALK_APP_SECRET")

dingtalk_has_webhook = is_binary(dingtalk_webhook_url) and dingtalk_webhook_url != ""
dingtalk_has_app = is_binary(dingtalk_robot_code) and dingtalk_robot_code != ""

if dingtalk_has_webhook or dingtalk_has_app do
  config :men, Men.Channels.Egress.DingtalkRobotAdapter,
    mode: dingtalk_mode,
    webhook_url: dingtalk_webhook_url,
    secret: System.get_env("DINGTALK_ROBOT_SECRET"),
    sign_enabled: System.get_env("DINGTALK_ROBOT_SIGN_ENABLED") in ~w(true TRUE 1),
    msg_key: System.get_env("DINGTALK_ROBOT_MSG_KEY"),
    markdown_title: System.get_env("DINGTALK_ROBOT_MARKDOWN_TITLE"),
    robot_code: dingtalk_robot_code,
    app_key: dingtalk_app_key,
    app_secret: dingtalk_app_secret,
    token_url: System.get_env("DINGTALK_TOKEN_URL"),
    app_send_url: System.get_env("DINGTALK_ROBOT_OTO_SEND_URL")

  config :men, Men.Channels.Egress.DingtalkCardAdapter,
    enabled: System.get_env("DINGTALK_CARD_STREAM_ENABLED") in ~w(true TRUE 1),
    robot_code: dingtalk_robot_code,
    app_key: dingtalk_app_key,
    app_secret: dingtalk_app_secret,
    last_message: System.get_env("DINGTALK_CARD_LAST_MESSAGE"),
    search_icon: System.get_env("DINGTALK_CARD_SEARCH_ICON"),
    search_desc: System.get_env("DINGTALK_CARD_SEARCH_DESC"),
    token_url: System.get_env("DINGTALK_TOKEN_URL"),
    card_template_id: System.get_env("DINGTALK_CARD_TEMPLATE_ID"),
    card_create_url: System.get_env("DINGTALK_CARD_CREATE_URL"),
    card_append_url: System.get_env("DINGTALK_CARD_APPEND_URL"),
    card_finalize_url: System.get_env("DINGTALK_CARD_FINALIZE_URL")
end

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/men start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :men, MenWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :men, Men.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :men, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :men, MenWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :men, MenWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :men, MenWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :men, Men.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
