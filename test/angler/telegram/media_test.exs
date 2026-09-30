defmodule Angler.Telegram.MediaTest do
  # send_photo/3 and send_media_group/3 (bodies built by Angler.Telegram.MediaBody).
  use ExUnit.Case, async: true

  import Angler.TelegramFixtures

  alias Angler.Telegram
  alias Angler.Telegram.{Error, HTTP, RateLimiter}

  # Unique chats keep the shared rate limiter from spacing out tests: an album
  # books one slot per item.
  setup do
    %{chat_id: unique_id()}
  end

  describe "send_photo/3" do
    @tag :tmp_dir
    test "uploads the photo as multipart", %{chat_id: chat_id, tmp_dir: dir} do
      photo = write_file!(dir, "Photo.JPG")
      sent = sent_photo(chat_id)
      stub_uploads(sent)

      assert {:ok, ^sent} =
               Telegram.send_photo(chat_id, {:path, photo},
                 reply_to_message_id: 77,
                 message_thread_id: 5,
                 chat_type: "private",
                 caption: "Post text",
                 disable_notification: true
               )

      assert_received {:upload, "sendPhoto", params, files}

      assert files == %{"photo" => {"photo.jpg", "image/jpeg", File.read!(photo)}}

      assert %{
               "chat_id" => chat_id_string,
               "message_thread_id" => "5",
               "caption" => "Post text",
               "disable_notification" => "true",
               "reply_parameters" => reply_parameters
             } = params

      assert chat_id_string == Integer.to_string(chat_id)

      assert Jason.decode!(reply_parameters) == %{
               "message_id" => 77,
               "allow_sending_without_reply" => true
             }

      assert Enum.sort(Map.keys(params)) ==
               ~w(caption chat_id disable_notification message_thread_id photo reply_parameters)
    end

    test "sends a file_id as JSON", %{chat_id: chat_id} do
      stub_bot_api(%{"sendPhoto" => sent_photo(chat_id)})

      assert {:ok, %{"photo" => [_ | _]}} =
               Telegram.send_photo(chat_id, {:file_id, "AgAC-file"}, reply_to_message_id: 3)

      assert_received {:bot_api, "sendPhoto", params}

      assert params == %{
               "chat_id" => chat_id,
               "photo" => "AgAC-file",
               "reply_parameters" => %{"message_id" => 3, "allow_sending_without_reply" => true}
             }
    end

    test "fails without calling Telegram when the file is missing", %{chat_id: chat_id} do
      stub_bot_api()

      assert {:error, %Error{method: "sendPhoto", reason: :enoent} = error} =
               Telegram.send_photo(chat_id, {:path, "/nonexistent/photo.jpg"})

      assert error.description == "photo file not found: /nonexistent/photo.jpg"
      refute_received {:bot_api, _, _}
    end
  end

  describe "send_media_group/3" do
    @tag :tmp_dir
    test "uploads the files as multipart parts referenced by the media array",
         %{chat_id: chat_id, tmp_dir: dir} do
      photo = write_file!(dir, "photo.jpg")
      video = write_file!(dir, "video.mp4", 100_000)
      thumbnail = write_file!(dir, "thumbnail.jpg")
      png = write_file!(dir, "photo.png")

      items = [
        # Photos never get a thumbnail, and only the first item's caption is sent.
        %{type: :photo, media: {:path, photo}, thumbnail: thumbnail, caption: "dropped"},
        %{
          type: :video,
          media: {:path, video},
          width: 720,
          height: 1280,
          duration: 11.6,
          thumbnail: thumbnail,
          caption: "dropped too"
        },
        %{type: :photo, media: {:path, png}, width: 1080, height: 1350}
      ]

      sent = sent_media_group(chat_id, items)
      stub_uploads(sent)

      assert {:ok, ^sent} =
               Telegram.send_media_group(chat_id, items,
                 caption: "Album text",
                 reply_to_message_id: 77,
                 message_thread_id: 5,
                 chat_type: "private",
                 disable_notification: true
               )

      assert_received {:upload, "sendMediaGroup", params, files}

      assert files == %{
               "file0" => {"photo0.jpg", "image/jpeg", File.read!(photo)},
               "file1" => {"video1.mp4", "video/mp4", File.read!(video)},
               "thumb1" => {"thumbnail1.jpg", "image/jpeg", File.read!(thumbnail)},
               "file2" => {"photo2.png", "image/png", File.read!(png)}
             }

      assert Jason.decode!(params["media"]) == [
               %{"type" => "photo", "media" => "attach://file0", "caption" => "Album text"},
               %{
                 "type" => "video",
                 "media" => "attach://file1",
                 "thumbnail" => "attach://thumb1",
                 "width" => 720,
                 "height" => 1280,
                 "duration" => 12,
                 "supports_streaming" => true
               },
               %{"type" => "photo", "media" => "attach://file2"}
             ]

      assert %{
               "chat_id" => chat_id_string,
               "message_thread_id" => "5",
               "disable_notification" => "true",
               "reply_parameters" => reply_parameters
             } = params

      assert chat_id_string == Integer.to_string(chat_id)
      assert Jason.decode!(reply_parameters)["message_id"] == 77

      # Never a part named thumb or thumbnail: Telegram would give it to every video.
      assert Enum.sort(Map.keys(params)) ==
               ~w(chat_id disable_notification file0 file1 file2 media message_thread_id
                  reply_parameters thumb1)
    end

    @tag :tmp_dir
    test "uploads only the files that aren't sent by file_id", %{chat_id: chat_id, tmp_dir: dir} do
      photo = write_file!(dir, "photo.webp")
      video = write_file!(dir, "video.mp4")
      thumbnail = write_file!(dir, "thumbnail.jpg")

      items = [
        # Thumbnails can't be reused: none for a file_id.
        %{type: :video, media: {:file_id, "BAAC-1"}, thumbnail: thumbnail, duration: 3},
        %{type: :photo, media: {:path, photo}},
        %{type: :video, media: {:path, video}, thumbnail: Path.join(dir, "missing.jpg")}
      ]

      stub_uploads(sent_media_group(chat_id, items))

      assert {:ok, [_, _, _]} = Telegram.send_media_group(chat_id, items)
      assert_received {:upload, "sendMediaGroup", params, files}

      assert files == %{
               "file1" => {"photo1.webp", "image/webp", File.read!(photo)},
               "file2" => {"video2.mp4", "video/mp4", File.read!(video)}
             }

      assert Jason.decode!(params["media"]) == [
               %{
                 "type" => "video",
                 "media" => "BAAC-1",
                 "duration" => 3,
                 "supports_streaming" => true
               },
               %{"type" => "photo", "media" => "attach://file1"},
               %{"type" => "video", "media" => "attach://file2", "supports_streaming" => true}
             ]

      assert Enum.sort(Map.keys(params)) == ~w(chat_id file1 file2 media)
    end

    test "sends file ids as JSON, with the first item's caption", %{chat_id: chat_id} do
      items = [
        %{type: :video, media: {:file_id, "BAAC-1"}, caption: "First", width: 720.0},
        %{type: :photo, media: {:file_id, "AgAC-2"}, caption: "Second"}
      ]

      sent = sent_media_group(chat_id, items)
      stub_bot_api(%{"sendMediaGroup" => sent})

      assert {:ok, ^sent} = Telegram.send_media_group(chat_id, items, reply_to_message_id: 3)
      assert_received {:bot_api, "sendMediaGroup", params}

      assert params == %{
               "chat_id" => chat_id,
               "media" => [
                 %{
                   "type" => "video",
                   "media" => "BAAC-1",
                   "caption" => "First",
                   "width" => 720,
                   "supports_streaming" => true
                 },
                 %{"type" => "photo", "media" => "AgAC-2"}
               ],
               "reply_parameters" => %{"message_id" => 3, "allow_sending_without_reply" => true}
             }
    end

    test "takes 2 to 10 items, and fails without calling Telegram otherwise",
         %{chat_id: chat_id} do
      stub_bot_api()
      photo = %{type: :photo, media: {:file_id, "AgAC"}}

      for items <- [[], [photo], List.duplicate(photo, 11)] do
        assert {:error, %Error{method: "sendMediaGroup", code: 400} = error} =
                 Telegram.send_media_group(chat_id, items)

        assert error.description =~ "2 to 10 items"
        # Not a network error, which would be retried.
        assert Error.kind(error) == :other
        refute Error.transient?(error)
      end

      for item <- [%{type: :audio, media: {:file_id, "x"}}, %{type: :photo, media: "x"}] do
        assert {:error, %Error{method: "sendMediaGroup", code: 400}} =
                 Telegram.send_media_group(chat_id, [photo, item])
      end

      refute_received {:bot_api, _, _}
    end

    @tag :tmp_dir
    test "fails without calling Telegram when a file is missing",
         %{chat_id: chat_id, tmp_dir: dir} do
      stub_bot_api()
      photo = write_file!(dir, "photo.jpg")
      missing = Path.join(dir, "video.mp4")

      assert {:error, %Error{method: "sendMediaGroup", reason: :enoent} = error} =
               Telegram.send_media_group(chat_id, [
                 %{type: :photo, media: {:path, photo}},
                 %{type: :video, media: {:path, missing}}
               ])

      assert error.description == "video file not found: #{missing}"
      refute_received {:bot_api, _, _}
    end
  end

  describe "uploads without an answer" do
    test "are unconfirmed when the request was sent completely" do
      Req.Test.stub(Angler.Telegram, fn conn ->
        request_sent()
        Req.Test.transport_error(conn, :timeout)
      end)

      album = [
        %{type: :photo, media: {:file_id, "AgAC-1"}},
        %{type: :video, media: {:file_id, "BAAC-2"}}
      ]

      for send <- [
            &Telegram.send_photo(&1, {:file_id, "AgAC"}),
            &Telegram.send_media_group(&1, album)
          ] do
        assert {:error, %Error{code: nil, request_sent: true} = error} = send.(unique_id())
        assert Error.kind(error) == :unconfirmed
        refute Error.transient?(error)
      end
    end
  end

  describe "rate limiting" do
    test "retries an album after a short 429", %{chat_id: chat_id} do
      calls = :counters.new(1, [])
      items = [%{type: :photo, media: {:file_id, "A"}}, %{type: :photo, media: {:file_id, "B"}}]
      sent = sent_media_group(chat_id, items)

      stub_bot_api(%{
        "sendMediaGroup" => fn conn ->
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) == 1 do
            conn
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(
              api_error(429, "Too Many Requests: retry after 0", %{"retry_after" => 0})
            )
          else
            Req.Test.json(conn, api_ok(sent))
          end
        end
      })

      assert {:ok, ^sent} = Telegram.send_media_group(chat_id, items)
      assert :counters.get(calls, 1) == 2
    end

    test "gives the slot of an album refused with a 429 back to the limiter" do
      # A group: the limiter counts its messages per minute.
      chat_id = -unique_id()
      calls = :counters.new(1, [])
      items = [%{type: :photo, media: {:file_id, "A"}}, %{type: :photo, media: {:file_id, "B"}}]

      stub_bot_api(%{
        "sendMediaGroup" => fn conn ->
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) == 1 do
            conn
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(api_error(429, "Too Many Requests", %{"retry_after" => 0}))
          else
            Req.Test.json(conn, api_ok(sent_media_group(chat_id, items)))
          end
        end
      })

      assert {:ok, _sent} = Telegram.send_media_group(chat_id, items, chat_type: "supergroup")

      # Only the two messages Telegram posted count, once.
      assert %{times: [at, at]} = :sys.get_state(RateLimiter).chats[chat_id]
    end

    test "an album books one slot per item", %{chat_id: chat_id} do
      stub_bot_api()
      items = for id <- ~w(A B C), do: %{type: :photo, media: {:file_id, id}}

      assert {:ok, _} = Telegram.send_media_group(chat_id, items, chat_type: "private")

      # The chat's next message waits as if the three had been sent 1050 ms apart.
      assert {:error, %Error{code: 429, retry_after: retry_after} = error} =
               Telegram.send_message(chat_id, "text", chat_type: "private", max_wait: 1_000)

      assert retry_after in 3..4
      assert error.description =~ "local rate limiter"
      assert_received {:bot_api, "sendMediaGroup", _}
      refute_received {:bot_api, "sendMessage", _}
    end

    test "sends wait up to :max_wait, uploads 10 s by default", %{chat_id: chat_id} do
      stub_bot_api()
      RateLimiter.backoff(chat_id, 20)
      album = [%{type: :photo, media: {:file_id, "A"}}, %{type: :photo, media: {:file_id, "B"}}]

      {elapsed, results} =
        :timer.tc(fn ->
          [
            Telegram.send_message(chat_id, "text", max_wait: 1_000),
            Telegram.send_video(chat_id, {:file_id, "BAAC"}, max_wait: 1_000),
            Telegram.send_photo(chat_id, {:file_id, "AgAC"}, max_wait: 1_000),
            Telegram.send_media_group(chat_id, album, max_wait: 1_000),
            Telegram.send_photo(chat_id, {:file_id, "AgAC"}),
            Telegram.send_media_group(chat_id, album, max_wait: nil)
          ]
        end)

      assert elapsed < 5_000_000

      for result <- results do
        assert {:error, %Error{code: 429, retry_after: retry_after} = error} = result
        assert retry_after in 19..20
        assert error.description =~ "local rate limiter"
      end

      refute_received {:bot_api, _, _}
    end

    test "a count the limiter can't book fails without calling Telegram", %{chat_id: chat_id} do
      stub_bot_api()

      for {kind, count} <- [message: 0, message: 21, message: 1.5, light: 2] do
        assert {:error, %Error{method: "sendMediaGroup", code: 400} = error} =
                 HTTP.send_to_chat("sendMediaGroup", chat_id, kind, [json: %{}], count: count)

        assert error.description =~ "local rate limiter"
      end

      refute_received {:bot_api, _, _}
    end
  end

  # Random bytes plus CRLF and NUL bytes, which must survive the upload unchanged.
  defp write_file!(dir, name, size \\ 20_000) do
    path = Path.join(dir, name)
    File.write!(path, [:crypto.strong_rand_bytes(size), "\r\n\r\n\0", "tail"])
    path
  end

  # Answers with `result` and reports each request to the test as
  # `{:upload, method, params, files}`, files mapping each part name to its
  # `{filename, content_type, bytes}`.
  defp stub_uploads(result) do
    test = self()

    Req.Test.stub(Angler.Telegram, fn conn ->
      files =
        for {name, %Plug.Upload{} = upload} <- conn.body_params, into: %{} do
          {name, {upload.filename, upload.content_type, File.read!(upload.path)}}
        end

      send(test, {:upload, List.last(conn.path_info), conn.body_params, files})
      Req.Test.json(conn, api_ok(result))
    end)
  end

  # What Finch reports in the calling process once a request was sent completely.
  defp request_sent, do: :telemetry.execute([:finch, :recv, :start], %{}, %{})
end
