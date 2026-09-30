defmodule Angler.Pipeline.AlbumTest do
  # Runs whole pipelines with Angler.FakeMedia (see Angler.PipelineTest): posts
  # with photos are sent as albums, and never twice.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  alias Angler.{Entries, FakeMedia, Pipeline, Storage}
  alias Angler.Entries.{Entry, MediaItem}

  @moduletag :capture_log
  @moduletag :tmp_dir

  # Generous: an album of 12 waits for 6 rate limiter slots between its parts.
  @timeout 15_000
  @jpeg <<0xFF, 0xD8, 0xFF, 0xD9>>

  setup %{tmp_dir: tmp_dir} do
    media_config = Application.fetch_env!(:angler, Angler.Media)
    Application.put_env(:angler, Angler.Media, Keyword.put(media_config, :data_dir, tmp_dir))
    on_exit(fn -> Application.put_env(:angler, Angler.Media, media_config) end)

    Req.Test.set_req_test_to_shared()
    stub_bot_api()
    Process.register(self(), FakeMedia)
    :ok = Entries.subscribe()
    :ok
  end

  describe "delivery" do
    test "downloads, prepares and replies with the photos and videos of a post" do
      start_pipeline()
      chat_id = unique_id()
      sent = sent_media_group(chat_id, [:photo, :video])
      test = self()

      stub_bot_api(%{
        "sendMediaGroup" => fn conn ->
          uploads = for part <- ["file0", "file1"], do: File.read!(conn.body_params[part].path)
          send(test, {:uploaded, uploads})
          Req.Test.json(conn, api_ok(sent))
        end
      })

      url = "https://fake.test/album/#{unique_id()}"
      {:ok, [entry]} = enqueue(url, chat_id, message_id: 42)
      id = entry.id

      for status <- [:downloading, :processing, :uploading, :done] do
        assert_receive {:entry_updated, %Entry{id: ^id, status: ^status}}, @timeout
      end

      assert_received {:entry_progress, ^id, %{stage: :downloading, detail: "Downloading 1/2"}}
      assert_received {:entry_progress, ^id, %{stage: :processing, detail: "Preparing 2/2"}}

      # One album replying to the link, the post text as its caption.
      assert_received {:uploaded, [photo, video]}
      assert photo == FakeMedia.photo_bytes()
      assert video == FakeMedia.video_bytes()
      assert_received {:bot_api, "sendMediaGroup", params}

      assert [
               %{"type" => "photo", "media" => "attach://file0", "caption" => "Fake album"},
               %{"type" => "video", "media" => "attach://file1", "thumbnail" => "attach://thumb1"}
             ] = Jason.decode!(params["media"])

      assert Jason.decode!(params["reply_parameters"])["message_id"] == 42

      [photo_message, video_message] = sent
      photo_file = Enum.max_by(photo_message["photo"], &(&1["width"] * &1["height"]))

      assert %Entry{
               media_kind: :album,
               title: "Fake album",
               width: 1080,
               height: 1350,
               duration: nil,
               video_codec: nil,
               transcoded: true,
               telegram_file_id: nil,
               reused_file_id: false,
               media_items: [photo_item, video_item]
             } = done = Entries.get(id)

      assert done.output_bytes == byte_size(photo) + byte_size(video)
      assert done.reply_message_id == photo_message["message_id"]

      assert %MediaItem{
               type: :photo,
               path: "album/01/photo.jpg",
               thumbnail: nil,
               width: 1080,
               height: 1350
             } = photo_item

      assert photo_item.bytes == byte_size(photo)
      assert photo_item.file_id == photo_file["file_id"]

      assert %MediaItem{
               type: :video,
               path: "album/02/video.mp4",
               thumbnail: "album/02/thumbnail.jpg",
               duration: 12.0
             } = video_item

      assert video_item.file_id == video_message["video"]["file_id"]

      # The items, their thumbnails and the cover are kept.
      assert length(Storage.album_files(done)) == 4

      assert_receive {:bot_api, "sendChatAction", %{"action" => "upload_video"}}, @timeout
      assert_reactions(chat_id, ["👀"])
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout

      # Albums are never re-sent from Telegram's cache: the next link downloads again.
      stub_bot_api(%{"sendMediaGroup" => sent_media_group(chat_id, [:photo, :video])})
      {:ok, [again]} = enqueue(url, chat_id)
      again_id = again.id
      assert_receive {:entry_updated, %Entry{id: ^again_id, status: :done}}, @timeout
      assert_received {:fake_media, :download, ^url, _dir, _opts}
      assert_received {:fake_media, :download, ^url, _dir, _opts}
      assert_received {:bot_api, "sendMediaGroup", %{"file0" => %Plug.Upload{}}}
      assert_receive {:bot_api, "sendChatAction", %{"action" => "upload_video"}}, @timeout
      assert_reactions(chat_id, ["👀"])
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "sends more than 10 items in parts, after the rate limiter slots of the first" do
      start_pipeline()
      chat_id = unique_id()
      first = sent_media_group(chat_id, List.duplicate(:photo, 6))
      second = sent_media_group(chat_id, List.duplicate(:photo, 6))
      url = "https://fake.test/album-12/#{unique_id()}"
      calls = :counters.new(1, [])
      test = self()

      stub_bot_api(%{
        "sendMediaGroup" => fn conn ->
          :counters.add(calls, 1, 1)

          case :counters.get(calls, 1) do
            1 ->
              Req.Test.json(conn, api_ok(first))

            _second ->
              entry = Repo.one!(from e in Entry, where: e.url == ^url)
              delivered = Enum.count(entry.media_items, &MediaItem.delivered?/1)
              send(test, {:delivered_before_second_part, delivered})
              Req.Test.json(conn, api_ok(second))
          end
        end
      })

      {:ok, [entry]} = enqueue(url, chat_id)
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :done} = done}, @timeout
      assert_received {:delivered_before_second_part, 6}
      assert :counters.get(calls, 1) == 2
      assert Enum.all?(done.media_items, &MediaItem.delivered?/1)
      assert length(done.media_items) == 12
      assert done.reply_message_id == hd(first)["message_id"]

      assert_receive {:bot_api, "sendChatAction", %{"action" => "upload_photo"}}, @timeout
      assert_reactions(chat_id, ["👀"])
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "sends a post text too long for a caption as a message after the album" do
      start_pipeline()
      chat_id = unique_id()
      sent = sent_media_group(chat_id, [:photo, :video])
      stub_bot_api(%{"sendMediaGroup" => sent})

      {:ok, [entry]} = enqueue("https://fake.test/album-long-text/#{unique_id()}", chat_id)
      id = entry.id
      assert_receive {:entry_updated, %Entry{id: ^id, status: :done} = done}, @timeout

      assert_received {:bot_api, "sendMediaGroup", params}
      refute params["media"] |> Jason.decode!() |> Enum.any?(&Map.has_key?(&1, "caption"))

      assert_receive {:bot_api, "sendMessage", %{"text" => text} = follow_up}, @timeout
      assert text == done.title
      assert String.length(text) == 1500
      assert follow_up["reply_parameters"]["message_id"] == hd(sent)["message_id"]
      assert follow_up["disable_notification"] == true

      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reactions(chat_id, ["👀"])
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end
  end

  describe "failures" do
    test "an album Telegram refused is downloaded and sent again" do
      start_pipeline()
      chat_id = unique_id()
      calls = :counters.new(1, [])

      stub_bot_api(%{
        "sendMediaGroup" => fn conn ->
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) == 1,
            do: conn |> Plug.Conn.put_status(502) |> Req.Test.json(api_error(502, "Bad Gateway")),
            else: Req.Test.json(conn, api_ok(sent_media_group(chat_id, [:photo, :video])))
        end
      })

      url = "https://fake.test/album/#{unique_id()}"
      {:ok, [entry]} = enqueue(url, chat_id, max_attempts: 3)
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :queued, error_kind: :transient}},
                     @timeout

      assert_receive {:entry_updated, %Entry{id: ^id, status: :done, attempts: 2} = done},
                     @timeout

      # Albums are prepared again, never re-used from an earlier attempt.
      assert_received {:fake_media, :download, ^url, _dir, _opts}
      assert_received {:fake_media, :download, ^url, _dir, _opts}
      assert Enum.all?(done.media_items, &MediaItem.delivered?/1)

      assert_reactions(chat_id, ["👀"])
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
    end

    test "an album Telegram never confirmed is not sent again" do
      start_pipeline()
      chat_id = unique_id()

      stub_bot_api(%{
        "sendMediaGroup" => fn conn ->
          :telemetry.execute([:finch, :recv, :start], %{}, %{})
          Req.Test.transport_error(conn, :closed)
        end
      })

      {:ok, [entry]} = enqueue("https://fake.test/album/#{unique_id()}", chat_id)
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :failed} = failed}, @timeout
      assert %Entry{attempts: 1, error_kind: :telegram, purged_at: nil} = failed
      assert failed.error =~ "did not confirm"
      assert length(Storage.album_files(failed)) == 4

      assert_received {:bot_api, "sendMediaGroup", _params}
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reactions(chat_id, ["👀"])
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      refute_receive {:bot_api, "sendMediaGroup", _params}, 300
      refute_received {:bot_api, "sendMessage", _params}
    end
  end

  describe "restart recovery" do
    test "an album interrupted after a part was delivered is never sent again" do
      chat_id = unique_id()
      entry = interrupted_album(chat_id)

      start_pipeline()

      id = entry.id
      assert_receive {:entry_updated, %Entry{id: ^id, status: :failed} = failed}, @timeout
      assert_partly_sent(failed, "Only 1 of 2 items were sent: the upload was interrupted")
      assert failed.attempts == 2

      refute_received {:fake_media, :download, _url, _dir, _opts}
      refute_received {:bot_api, "sendMediaGroup", _params}
      refute_received {:bot_api, "sendVideo", _params}

      assert_receive {:bot_api, "sendMessage",
                      %{"chat_id" => ^chat_id, "text" => "Only 1 of 2 items could be sent."}},
                     @timeout

      assert_reactions(chat_id, ["👎"])
    end

    test "on its last attempt too" do
      chat_id = unique_id()
      entry = interrupted_album(chat_id, %{attempts: 3})

      start_pipeline()

      assert_receive {:bot_api, "sendMessage",
                      %{"chat_id" => ^chat_id, "text" => "Only 1 of 2 items could be sent."}},
                     @timeout

      assert_partly_sent(
        Entries.get(entry.id),
        "Only 1 of 2 items were sent: the upload was interrupted"
      )

      assert_reactions(chat_id, ["👎"])
    end

    test "with a local Bot API server, which may still post the rest" do
      telegram_config = Application.fetch_env!(:angler, Angler.Telegram)

      Application.put_env(
        :angler,
        Angler.Telegram,
        Keyword.put(telegram_config, :local_mode, true)
      )

      on_exit(fn -> Application.put_env(:angler, Angler.Telegram, telegram_config) end)

      chat_id = unique_id()
      entry = interrupted_album(chat_id)

      start_pipeline()

      assert_receive {:bot_api, "setMessageReaction", %{"chat_id" => ^chat_id, "reaction" => []}},
                     @timeout

      assert_partly_sent(
        Entries.get(entry.id),
        "1 of 2 items were confirmed; the rest may still appear in the chat"
      )

      refute_receive {:bot_api, "sendMessage", _params}, 300
    end

    test "an album sent again from the dashboard and interrupted before its job ran is sent whole" do
      chat_id = unique_id()
      entry = interrupted_album(chat_id)
      delivered = Enum.map(entry.media_items, &%{&1 | file_id: &1.file_id || "BAAC2"})
      done = Entries.mark_done(entry, %{media_items: delivered})

      # Sent again, claimed, and a restart before the job cleared the old delivery.
      {:ok, _requeued} = Entries.retry(done)
      [_claimed] = Entries.claim(1)
      stub_bot_api(%{"sendMediaGroup" => sent_media_group(chat_id, [:photo, :video])})
      flush_entry_updates()

      start_pipeline()

      id = entry.id
      assert_receive {:entry_updated, %Entry{id: ^id, status: :done} = sent}, @timeout
      assert Enum.all?(sent.media_items, &MediaItem.delivered?/1)
      assert_received {:bot_api, "sendMediaGroup", _params}
      refute_received {:bot_api, "sendMessage", _params}
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
    end

    test "sending it again from the dashboard sends the whole album" do
      chat_id = unique_id()
      entry = interrupted_album(chat_id)
      Entries.mark_failed(entry, :telegram, "Only 1 of 2 items were sent")
      {:ok, _entry} = Entries.retry(Entries.get(entry.id))
      stub_bot_api(%{"sendMediaGroup" => sent_media_group(chat_id, [:photo, :video])})

      start_pipeline()

      id = entry.id
      assert_receive {:entry_updated, %Entry{id: ^id, status: :done} = done}, @timeout
      assert_received {:fake_media, :download, _url, _dir, _opts}
      assert_received {:bot_api, "sendMediaGroup", _params}
      assert Enum.all?(done.media_items, &MediaItem.delivered?/1)

      assert_reactions(chat_id, ["👀"])
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
    end
  end

  defp start_pipeline do
    start_supervised!(
      {Pipeline,
       enabled: true,
       name: :"#{inspect(__MODULE__)}.Pipeline#{unique_id()}",
       media: FakeMedia,
       retry_base_delay: 10,
       poll_interval: 50}
    )
  end

  defp enqueue(url, chat_id, attrs \\ []) do
    [url: url, chat_id: chat_id, chat_type: "private", message_id: unique_id()]
    |> Keyword.merge(attrs)
    |> Map.new()
    |> List.wrap()
    |> Entries.enqueue()
  end

  # An album entry whose upload stopped (a restart) after its first item was
  # delivered and recorded.
  defp interrupted_album(chat_id, attrs \\ %{}) do
    {:ok, [_entry]} = enqueue("https://fake.test/album/#{unique_id()}", chat_id)
    [entry] = Entries.claim(1)
    {:ok, dir, entry} = Storage.prepare_dir(entry)

    for {name, content} <- [
          {"album/01/photo.jpg", FakeMedia.photo_bytes()},
          {"album/02/video.mp4", FakeMedia.video_bytes()},
          {"album/02/thumbnail.jpg", @jpeg},
          {"thumbnail.jpg", @jpeg}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(dir, name)))
      File.write!(Path.join(dir, name), content)
    end

    items = [
      MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", file_id: "AgAC1"}),
      MediaItem.new(%{
        type: :video,
        path: "album/02/video.mp4",
        thumbnail: "album/02/thumbnail.jpg"
      })
    ]

    entry
    |> Storage.record_usage()
    |> Entries.update!(
      Map.merge(
        %{status: :uploading, media_kind: :album, title: "Fake album", media_items: items},
        attrs
      )
    )
  end

  defp flush_entry_updates do
    receive do
      {:entry_updated, _entry} -> flush_entry_updates()
    after
      0 -> :ok
    end
  end

  defp assert_partly_sent(entry, error) do
    assert %Entry{status: :failed, error_kind: :telegram, error: ^error, purged_at: nil} = entry
    assert [%MediaItem{file_id: "AgAC1"}, %MediaItem{file_id: nil}] = entry.media_items
    assert length(Storage.album_files(entry)) == 4
  end

  # Feedback runs in tasks: wait for them, so none outlives the test's stubs.
  defp assert_reactions(chat_id, emojis) do
    for emoji <- emojis do
      assert_receive {:bot_api, "setMessageReaction",
                      %{"chat_id" => ^chat_id, "reaction" => [%{"emoji" => ^emoji}]}},
                     @timeout
    end
  end
end
