defmodule Angler.Pipeline.FeedbackTest do
  # Unique chats keep the application's shared rate limiter from spacing out tests.
  use ExUnit.Case, async: true

  import Angler.TelegramFixtures

  alias Angler.Entries.Entry
  alias Angler.Pipeline.Feedback
  alias Angler.Settings.Setting
  alias Angler.Telegram.RateLimiter

  @timeout 3_000

  setup do
    stub_bot_api()
    chat_id = unique_id()

    entry = %Entry{
      id: Ecto.UUID.generate(),
      chat_id: chat_id,
      chat_type: "private",
      message_id: unique_id()
    }

    %{entry: entry, settings: %Setting{reactions_enabled: true, failure_replies: :none}}
  end

  test "started/2 reacts 👀", %{entry: entry, settings: settings} do
    assert Feedback.started(entry, settings) == :ok

    assert_receive {:bot_api, "setMessageReaction",
                    %{"message_id" => message_id, "reaction" => [%{"emoji" => "👀"}]}},
                   @timeout

    assert message_id == entry.message_id
  end

  test "started/2 drops the 👀 while the chat is held back, so it can't land after the 👎",
       %{entry: entry, settings: settings} do
    # E.g. after a 429 on a video sent to the chat.
    RateLimiter.backoff(entry.chat_id, 1)
    _state = :sys.get_state(RateLimiter)

    assert Feedback.started(entry, settings) == :ok
    # The entry fails quickly, while the chat is still held back.
    assert Feedback.failed(entry, :unsupported, settings) == :ok

    assert_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👎"}]}},
                   @timeout

    refute_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👀"}]}}, 500
  end
end
