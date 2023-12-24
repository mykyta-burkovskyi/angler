defmodule Angler.Bot do
  alias Angler.Angles
  alias Angler.UrlExtractor
  use Telegram.Bot

  @impl Telegram.Bot
  def handle_update(
        %{
          "message" => %{
            "entities" => message_entities,
            "text" => message_text,
            "chat" => %{"id" => chat_id},
            "message_id" => message_id
          }
        },
        token
      ) do
    Logger.info("Got message from chat #{chat_id} with text #{message_text}")

    message_entities
    |> UrlExtractor.extract(message_text)
    |> Task.async_stream(
      fn message_url ->
        video_url = Angles.Tiktok.fish_out(message_url)

        Telegram.Api.request(token, "sendVideo",
          chat_id: chat_id,
          reply_to_message_id: message_id,
          video: video_url
        )
      end,
      timeout: 5 * 60_000
    )
    |> Stream.run()
  end

  def handle_update(_update, _token) do
    :ok
  end
end
