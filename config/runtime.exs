import Config

config :angler,
  token: System.fetch_env!("BOT_TOKEN"),
  max_bot_concurrency: System.get_env("BOT_MAX_CONCURRENTCY", "1000") |> String.to_integer()
