defmodule Angler.Pipeline.AlbumUploadTest do
  # Changes the global Telegram and media configuration; feedback and background
  # writes run in tasks.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  alias Angler.{Entries, FakeMedia, Media, Settings, Storage}
  alias Angler.Entries.{Entry, MediaItem}
  alias Angler.Pipeline.{AlbumUpload, Caption, RetryPolicy}
  alias Angler.Telegram.RateLimiter
  alias Broadway.Message

  @moduletag :capture_log
  @moduletag :tmp_dir
  @timeout 5_000
  # A follow-up text waits for the chat's next rate limiter slot, 1050 ms per item
  # after an album of two: no follow-up after longer than that means none came.
  @no_follow_up_wait 2_500
  @jpeg <<0xFF, 0xD8, 0xFF, 0xD9>>

  setup %{tmp_dir: tmp_dir} do
    media_config = Application.fetch_env!(:angler, Angler.Media)
    Application.put_env(:angler, Angler.Media, Keyword.put(media_config, :data_dir, tmp_dir))
    on_exit(fn -> Application.put_env(:angler, Angler.Media, media_config) end)

    stub_bot_api()
    :ok = Entries.subscribe()
    :ok
  end

  describe "run/2" do
    test "sends the album as a reply, with the post text as the caption of the first item" do
      {entry, album} = prepared_album([:photo, :video], title: "Catch of the day 🎣")
      sent = sent_media_group(entry.chat_id, [:photo, :video])
      test = self()

      stub_bot_api(%{
        "sendMediaGroup" => fn conn ->
          send(test, {:uploaded, read_upload(conn, "file0"), read_upload(conn, "file1")})
          Req.Test.json(conn, api_ok(sent))
        end
      })

      assert %Message{status: :ok} = run(entry, album)

      # Multipart with the bytes intact, the caption on the first item, plain text.
      assert_received {:uploaded, photo, video}
      assert photo == FakeMedia.photo_bytes()
      assert video == FakeMedia.video_bytes()
      assert_received {:bot_api, "sendMediaGroup", params}
      refute Map.has_key?(params, "parse_mode")

      assert Jason.decode!(params["media"]) == [
               %{
                 "type" => "photo",
                 "media" => "attach://file0",
                 "caption" => "Catch of the day 🎣"
               },
               %{
                 "type" => "video",
                 "media" => "attach://file1",
                 "thumbnail" => "attach://thumb1",
                 "duration" => 12,
                 "width" => 720,
                 "height" => 1280,
                 "supports_streaming" => true
               }
             ]

      assert %Plug.Upload{} = params["thumb1"]

      assert Jason.decode!(params["reply_parameters"]) ==
               %{"message_id" => entry.message_id, "allow_sending_without_reply" => true}

      # Every item keeps its Telegram file (the largest size of a photo); albums
      # are never re-used, so the entry has no file id of its own.
      [photo_message, video_message] = sent
      photo_file = Enum.max_by(photo_message["photo"], &(&1["width"] * &1["height"]))

      assert %Entry{
               status: :done,
               telegram_file_id: nil,
               telegram_file_unique_id: nil,
               reused_file_id: false,
               purged_at: nil,
               media_items: [%MediaItem{} = photo_item, %MediaItem{} = video_item]
             } = done = Entries.get(entry.id)

      assert done.reply_message_id == photo_message["message_id"]

      assert {photo_item.file_id, photo_item.file_unique_id} ==
               {photo_file["file_id"], photo_file["file_unique_id"]}

      assert video_item.file_id == video_message["video"]["file_id"]
      assert video_item.file_unique_id == video_message["video"]["file_unique_id"]
      assert %MediaItem{path: "album/02/video.mp4", duration: 12.0} = video_item

      # Its files are kept like a video's; intermediates are deleted.
      assert length(Storage.album_files(done)) == 4
      refute File.exists?(Path.join(entry.storage_path, "album/01/source.jpg"))

      assert_receive {:bot_api, "sendChatAction", %{"action" => "upload_video"}}, @timeout
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      refute_receive {:bot_api, "sendMessage", _params}, 200
    end

    test "sends a lone photo with sendPhoto, showing that a photo is on its way" do
      {entry, album} = prepared_album([:photo], title: "A photo")
      sent = sent_photo(entry.chat_id)
      stub_bot_api(%{"sendPhoto" => sent})

      assert %Message{status: :ok} = run(entry, album)

      assert_received {:bot_api, "sendPhoto", %{"photo" => %Plug.Upload{}} = params}
      assert params["caption"] == "A photo"
      largest = List.last(sent["photo"])

      assert %Entry{status: :done, media_items: [%MediaItem{file_id: file_id}]} =
               Entries.get(entry.id)

      assert file_id == largest["file_id"]
      assert_receive {:bot_api, "sendChatAction", %{"action" => "upload_photo"}}, @timeout
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "sends a lone video with sendVideo" do
      {entry, album} = prepared_album([:video])
      sent = sent_video(entry.chat_id)
      stub_bot_api(%{"sendVideo" => sent})

      assert %Message{status: :ok} = run(entry, album)

      assert_received {:bot_api, "sendVideo", params}
      assert %{"video" => %Plug.Upload{}, "thumbnail" => "attach://thumb"} = params
      assert %{"duration" => "12", "supports_streaming" => "true"} = params

      assert %Entry{status: :done, media_items: [%MediaItem{file_id: file_id}]} =
               Entries.get(entry.id)

      assert file_id == sent["video"]["file_id"]
      assert_chat_action(entry)
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "sends a post text too long for a caption after the album, replying to it" do
      title = String.duplicate("A long post. ", 100)
      {entry, album} = prepared_album([:photo, :photo], title: title)
      sent = sent_media_group(entry.chat_id, [:photo, :photo])
      stub_bot_api(%{"sendMediaGroup" => sent})

      assert %Message{status: :ok} = run(entry, album)

      assert_received {:bot_api, "sendMediaGroup", params}
      refute params["media"] |> Jason.decode!() |> Enum.any?(&Map.has_key?(&1, "caption"))

      assert_receive {:bot_api, "sendMessage", follow_up}, @timeout
      assert follow_up["text"] == String.trim(title)
      assert follow_up["reply_parameters"]["message_id"] == hd(sent)["message_id"]
      assert follow_up["disable_notification"] == true
      assert %Entry{status: :done} = Entries.get(entry.id)
      assert_chat_action(entry)
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "fails the message without sending anything when a file is missing" do
      {entry, album} = prepared_album([:photo, :video])
      File.rm!(Path.join(entry.storage_path, "album/02/thumbnail.jpg"))

      assert %Message{status: {:failed, {:internal, text}}} = run(entry, album)
      assert text =~ "album file not found"
      assert text =~ "album/02/thumbnail.jpg"

      refute_received {:bot_api, "sendMediaGroup", _params}
      assert %Entry{status: :uploading} = Entries.get(entry.id)
    end

    test "fails the message like a video when Telegram refuses the first part" do
      for {response, kind} <- [
            {{:error, 502, "Bad Gateway"}, :transient},
            {{:error, 400, "Bad Request: PHOTO_INVALID_DIMENSIONS"}, :telegram}
          ] do
        {entry, album} = prepared_album([:photo, :video])
        stub_bot_api(%{"sendMediaGroup" => response})

        assert %Message{status: {:failed, {^kind, _text}}} = run(entry, album)

        # Nothing is in the chat: retrying it (see Failures) sends it whole.
        assert %Entry{status: :uploading} = current = Entries.get(entry.id)
        refute AlbumUpload.partly_delivered?(current)
        assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      end
    end

    test "fails the entry for good when Telegram never confirmed the first part" do
      {entry, album} = prepared_album([:photo, :video])

      stub_bot_api(%{
        "sendMediaGroup" => fn conn ->
          request_sent()
          Req.Test.transport_error(conn, :closed)
        end
      })

      assert %Message{status: :ok} = run(entry, album)

      assert %Entry{status: :failed, error_kind: :telegram, purged_at: nil} =
               failed = Entries.get(entry.id)

      assert failed.error == RetryPolicy.unconfirmed_text()
      assert length(Storage.album_files(failed)) == 4
      assert_chat_action(entry)
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      refute_receive {:bot_api, "sendMessage", _params}, 200
    end

    test "sends no post text on its own when Telegram never confirmed the first part" do
      title = String.duplicate("A long post. ", 100)
      {entry, album} = prepared_album([:photo, :video], title: title)
      stub_unconfirmed_media_group()

      assert %Message{status: :ok} = run(entry, album)

      assert_received {:bot_api, "sendMediaGroup", params}
      refute params["media"] |> Jason.decode!() |> Enum.any?(&Map.has_key?(&1, "caption"))
      assert %Entry{status: :failed, error_kind: :telegram} = Entries.get(entry.id)
      assert_chat_action(entry)
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout

      # The album may appear much later, or never: the text would come first, or alone.
      refute_receive {:bot_api, "sendMessage", _params}, @no_follow_up_wait
    end

    test "with a local Bot API server, also posts a text too long for a caption cut to fit it" do
      local_mode()
      title = String.duplicate("A long post. ", 100)

      for confirmed? <- [true, false] do
        {entry, album} = prepared_album([:photo, :video], title: title)
        sent = sent_media_group(entry.chat_id, [:photo, :video])

        if confirmed?,
          do: stub_bot_api(%{"sendMediaGroup" => sent}),
          else: stub_unconfirmed_media_group()

        assert %Message{status: :ok} = run(entry, album)

        # JSON: the server reads the files from disk.
        assert_received {:bot_api, "sendMediaGroup", %{"media" => [first, second]}}
        assert first["caption"] == Caption.build(title)
        assert String.ends_with?(first["caption"], "…")
        refute Map.has_key?(second, "caption")
        assert_chat_action(entry)
        assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout

        if confirmed? do
          # Delivered: the whole text follows the album.
          assert_receive {:bot_api, "sendMessage", follow_up}, @timeout
          assert follow_up["text"] == String.trim(title)
          assert follow_up["reply_parameters"]["message_id"] == hd(sent)["message_id"]
          assert %Entry{status: :done} = Entries.get(entry.id)
        else
          assert %Entry{status: :failed, error_kind: :telegram} = Entries.get(entry.id)
          refute_receive {:bot_api, "sendMessage", _params}, @no_follow_up_wait
        end
      end
    end

    test "sends no post text when Telegram refused the first part" do
      {entry, album} =
        prepared_album([:photo, :video], title: String.duplicate("A long post. ", 100))

      stub_bot_api(%{"sendMediaGroup" => {:error, 400, "Bad Request: PHOTO_INVALID_DIMENSIONS"}})

      assert %Message{status: {:failed, {:telegram, _text}}} = run(entry, album)
      assert_chat_action(entry)
      refute_receive {:bot_api, "sendMessage", _params}, 300
    end
  end

  describe "run/2 with more than 10 items" do
    test "sends them in parts, recording each part before the next" do
      {entry, album} = prepared_album(List.duplicate(:photo, 12), title: "Twelve")
      first = sent_media_group(entry.chat_id, List.duplicate(:photo, 6))
      second = sent_media_group(entry.chat_id, List.duplicate(:photo, 6))
      test = self()

      stub_parts(entry, [
        &Req.Test.json(&1, api_ok(first)),
        fn conn ->
          delivered = Enum.count(Entries.get(entry.id).media_items, &MediaItem.delivered?/1)
          send(test, {:delivered_before_second_part, delivered})
          Req.Test.json(conn, api_ok(second))
        end
      ])

      assert %Message{status: :ok} = run(entry, album)

      assert_received {:bot_api, "sendMediaGroup", first_params}
      assert_received {:delivered_before_second_part, 6}
      assert_received {:bot_api, "sendMediaGroup", second_params}

      # The caption goes with the first item; later parts don't notify the chat.
      assert [%{"caption" => "Twelve"} | _rest] =
               first_media = Jason.decode!(first_params["media"])

      assert length(first_media) == 6
      refute Map.has_key?(first_params, "disable_notification")
      second_media = Jason.decode!(second_params["media"])
      assert length(second_media) == 6
      refute Enum.any?(second_media, &Map.has_key?(&1, "caption"))
      assert second_params["disable_notification"] == "true"
      assert Jason.decode!(second_params["reply_parameters"])["message_id"] == entry.message_id

      assert %Entry{status: :done, media_items: items} = done = Entries.get(entry.id)
      assert Enum.all?(items, &MediaItem.delivered?/1)
      assert done.reply_message_id == hd(first)["message_id"]
      assert length(Storage.album_files(done)) == 13
      assert_chat_action(entry)
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "fails as sent in part when a later part is refused, keeping the files" do
      {entry, album} = prepared_album(List.duplicate(:photo, 12))
      first = sent_media_group(entry.chat_id, List.duplicate(:photo, 6))

      stub_parts(entry, [
        &Req.Test.json(&1, api_ok(first)),
        &api_error_response(&1, 400, "Bad Request: failed to send message #1: MEDIA_EMPTY")
      ])

      assert %Message{status: :ok} = run(entry, album)

      assert %Entry{status: :failed, error_kind: :telegram, purged_at: nil} =
               failed = Entries.get(entry.id)

      assert failed.error ==
               "Only 6 of 12 items were sent: Telegram sendMediaGroup failed (400): " <>
                 "Bad Request: failed to send message #1: MEDIA_EMPTY"

      assert failed.reply_message_id == hd(first)["message_id"]
      {delivered, rest} = Enum.split(failed.media_items, 6)
      assert Enum.all?(delivered, &MediaItem.delivered?/1)
      refute Enum.any?(rest, &MediaItem.delivered?/1)
      assert length(Storage.album_files(failed)) == 13

      # Nothing will be sent again: failure feedback, with how much was sent.
      chat_id = entry.chat_id

      assert_receive {:bot_api, "sendMessage",
                      %{"chat_id" => ^chat_id, "text" => "Only 6 of 12 items could be sent."}},
                     @timeout

      assert_chat_action(entry)

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👎"}]}},
                     @timeout
    end

    test "fails without failure feedback when Telegram never confirmed a later part" do
      {entry, album} = prepared_album(List.duplicate(:photo, 12))
      first = sent_media_group(entry.chat_id, List.duplicate(:photo, 6))

      stub_parts(entry, [
        &Req.Test.json(&1, api_ok(first)),
        fn conn ->
          request_sent()
          Req.Test.transport_error(conn, :timeout)
        end
      ])

      assert %Message{status: :ok} = run(entry, album)

      assert %Entry{status: :failed, error_kind: :telegram, purged_at: nil} =
               failed = Entries.get(entry.id)

      assert failed.error == "6 of 12 items were confirmed; the rest may still appear in the chat"
      assert length(Storage.album_files(failed)) == 13
      assert_chat_action(entry)
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      refute_receive {:bot_api, "sendMessage", _params}, 200
    end

    test "sends a later part again while Telegram refuses it without posting it" do
      {entry, album} = prepared_album(List.duplicate(:photo, 12))
      first = sent_media_group(entry.chat_id, List.duplicate(:photo, 6))
      second = sent_media_group(entry.chat_id, List.duplicate(:photo, 6))

      too_many =
        &api_error_response(&1, 429, "Too Many Requests: retry after 0", %{"retry_after" => 0})

      stub_parts(entry, [
        &Req.Test.json(&1, api_ok(first)),
        # Nothing reached Telegram.
        &Req.Test.transport_error(&1, :econnrefused),
        # The client itself retries twice.
        too_many,
        too_many,
        too_many,
        &Req.Test.json(&1, api_ok(second))
      ])

      assert %Message{status: :ok} = run(entry, album, %{album_retry_delays: [10]})

      for _call <- 1..6, do: assert_received({:bot_api, "sendMediaGroup", _params})
      assert %Entry{status: :done, media_items: items} = Entries.get(entry.id)
      assert Enum.all?(items, &MediaItem.delivered?/1)
      assert_chat_action(entry)
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "sends a later part without replying when the original message is gone" do
      chat_id = -1_000_000_000_000 - unique_id()

      {entry, album} =
        prepared_album(List.duplicate(:photo, 12),
          chat_id: chat_id,
          chat_type: "supergroup",
          message_thread_id: 7
        )

      first = sent_media_group(chat_id, List.duplicate(:photo, 6))
      second = sent_media_group(chat_id, List.duplicate(:photo, 6))

      stub_parts(entry, [
        &Req.Test.json(&1, api_ok(first)),
        &api_error_response(&1, 400, "Bad Request: message to be replied not found"),
        &Req.Test.json(&1, api_ok(second))
      ])

      assert %Message{status: :ok} = run(entry, album)

      assert_received {:bot_api, "sendMediaGroup", %{"reply_parameters" => _reply}}
      assert_received {:bot_api, "sendMediaGroup", %{"reply_parameters" => _reply}}
      assert_received {:bot_api, "sendMediaGroup", last}
      refute Map.has_key?(last, "reply_parameters")
      assert last["message_thread_id"] == "7"

      assert %Entry{status: :done} = Entries.get(entry.id)
      assert_chat_action(entry)
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "never raises after a part was delivered: a crash fails it as sent in part" do
      {entry, album} = prepared_album(List.duplicate(:photo, 12))
      first = sent_media_group(entry.chat_id, List.duplicate(:photo, 6))

      stub_parts(entry, [
        &Req.Test.json(&1, api_ok(first)),
        fn _conn -> raise "connection pool crashed" end
      ])

      assert %Message{status: :ok} = run(entry, album)

      assert %Entry{status: :failed, error_kind: :telegram, error: error} = Entries.get(entry.id)
      assert error == "Only 6 of 12 items were sent: ** (RuntimeError) connection pool crashed"

      assert_chat_action(entry)
      assert_partial_reply(entry, "Only 6 of 12 items could be sent.")

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👎"}]}},
                     @timeout
    end

    test "stops sending when the progress can't be recorded, failing it as sent in part" do
      {entry, album} = prepared_album(List.duplicate(:photo, 12))
      first = sent_media_group(entry.chat_id, List.duplicate(:photo, 6))
      fail_progress_updates()
      stub_parts(entry, [&Req.Test.json(&1, api_ok(first))])

      assert %Message{status: :ok} = run(entry, album, %{db_retry_delays: [10, 10]})

      id = entry.id
      assert_receive {:entry_updated, %Entry{id: ^id, status: :failed} = failed}, @timeout
      assert failed.error == "Only 6 of 12 items were sent: the database could not be reached"
      assert Enum.count(failed.media_items, &MediaItem.delivered?/1) == 6

      assert_received {:bot_api, "sendMediaGroup", _params}
      refute_received {:bot_api, "sendMediaGroup", _params}

      assert_chat_action(entry)
      assert_partial_reply(entry, "Only 6 of 12 items could be sent.")

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👎"}]}},
                     @timeout
    end
  end

  describe "finish_partial/3" do
    test "fails a partly delivered album for good, with failure feedback, keeping its files" do
      {entry, _album} = prepared_album([:photo, :video])
      entry = deliver_first_item(entry)
      assert AlbumUpload.partly_delivered?(entry)

      failed = AlbumUpload.finish_partial(entry, Settings.get(), "the upload was interrupted")

      assert %Entry{status: :failed, error_kind: :telegram, purged_at: nil} = failed
      assert failed.error == "Only 1 of 2 items were sent: the upload was interrupted"
      assert length(Storage.album_files(failed)) == 4

      assert_receive {:bot_api, "sendMessage", %{"text" => "Only 1 of 2 items could be sent."}},
                     @timeout

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👎"}]}},
                     @timeout
    end

    test "without failure feedback when the rest may still appear" do
      {entry, _album} = prepared_album([:photo, :video])
      entry = deliver_first_item(entry)

      failed = AlbumUpload.finish_partial(entry, Settings.get(), :unconfirmed)

      assert failed.error == "1 of 2 items were confirmed; the rest may still appear in the chat"
      assert %Entry{status: :failed, purged_at: nil} = failed
      assert length(Storage.album_files(failed)) == 4
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      refute_receive {:bot_api, "sendMessage", _params}, 200
    end

    test "sends the post text too long for a caption after the part in the chat" do
      title = String.duplicate("A long post. ", 100)
      text = String.trim(title)

      for reason <- [:unconfirmed, "the upload was interrupted"] do
        {entry, _album} = prepared_album([:photo, :video], title: title)
        entry = entry |> deliver_first_item() |> Entries.update!(%{reply_message_id: 501})

        AlbumUpload.finish_partial(entry, Settings.get(), reason)

        # Replying to the first message of the album.
        assert_receive {:bot_api, "sendMessage", %{"text" => ^text} = follow_up}, @timeout
        assert follow_up["reply_parameters"]["message_id"] == 501
        assert follow_up["chat_id"] == entry.chat_id
      end
    end
  end

  test "partly_delivered?/1 only holds for albums with a delivered item" do
    item = MediaItem.new(%{type: :photo, path: "album/01/photo.jpg"})
    delivered = %{item | file_id: "AgAC"}

    assert AlbumUpload.partly_delivered?(%Entry{
             media_kind: :album,
             media_items: [item, delivered]
           })

    refute AlbumUpload.partly_delivered?(%Entry{media_kind: :album, media_items: [item]})
    refute AlbumUpload.partly_delivered?(%Entry{media_kind: :album, media_items: []})
    refute AlbumUpload.partly_delivered?(%Entry{media_kind: :video, media_items: [delivered]})
  end

  test "media_items/2 records paths relative to the entry directory, however it is written" do
    dir = Path.join(File.cwd!(), "data/media/entry")

    output = %Media.Output{
      kind: :album,
      path: Path.join(dir, "album"),
      size: 30,
      items: [
        %{
          type: :photo,
          path: Path.join(dir, "album/01/photo.jpg"),
          size: 10,
          width: 1080,
          height: 1350,
          duration: nil,
          thumbnail_path: nil,
          video_codec: nil,
          transcoded: false
        },
        %{
          type: :video,
          path: Path.join(dir, "album/02/video.mp4"),
          size: 20,
          width: 720,
          height: 1280,
          duration: 12,
          thumbnail_path: Path.join(dir, "album/02/thumbnail.jpg"),
          video_codec: "h264",
          transcoded: true
        }
      ]
    }

    for entry_dir <- [dir, "data/media/entry", dir <> "/"] do
      assert [photo, video] = AlbumUpload.media_items(output, entry_dir)

      assert photo == %MediaItem{
               type: :photo,
               path: "album/01/photo.jpg",
               bytes: 10,
               width: 1080,
               height: 1350
             }

      assert %MediaItem{path: "album/02/video.mp4", thumbnail: "album/02/thumbnail.jpg"} = video
      assert video.duration == 12.0
    end
  end

  # Feedback runs in tasks: wait for all of it, so none outlives the test's stubs.
  defp assert_chat_action(%Entry{chat_id: chat_id}) do
    assert_receive {:bot_api, "sendChatAction", %{"chat_id" => ^chat_id}}, @timeout
  end

  defp assert_partial_reply(%Entry{chat_id: chat_id}, text) do
    assert_receive {:bot_api, "sendMessage", %{"chat_id" => ^chat_id, "text" => ^text}},
                   @timeout
  end

  # The request was sent, then the connection closed without an answer.
  defp stub_unconfirmed_media_group do
    stub_bot_api(%{
      "sendMediaGroup" => fn conn ->
        request_sent()
        Req.Test.transport_error(conn, :closed)
      end
    })
  end

  defp local_mode do
    config = Application.fetch_env!(:angler, Angler.Telegram)
    Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :local_mode, true))
    on_exit(fn -> Application.put_env(:angler, Angler.Telegram, config) end)
  end

  # Runs the upload step for an album, as the pipeline does.
  defp run(entry, album, context \\ %{}) do
    output = %Media.Output{kind: :album, path: Path.join(entry.storage_path, "album"), size: 0}

    message = %Message{
      data: %{entry: entry, album: album, output: output, settings: Settings.get()},
      acknowledger: Broadway.NoopAcknowledger.init()
    }

    AlbumUpload.run(message, context)
  end

  # A claimed album entry with its prepared files (a leftover source too), as
  # Angler.Pipeline.Job leaves it: returns the entry and the items to send.
  defp prepared_album(types, attrs \\ []) do
    entry = claimed_entry(attrs)
    {:ok, dir, entry} = Storage.prepare_dir(entry)
    File.mkdir_p!(Path.join(dir, "album/01"))
    File.write!(Path.join(dir, "album/01/source.jpg"), "downloaded")
    File.write!(Path.join(dir, "thumbnail.jpg"), @jpeg)

    items =
      types |> Enum.with_index(1) |> Enum.map(fn {type, n} -> prepared_item(dir, type, n) end)

    media_items =
      Enum.map(items, fn {item, relative} ->
        MediaItem.new(Map.merge(item, relative))
      end)

    entry =
      entry
      |> Entries.update!(%{
        media_kind: :album,
        title: attrs[:title],
        media_items: media_items
      })
      |> Storage.record_usage()

    album =
      Enum.map(items, fn {item, _relative} ->
        %{
          type: item.type,
          media: {:path, item.path},
          width: item.width,
          height: item.height,
          duration: item.duration,
          thumbnail: item.thumbnail
        }
      end)

    {entry, album}
  end

  defp prepared_item(dir, type, n) do
    name = "album/" <> String.pad_leading("#{n}", 2, "0")
    File.mkdir_p!(Path.join(dir, name))

    case type do
      :photo ->
        path = Path.join([dir, name, "photo.jpg"])
        File.write!(path, FakeMedia.photo_bytes())

        item = %{
          type: :photo,
          path: path,
          thumbnail: nil,
          width: 1080,
          height: 1350,
          duration: nil
        }

        {item, %{path: name <> "/photo.jpg", thumbnail: nil}}

      :video ->
        path = Path.join([dir, name, "video.mp4"])
        thumbnail = Path.join([dir, name, "thumbnail.jpg"])
        File.write!(path, FakeMedia.video_bytes())
        File.write!(thumbnail, @jpeg)

        item = %{
          type: :video,
          path: path,
          thumbnail: thumbnail,
          width: 720,
          height: 1280,
          duration: 12
        }

        {item, %{path: name <> "/video.mp4", thumbnail: name <> "/thumbnail.jpg"}}
    end
  end

  defp claimed_entry(attrs) do
    chat_id = Keyword.get_lazy(attrs, :chat_id, &unique_id/0)

    {:ok, [_entry]} =
      Entries.enqueue([
        %{
          url: "https://www.instagram.com/p/#{unique_id()}/",
          chat_id: chat_id,
          chat_type: Keyword.get(attrs, :chat_type, "private"),
          message_thread_id: attrs[:message_thread_id],
          message_id: unique_id()
        }
      ])

    [entry] = Entries.claim(1)
    entry
  end

  # As if the first item had been delivered before the upload was interrupted.
  defp deliver_first_item(%Entry{media_items: [first | rest]} = entry) do
    Entries.update!(entry, %{
      media_items: [%{first | file_id: "AgAC1", file_unique_id: "AQAD1"} | rest]
    })
  end

  # Answers the album's parts in order with `responses` (fun(conn)). The first
  # part books a rate limiter slot per item: the limiter forgets the chat's
  # bookings, so the next part goes right away.
  defp stub_parts(entry, responses) do
    calls = :counters.new(1, [])

    stub_bot_api(%{
      "sendMediaGroup" => fn conn ->
        :counters.add(calls, 1, 1)
        forget_chat(entry.chat_id)
        Enum.at(responses, :counters.get(calls, 1) - 1).(conn)
      end
    })
  end

  defp forget_chat(chat_id) do
    :sys.replace_state(RateLimiter, fn state ->
      %{state | chats: Map.delete(state.chats, chat_id)}
    end)
  end

  defp api_error_response(conn, code, description, parameters \\ nil) do
    conn
    |> Plug.Conn.put_status(code)
    |> Req.Test.json(api_error(code, description, parameters))
  end

  defp read_upload(conn, name), do: File.read!(conn.body_params[name].path)

  # What Finch reports in the calling process once a request was sent completely.
  defp request_sent, do: :telemetry.execute([:finch, :recv, :start], %{}, %{})

  # Writes of an album's progress (file ids while uploading) fail like a database
  # outage would (rolled back with the test's transaction).
  defp fail_progress_updates do
    for sql <- [
          """
          CREATE FUNCTION test_outage() RETURNS trigger AS $$
          BEGIN
            IF NEW.status = 'uploading' AND NEW.media_items[1]->>'file_id' IS NOT NULL THEN
              RAISE EXCEPTION 'simulated database outage';
            END IF;
            RETURN NEW;
          END $$ LANGUAGE plpgsql
          """,
          "CREATE TRIGGER test_outage BEFORE UPDATE ON entries " <>
            "FOR EACH ROW EXECUTE FUNCTION test_outage()"
        ] do
      Repo.query!(sql)
    end
  end
end
