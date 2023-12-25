import Config

config :angler,
  token: System.fetch_env!("BOT_TOKEN"),
  max_bot_concurrency: System.get_env("BOT_MAX_CONCURRENTCY", "1000") |> String.to_integer(),
  host: "#{System.fetch_env!("APP_NAME")}.gigalixirapp.com",
  local_port: System.get_env("PORT", "4000") |> String.to_integer(),
  tiktok_user_agent: System.fetch_env!("TIKTOK_USER_AGENT"),
  tiktok_feed_url: System.fetch_env!("TIKTOK_FEED_URL")
