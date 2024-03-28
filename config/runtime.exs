import Config

config :angler,
  token: System.fetch_env!("BOT_TOKEN"),
  max_bot_concurrency: System.get_env("BOT_MAX_CONCURRENTCY", "1000") |> String.to_integer(),
  host: "#{System.fetch_env!("APP_NAME")}.gigalixirapp.com",
  local_port: System.get_env("PORT", "4000") |> String.to_integer(),
