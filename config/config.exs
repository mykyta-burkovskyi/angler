import Config

config :logger, :console, metadata: [:bot, :chat_id]
config :tesla, :adapter, {Tesla.Adapter.Hackney, [recv_timeout: 40_000]}
config :telegram, :webserver, Telegram.WebServer.Bandit

import_config "#{config_env()}.exs"
