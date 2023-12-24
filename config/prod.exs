import Config

config :angler,
  host: "#{System.fetch_env!("APP_NAME")}.gigalixirapp.com",
  local_port: System.get_env("PORT", "4000") |> String.to_integer()

config :logger, level: :info
