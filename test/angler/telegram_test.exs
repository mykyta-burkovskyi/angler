defmodule Angler.TelegramTest do
  use ExUnit.Case, async: true

  import Angler.TelegramFixtures

  alias Angler.Telegram
  alias Angler.Telegram.Error

  @token "123456:TEST-TOKEN"

  # Unique chats keep the shared rate limiter from spacing out tests.
  setup do
    %{chat_id: unique_id()}
  end

  describe "request/3" do
    test "posts JSON to /bot<token>/<method> and returns the result" do
      test = self()

      Req.Test.stub(Angler.Telegram, fn conn ->
        send(test, {:request, conn.method, conn.request_path, conn.body_params})
        Req.Test.json(conn, api_ok(%{"id" => 42, "username" => "angler_bot"}))
      end)

      assert Telegram.request("getChat", %{chat_id: 7, unused: nil}) ==
               {:ok, %{"id" => 42, "username" => "angler_bot"}}

      assert_received {:request, "POST", "/bot" <> @token <> "/getChat",
                       %{"chat_id" => 7} = params}

      refute Map.has_key?(params, "unused")
    end

    test "maps Telegram errors, including their parameters" do
      stub_bot_api(%{
        "sendMessage" =>
          {:error, 400, "Bad Request: group chat was upgraded to a supergroup chat",
           %{"migrate_to_chat_id" => -1_001_234}}
      })

      assert {:error, %Error{} = error} =
               Telegram.request("sendMessage", %{chat_id: -5, text: "hi"})

      assert error.method == "sendMessage"
      assert error.code == 400
      assert error.migrate_to_chat_id == -1_001_234
      assert Error.kind(error) == :chat_migrated
      refute Error.transient?(error)

      assert Exception.message(error) ==
               "Telegram sendMessage failed (400): Bad Request: group chat was upgraded to a supergroup chat"
    end

    test "prefers parameters.retry_after and falls back to the Retry-After header" do
      Req.Test.stub(Angler.Telegram, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "9")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(
          api_error(429, "Too Many Requests: retry after 7", %{"retry_after" => 7})
        )
      end)

      assert {:error, %Error{code: 429, retry_after: 7}} = Telegram.request("getMe")

      Req.Test.stub(Angler.Telegram, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "9")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(api_error(429, "Too Many Requests"))
      end)

      assert {:error, %Error{code: 429, retry_after: 9}} = Telegram.request("getMe")
    end

    test "maps HTML and empty responses to their HTTP status" do
      Req.Test.stub(Angler.Telegram, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(413, """
        <html>
        <head><title>413 Request Entity Too Large</title></head>
        <body><center><h1>413 Request Entity Too Large</h1></center></body>
        </html>
        """)
      end)

      assert {:error, %Error{code: 413, description: description} = error} =
               Telegram.request("sendVideo")

      assert description ==
               "HTTP 413: 413 Request Entity Too Large 413 Request Entity Too Large"

      assert Error.kind(error) == :too_large

      Req.Test.stub(Angler.Telegram, &Plug.Conn.send_resp(&1, 502, ""))
      assert {:error, %Error{code: 502, description: "HTTP 502"}} = Telegram.request("getMe")
    end

    test "maps transport errors" do
      Req.Test.stub(Angler.Telegram, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Error{code: nil, description: "timeout"} = error} =
               Telegram.request("getMe")

      assert %Req.TransportError{reason: :timeout} = error.reason
      assert Error.transient?(error)
      assert Error.kind(error) == :network
      refute error.request_sent
    end

    test "never exposes the bot token" do
      Req.Test.stub(Angler.Telegram, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(api_error(404, "Not Found: /bot#{@token}/nope"))
      end)

      assert {:error, %Error{description: description}} = Telegram.request("nope")
      assert description == "Not Found: /bot<token>/nope"

      Req.Test.stub(Angler.Telegram, &Plug.Conn.send_resp(&1, 500, "failed: #{@token}"))

      assert {:error, %Error{description: "HTTP 500: failed: <token>"}} =
               Telegram.request("getMe")
    end
  end

  describe "webhook and update methods" do
    test "set_webhook/3 sends the webhook parameters" do
      stub_bot_api()

      assert {:ok, true} =
               Telegram.set_webhook("https://angler.example/telegram/webhook", "s3cret",
                 allowed_updates: ["message"],
                 max_connections: 10
               )

      assert_received {:bot_api, "setWebhook", params}

      assert params == %{
               "url" => "https://angler.example/telegram/webhook",
               "secret_token" => "s3cret",
               "allowed_updates" => ["message"],
               "max_connections" => 10
             }
    end

    test "delete_webhook/1, get_webhook_info/0 and get_me/0" do
      stub_bot_api(%{
        "getWebhookInfo" => %{"url" => "", "pending_update_count" => 0},
        "getMe" => %{"id" => 1, "is_bot" => true, "username" => "angler_bot"}
      })

      assert {:ok, true} = Telegram.delete_webhook(drop_pending_updates: false)
      assert_received {:bot_api, "deleteWebhook", %{"drop_pending_updates" => false}}

      assert {:ok, %{"pending_update_count" => 0}} = Telegram.get_webhook_info()
      assert {:ok, %{"username" => "angler_bot"}} = Telegram.get_me()
    end

    test "get_updates/2 sends offset, timeout and allowed updates" do
      stub_bot_api(%{"getUpdates" => [%{"update_id" => 5}]})

      assert {:ok, [%{"update_id" => 5}]} =
               Telegram.get_updates(5, timeout: 1, allowed_updates: ["message"])

      assert_received {:bot_api, "getUpdates", params}
      assert params == %{"offset" => 5, "timeout" => 1, "allowed_updates" => ["message"]}

      assert {:ok, _} = Telegram.get_updates(nil)
      assert_received {:bot_api, "getUpdates", %{"timeout" => 0} = params}
      refute Map.has_key?(params, "offset")
    end

    test "log_out_from_cloud/0 calls logOut" do
      test = self()

      Req.Test.stub(Angler.Telegram, fn conn ->
        send(test, {:logout, conn.host, conn.request_path})
        Req.Test.json(conn, api_ok(true))
      end)

      assert {:ok, true} = Telegram.log_out_from_cloud()
      assert_received {:logout, "api.telegram.org", "/bot" <> @token <> "/logOut"}
    end
  end

  describe "send_video/3" do
    @tag :tmp_dir
    test "uploads the video and thumbnail as multipart", %{chat_id: chat_id, tmp_dir: dir} do
      # CRLF and NUL bytes must survive the upload unchanged.
      video = Path.join(dir, "video.mp4")
      File.write!(video, [:crypto.strong_rand_bytes(100_000), "\r\n\r\n\0", "tail"])
      thumbnail = Path.join(dir, "thumbnail.jpg")
      File.write!(thumbnail, <<0xFF, 0xD8, 0xFF, "\r\n", 0xFF, 0xD9>>)
      test = self()
      sent = sent_video(chat_id)

      Req.Test.stub(Angler.Telegram, fn conn ->
        %{"video" => upload, "thumb" => thumb} = conn.body_params
        send(test, {:upload, conn.body_params, File.read!(upload.path), File.read!(thumb.path)})
        Req.Test.json(conn, api_ok(sent))
      end)

      assert {:ok, ^sent} =
               Telegram.send_video(chat_id, {:path, video},
                 reply_to_message_id: 77,
                 message_thread_id: 5,
                 chat_type: "private",
                 duration: 11.6,
                 width: 720,
                 height: 1280,
                 thumbnail: thumbnail
               )

      assert_received {:upload, params, video_bytes, thumb_bytes}

      assert video_bytes == File.read!(video)
      assert thumb_bytes == File.read!(thumbnail)

      assert %{
               "chat_id" => chat_id_string,
               "message_thread_id" => "5",
               "duration" => "12",
               "width" => "720",
               "height" => "1280",
               "supports_streaming" => "true",
               "thumbnail" => "attach://thumb",
               "reply_parameters" => reply_parameters,
               "video" => %Plug.Upload{filename: "video.mp4", content_type: "video/mp4"},
               "thumb" => %Plug.Upload{filename: "thumbnail.jpg", content_type: "image/jpeg"}
             } = params

      assert chat_id_string == Integer.to_string(chat_id)

      assert Jason.decode!(reply_parameters) == %{
               "message_id" => 77,
               "allow_sending_without_reply" => true
             }

      refute Map.has_key?(params, "caption")
    end

    @tag :tmp_dir
    test "skips a missing thumbnail", %{chat_id: chat_id, tmp_dir: dir} do
      video = Path.join(dir, "video.mp4")
      File.write!(video, "video")
      stub_bot_api(%{"sendVideo" => sent_video(chat_id)})

      assert {:ok, _} =
               Telegram.send_video(chat_id, {:path, video},
                 thumbnail: Path.join(dir, "missing.jpg"),
                 supports_streaming: false,
                 caption: "🎣"
               )

      assert_received {:bot_api, "sendVideo", params}

      assert %{"supports_streaming" => "false", "caption" => "🎣", "video" => %Plug.Upload{}} =
               params

      refute Map.has_key?(params, "thumbnail")
      refute Map.has_key?(params, "thumb")
      refute Map.has_key?(params, "reply_parameters")
    end

    test "fails without calling Telegram when the file is missing", %{chat_id: chat_id} do
      stub_bot_api()

      assert {:error, %Error{method: "sendVideo", reason: :enoent}} =
               Telegram.send_video(chat_id, {:path, "/nonexistent/video.mp4"})

      refute_received {:bot_api, _, _}
    end

    test "sends a file_id as JSON without the thumbnail", %{chat_id: chat_id} do
      stub_bot_api(%{"sendVideo" => sent_video(chat_id)})

      assert {:ok, _} =
               Telegram.send_video(chat_id, {:file_id, "BAAC-file"},
                 reply_to_message_id: 3,
                 thumbnail: "/tmp/thumbnail.jpg",
                 duration: 5
               )

      assert_received {:bot_api, "sendVideo", params}

      assert params == %{
               "chat_id" => chat_id,
               "video" => "BAAC-file",
               "duration" => 5,
               "supports_streaming" => true,
               "reply_parameters" => %{"message_id" => 3, "allow_sending_without_reply" => true}
             }
    end

    test "can be sent without a notification", %{chat_id: chat_id} do
      stub_bot_api(%{"sendVideo" => sent_video(chat_id)})

      assert {:ok, _} =
               Telegram.send_video(chat_id, {:file_id, "BAAC"}, disable_notification: true)

      assert_received {:bot_api, "sendVideo", %{"disable_notification" => true}}
    end
  end

  describe "send_video/3 without an answer" do
    test "is unconfirmed when the request was sent completely", %{chat_id: chat_id} do
      for reason <- [:timeout, :closed] do
        Req.Test.stub(Angler.Telegram, fn conn ->
          request_sent()
          Req.Test.transport_error(conn, reason)
        end)

        assert {:error, %Error{code: nil, request_sent: true} = error} =
                 Telegram.send_video(chat_id, {:file_id, "BAAC"})

        assert Error.kind(error) == :unconfirmed
        refute Error.transient?(error)
      end
    end

    test "is a network error when the request was not sent", %{chat_id: chat_id} do
      Req.Test.stub(Angler.Telegram, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{request_sent: false} = error} =
               Telegram.send_video(chat_id, {:file_id, "BAAC"})

      assert Error.kind(error) == :network
      assert Error.transient?(error)
    end

    test "is not tracked for text messages", %{chat_id: chat_id} do
      Req.Test.stub(Angler.Telegram, fn conn ->
        request_sent()
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Error{request_sent: false} = error} = Telegram.send_message(chat_id, "hi")
      assert Error.kind(error) == :network
    end
  end

  describe "other chat methods" do
    test "send_message/3", %{chat_id: chat_id} do
      stub_bot_api(%{"sendMessage" => %{"message_id" => 1}})

      assert {:ok, %{"message_id" => 1}} =
               Telegram.send_message(chat_id, "hello",
                 reply_to_message_id: 9,
                 parse_mode: "HTML",
                 link_preview: false
               )

      assert_received {:bot_api, "sendMessage", params}

      assert params == %{
               "chat_id" => chat_id,
               "text" => "hello",
               "parse_mode" => "HTML",
               "reply_parameters" => %{"message_id" => 9, "allow_sending_without_reply" => true},
               "link_preview_options" => %{"is_disabled" => true}
             }

      other_chat_id = unique_id()
      assert {:ok, _} = Telegram.send_message(other_chat_id, "quiet", disable_notification: true)

      assert_received {:bot_api, "sendMessage",
                       %{"text" => "quiet", "disable_notification" => true} = params}

      refute Map.has_key?(params, "reply_parameters")
    end

    test "set_message_reaction/4 sets and clears", %{chat_id: chat_id} do
      stub_bot_api()

      assert {:ok, true} = Telegram.set_message_reaction(chat_id, 4, "👀", chat_type: "private")
      assert_received {:bot_api, "setMessageReaction", params}

      assert params == %{
               "chat_id" => chat_id,
               "message_id" => 4,
               "reaction" => [%{"type" => "emoji", "emoji" => "👀"}]
             }

      assert {:ok, true} = Telegram.set_message_reaction(chat_id, 4, nil)
      assert_received {:bot_api, "setMessageReaction", %{"reaction" => []}}
    end

    test "send_chat_action/3", %{chat_id: chat_id} do
      stub_bot_api()

      assert {:ok, true} =
               Telegram.send_chat_action(chat_id, "upload_video", message_thread_id: 2)

      assert_received {:bot_api, "sendChatAction", params}

      assert params == %{
               "chat_id" => chat_id,
               "action" => "upload_video",
               "message_thread_id" => 2
             }
    end
  end

  describe "429 handling" do
    test "retries after retry_after", %{chat_id: chat_id} do
      calls = counter()

      stub_bot_api(%{
        "sendMessage" => fn conn ->
          if increment(calls) == 1 do
            conn
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(
              api_error(429, "Too Many Requests: retry after 0", %{"retry_after" => 0})
            )
          else
            Req.Test.json(conn, api_ok(%{"message_id" => 2}))
          end
        end
      })

      assert {:ok, %{"message_id" => 2}} = Telegram.send_message(chat_id, "hi")
      assert count(calls) == 2
    end

    test "gives up after two retries", %{chat_id: chat_id} do
      stub_bot_api(%{"sendMessage" => {:error, 429, "Too Many Requests", %{"retry_after" => 0}}})

      assert {:error, %Error{code: 429, retry_after: 0}} = Telegram.send_message(chat_id, "hi")

      for _ <- 1..3, do: assert_received({:bot_api, "sendMessage", _})
      refute_received {:bot_api, "sendMessage", _}
    end

    test "returns long waits to the caller and holds the chat back", %{chat_id: chat_id} do
      stub_bot_api(%{"sendMessage" => {:error, 429, "Too Many Requests", %{"retry_after" => 61}}})

      assert {:error, %Error{code: 429, retry_after: 61}} = Telegram.send_message(chat_id, "hi")
      assert_received {:bot_api, "sendMessage", _}

      # The limiter now refuses to send to this chat instead of waiting a minute.
      assert {:error, %Error{code: 429, retry_after: retry_after} = error} =
               Telegram.send_video(chat_id, {:file_id, "BAAC"})

      assert retry_after in 60..61
      assert error.description =~ "local rate limiter"
      refute_received {:bot_api, "sendVideo", _}
    end

    test "sendVideo returns waits over 10 s to the caller instead of blocking",
         %{chat_id: chat_id} do
      # Held back by the local limiter (e.g. a 429 on another send to this chat).
      Angler.Telegram.RateLimiter.backoff(chat_id, 20)
      stub_bot_api(%{"sendVideo" => sent_video(chat_id)})

      {elapsed, result} = :timer.tc(fn -> Telegram.send_video(chat_id, {:file_id, "BAAC"}) end)

      assert {:error, %Error{code: 429, retry_after: retry_after}} = result
      assert retry_after in 19..20
      assert elapsed < 5_000_000
      refute_received {:bot_api, "sendVideo", _}

      # Telegram's own 429s alike: one call, and the chat is held back.
      other_chat_id = unique_id()

      stub_bot_api(%{
        "sendVideo" => {:error, 429, "Too Many Requests: retry after 30", %{"retry_after" => 30}}
      })

      {elapsed, result} =
        :timer.tc(fn -> Telegram.send_video(other_chat_id, {:file_id, "BAAC"}) end)

      assert {:error, %Error{code: 429, retry_after: 30}} = result
      assert elapsed < 5_000_000
      assert_received {:bot_api, "sendVideo", _}
      refute_received {:bot_api, "sendVideo", _}

      assert {:error, %Error{code: 429, description: description}} =
               Telegram.send_video(other_chat_id, {:file_id, "BAAC"})

      assert description =~ "local rate limiter"
    end

    test "reactions and chat actions are dropped on 429 without holding the chat back",
         %{chat_id: chat_id} do
      stub_bot_api(%{
        "setMessageReaction" => {:error, 429, "Too Many Requests", %{"retry_after" => 1}},
        "sendChatAction" => {:error, 429, "Too Many Requests", %{"retry_after" => 120}},
        "sendMessage" => %{"message_id" => 3}
      })

      assert {:error, %Error{code: 429, retry_after: 1}} =
               Telegram.set_message_reaction(chat_id, 4, "👀")

      assert {:error, %Error{code: 429, retry_after: 120}} =
               Telegram.send_chat_action(chat_id, "upload_video")

      # Not retried, and messages to the chat are not held back.
      assert_received {:bot_api, "setMessageReaction", _}
      refute_received {:bot_api, "setMessageReaction", _}
      assert_received {:bot_api, "sendChatAction", _}
      refute_received {:bot_api, "sendChatAction", _}
      assert {:ok, %{"message_id" => 3}} = Telegram.send_message(chat_id, "hi")
    end

    test "a reaction with max_wait is not sent when it would have to wait longer",
         %{chat_id: chat_id} do
      stub_bot_api()
      Angler.Telegram.RateLimiter.backoff(chat_id, 5)

      {elapsed, result} =
        :timer.tc(fn -> Telegram.set_message_reaction(chat_id, 4, "👀", max_wait: 0) end)

      assert {:error, %Error{code: 429, retry_after: retry_after} = error} = result
      assert retry_after in 4..5
      assert error.description =~ "local rate limiter"
      assert elapsed < 1_000_000
      refute_received {:bot_api, "setMessageReaction", _}
    end

    test "does not retry other errors", %{chat_id: chat_id} do
      stub_bot_api(%{"sendMessage" => {:error, 500, "Internal Server Error"}})

      assert {:error, %Error{code: 500}} = Telegram.send_message(chat_id, "hi")
      assert_received {:bot_api, "sendMessage", _}
      refute_received {:bot_api, "sendMessage", _}
    end
  end

  test "Error.kind/1 recognizes common failures" do
    kind = &Error.kind(%Error{code: &1, description: &2})

    assert kind.(403, "Forbidden: bot was blocked by the user") == :forbidden
    assert kind.(401, "Unauthorized") == :unauthorized
    assert kind.(409, "Conflict: terminated by other getUpdates request") == :conflict
    assert kind.(400, "Bad Request: chat not found") == :chat_not_found
    assert kind.(400, "Bad Request: message thread not found") == :thread_not_found
    assert kind.(400, "Bad Request: message to be replied not found") == :reply_not_found
    assert kind.(400, "Bad Request: wrong file identifier/HTTP URL specified") == :invalid_file
    assert kind.(400, "Bad Request: FILE_ID_INVALID") == :invalid_file
    assert kind.(400, "Bad Request: file is too big") == :too_large
    assert kind.(503, "Service Unavailable") == :server_error
    assert kind.(400, "Bad Request: REACTION_INVALID") == :other
    assert kind.(400, nil) == :other
    assert kind.(nil, "timeout") == :network
    assert Error.kind(%Error{description: "closed", request_sent: true}) == :unconfirmed
  end

  # What Finch reports in the calling process once a request was sent completely.
  defp request_sent, do: :telemetry.execute([:finch, :recv, :start], %{}, %{})

  defp counter, do: :counters.new(1, [])

  defp increment(counter) do
    :counters.add(counter, 1, 1)
    :counters.get(counter, 1)
  end

  defp count(counter), do: :counters.get(counter, 1)
end
