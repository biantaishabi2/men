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

config :men, :runtime_bridge,
  # 支持仅通过配置切换 bridge 实现，不做运行时动态开关。
  bridge_impl: runtime_bridge_impl,
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

default_gateway_policy =
  case System.get_env("GATEWAY_BOOTSTRAP_POLICY_JSON") do
    nil ->
      %{
        "acl" => %{
          "main" => %{
            "read" => ["global.", "agent.", "shared.", "inbox."],
            "write" => ["global.control.", "inbox."]
          },
          "child" => %{
            "read" => ["agent.$agent_id.", "shared.evidence.agent.$agent_id.", "inbox."],
            "write" => ["agent.$agent_id.", "shared.evidence.agent.$agent_id.", "inbox."]
          },
          "tool" => %{
            "read" => ["agent.$agent_id.", "shared.evidence.agent.$agent_id.", "inbox."],
            "write" => ["inbox."]
          },
          "system" => %{"read" => [""], "write" => [""]}
        },
        "wake" => %{
          "must_wake" => ["agent_result", "agent_error", "policy_changed"],
          "inbox_only" => ["heartbeat", "tool_progress", "telemetry"]
        },
        "dedup_ttl_ms" => 60_000,
        "version" => 0,
        "policy_version" => "fallback"
      }

    raw ->
      case Jason.decode(raw) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end
  end

config :men, :ops_policy,
  cache_ttl_ms: parse_positive_integer_env.("OPS_POLICY_CACHE_TTL_MS", 60_000),
  reconcile_interval_ms: parse_positive_integer_env.("OPS_POLICY_RECONCILE_INTERVAL_MS", 30_000),
  reconcile_jitter_ms: parse_non_negative_integer_env.("OPS_POLICY_RECONCILE_JITTER_MS", 5_000),
  reconcile_failure_threshold:
    parse_positive_integer_env.("OPS_POLICY_RECONCILE_FAILURE_THRESHOLD", 3),
  telemetry_enabled: parse_boolean_env.("OPS_POLICY_TELEMETRY_ENABLED", true),
  default_policies: %{
    {"default", "prod", "gateway", "gateway_runtime"} => default_gateway_policy
  }

config :men, Men.Gateway.OpsPolicyProvider,
  cache_ttl_ms: parse_positive_integer_env.("GATEWAY_POLICY_CACHE_TTL_MS", 300_000),
  bootstrap_policy: default_gateway_policy

config :men, Men.Gateway.DispatchServer,
  agent_loop_enabled: parse_boolean_env.("GATEWAY_AGENT_LOOP_ENABLED", true),
  prompt_frame_injection_enabled:
    parse_boolean_env.("GATEWAY_PROMPT_FRAME_INJECTION_ENABLED", false),
  frame_budget_tokens: parse_positive_integer_env.("GATEWAY_FRAME_BUDGET_TOKENS", 16_000),
  frame_budget_messages: parse_positive_integer_env.("GATEWAY_FRAME_BUDGET_MESSAGES", 20),
  receipt_recent_limit: parse_positive_integer_env.("GATEWAY_RECEIPT_RECENT_LIMIT", 20),
  event_bus_topic: System.get_env("GATEWAY_EVENT_BUS_TOPIC") || "gateway_events"

# 钉钉机器人回发配置（生产可直接由环境变量驱动）。
dingtalk_webhook_url = System.get_env("DINGTALK_ROBOT_WEBHOOK_URL")

if is_binary(dingtalk_webhook_url) and dingtalk_webhook_url != "" do
  config :men, Men.Channels.Egress.DingtalkRobotAdapter,
    webhook_url: dingtalk_webhook_url,
    secret: System.get_env("DINGTALK_ROBOT_SECRET"),
    sign_enabled: System.get_env("DINGTALK_ROBOT_SIGN_ENABLED") in ~w(true TRUE 1)
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
