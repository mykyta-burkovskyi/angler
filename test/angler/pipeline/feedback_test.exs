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

  test "failure_text/2 doesn't assume the link was a video" do
    settings = %Setting{upload_limit_mb: 20}

    assert Feedback.failure_text(:unsupported, settings) ==
             "I couldn't find anything to send at this link."

    assert Feedback.failure_text(:unavailable, settings) ==
             "This post is private, removed or unavailable."

    assert Feedback.failure_text(:too_large, settings) ==
             "This is too large or too long to send here (the limit is 20 MB)."

    assert Feedback.failure_text(:timeout, settings) == "Downloading this took too long."

    for kind <- [:transient, :internal, :telegram] do
      assert Feedback.failure_text(kind, settings) == "Something went wrong while fetching this."
    end
  end

  test "partial/4 reacts 👎 and replies how much of an album was sent",
       %{entry: entry, settings: settings} do
    assert Feedback.partial(entry, 10, 14, %{settings | failure_replies: :all}) == :ok

    assert_receive {:bot_api, "sendMessage", params}, @timeout
    assert params["text"] == "Only 10 of 14 items could be sent."
    assert params["reply_parameters"]["message_id"] == entry.message_id

    assert_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👎"}]}},
                   @timeout
  end

  test "uploading/2 shows the chat action, but not in channels", %{entry: entry} do
    assert Feedback.uploading(entry, "upload_photo") == :ok
    assert_receive {:bot_api, "sendChatAction", %{"action" => "upload_photo"}}, @timeout

    assert Feedback.uploading(%{entry | chat_type: "channel"}, "upload_photo") == :ok
    refute_receive {:bot_api, "sendChatAction", _params}, 200
  end

  describe "follow_up/3" do
    test "sends the text as a quiet reply to the delivered media", %{entry: entry} do
      entry = %{entry | message_thread_id: 7}
      assert Feedback.follow_up(entry, "The whole post text", 123) == :ok

      assert_receive {:bot_api, "sendMessage", params}, @timeout

      assert %{
               "text" => "The whole post text",
               "message_thread_id" => 7,
               "disable_notification" => true,
               "link_preview_options" => %{"is_disabled" => true},
               "reply_parameters" => %{"message_id" => 123}
             } = params

      refute Map.has_key?(params, "parse_mode")
    end

    test "replies to the original message when the media's message is unknown",
         %{entry: entry} do
      Feedback.follow_up(entry, "Text", nil)

      assert_receive {:bot_api, "sendMessage", params}, @timeout
      assert params["reply_parameters"]["message_id"] == entry.message_id
    end

    test "is sent without replying when the message to reply to is gone", %{entry: entry} do
      stub_bot_api(%{
        "sendMessage" => fn conn ->
          if conn.body_params["reply_parameters"] do
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(api_error(400, "Bad Request: message to be replied not found"))
          else
            Req.Test.json(conn, api_ok(%{"message_id" => 1}))
          end
        end
      })

      Feedback.follow_up(entry, "Text", 123)

      assert_receive {:bot_api, "sendMessage", %{"reply_parameters" => _reply}}, @timeout
      assert_receive {:bot_api, "sendMessage", params}, @timeout
      refute Map.has_key?(params, "reply_parameters")
      assert params["text"] == "Text"
    end
  end
end
