import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
db_pool_size =
  case System.get_env("DB_POOL_SIZE") do
    nil ->
      20

    value ->
      case Integer.parse(value) do
        {size, _} when size > 0 -> size
        _ -> 20
      end
  end

config :men, Men.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "men_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: db_pool_size

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :men, MenWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "fHt0Wsony+FvojvZw0er6kqUt4d3QMacrLCGCs+OJ/Lq0zUumpvDpUN8JT3bf7dn",
  server: false

# In test we don't send emails
config :men, Men.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :men, :ops_policy, sync_enabled: false
