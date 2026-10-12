import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :angler, Angler.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "angler_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :angler, AnglerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NiTBDbQ/aRBfNxNaxy3AIfZnq3HbtME3YbFj5qI/ZqbsTF0KP9pqOGrwX/7WNqCf",
  server: false

config :angler, Angler.Telegram,
  token: "123456:TEST-TOKEN",
  mode: :disabled,
  webhook_secret: "test-webhook-secret",
  req_options: [plug: {Req.Test, Angler.Telegram}, retry: false]

config :angler, Angler.Media, data_dir: Path.expand("../tmp/test-data", __DIR__)

# Every test shares the application's rate limiter: keep the per-chat rules but
# don't let one test's burst of calls fill the global window for the next test.
config :angler, Angler.Telegram.RateLimiter, global_limit: 10_000

# Tests must not depend on how much free space the machine running them has.
config :angler, Angler.Storage, min_free_bytes: 0, min_free_percent: 0

config :angler, Angler.Media.TikTok,
  req_options: [plug: {Req.Test, Angler.Media.TikTok}],
  retry_delays: [0, 0]

config :angler, Angler.Media.Instagram,
  req_options: [plug: {Req.Test, Angler.Media.Instagram}],
  retry_delays: [0, 0]

config :angler, Angler.Media.Threads,
  req_options: [plug: {Req.Test, Angler.Media.Threads}],
  retry_delays: [0, 0]

# Tests start pipelines and the storage janitor explicitly
config :angler, Angler.Pipeline, enabled: false
config :angler, Angler.Storage.Janitor, enabled: false

config :angler, AnglerWeb.DashboardAuth, username: "admin", password: "test-password"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
