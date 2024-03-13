defmodule Angler.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Angler.Finch},
      setup_telegram()
    ]

    opts = [strategy: :one_for_one, name: Angler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp setup_telegram do
    bots = [
      {Angler.Bot,
       [
         token: Application.fetch_env!(:angler, :token),
         max_bot_concurrency: Application.fetch_env!(:angler, :max_bot_concurrency)
       ]}
    ]

    case Mix.env() do
      :prod ->
        {Telegram.Webhook,
         config: [
           host: Application.fetch_env!(:angler, :host),
           local_port: Application.fetch_env!(:angler, :local_port)
         ],
         bots: bots}

      :dev ->
        {Telegram.Poller, bots: bots}
    end
  end
end
