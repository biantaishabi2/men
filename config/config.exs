# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :men,
  ecto_repos: [Men.Repo],
  generators: [timestamp_type: :utc_datetime]

config :men, Men.Gateway.DispatchServer,
  bridge_adapter: Men.RuntimeBridge.GongCLI,
  egress_adapter: Men.Gateway.DispatchServer.NoopEgress,
  storage_adapter: :memory

config :men, Men.Channels.Ingress.FeishuAdapter,
  signing_secret: System.get_env("FEISHU_SIGNING_SECRET"),
  sign_mode: :strict,
  replay_backend: Men.Channels.Ingress.FeishuAdapter.ReplayBackend.ETS,
  bots: %{}

config :men, Men.Channels.Ingress.DingtalkAdapter,
  secret: System.get_env("DINGTALK_WEBHOOK_SECRET"),
  signature_window_seconds: String.to_integer(System.get_env("DINGTALK_SIGNATURE_WINDOW_SECONDS") || "300")

config :men, Men.Channels.Egress.FeishuAdapter,
  base_url: "https://open.feishu.cn",
  bot_access_token: System.get_env("FEISHU_BOT_ACCESS_TOKEN"),
  bots: %{}

config :men, Men.Channels.Egress.DingtalkAdapter,
  webhook_url: System.get_env("DINGTALK_EGRESS_WEBHOOK_URL")

config :men, :runtime_bridge,
  timeout_ms: String.to_integer(System.get_env("RUNTIME_BRIDGE_TIMEOUT_MS") || "30000")

config :men, :gateway_log_fields, [:request_id, :session_key, :run_id, :channel, :event_type, :stage]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :session_key, :run_id, :channel, :event_type, :stage]

# Configures the endpoint
config :men, MenWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MenWeb.ErrorHTML, json: MenWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Men.PubSub,
  live_view: [signing_salt: "90va5aKS"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :men, Men.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  men: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  men: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
