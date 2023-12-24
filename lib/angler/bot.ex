defmodule Angler.Bot do
  use Telegram.Bot

  @impl Telegram.Bot
  def handle_update(
        %{
          "message" => %{
            "text" => "/hello",
            "chat" => %{"id" => chat_id, "username" => username},
            "message_id" => message_id
          }
        },
        token
      ) do
    Telegram.Api.request(token, "sendMessage",
      chat_id: chat_id,
      reply_to_message_id: message_id,
      text: "Hello #{username}!"
    )
  end

  def handle_update(_update, _token) do
    :ok
  end
end
