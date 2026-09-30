defmodule Angler.Pipeline.DeliveryTest do
  # Changes the global Telegram and media configuration; feedback runs in tasks.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  alias Angler.{Entries, Settings, Storage}
  alias Angler.Entries.{Entry, MediaItem}
  alias Angler.Pipeline.{Caption, Delivery, RetryPolicy}

  @moduletag :tmp_dir
  @timeout 2_000

  setup %{tmp_dir: tmp_dir} do
    media_config = Application.fetch_env!(:angler, Angler.Media)
    telegram_config = Application.fetch_env!(:angler, Angler.Telegram)
    Application.put_env(:angler, Angler.Media, Keyword.put(media_config, :data_dir, tmp_dir))

    on_exit(fn ->
      Application.put_env(:angler, Angler.Media, media_config)
      Application.put_env(:angler, Angler.Telegram, telegram_config)
    end)

    stub_bot_api()
    %{telegram_config: telegram_config}
  end

  describe "caption/1" do
    test "cuts a text too long for a caption to fit it only with a local Bot API server",
         %{telegram_config: config} do
      title = String.duplicate("Long title 🎣 ", 200)
      entry = Entries.update!(claimed_entry(), %{title: title})
      text = String.trim(title)

      assert Delivery.caption(entry) == {nil, text}

      Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :local_mode, true))
      assert Delivery.caption(entry) == {Caption.build(title), text}
      assert Delivery.caption(%{entry | title: "A title"}) == {"A title", nil}
    end

    test "reads the settings of now" do
      entry = Entries.update!(claimed_entry(), %{title: "A title"})
      {:ok, _} = Settings.update(%{"title_captions" => "false"})

      assert Delivery.caption(entry) == {nil, nil}
    end
  end

  describe "settle_unconfirmed/2" do
    test "keeps the video a local Bot API server may still be uploading, even without retention",
         %{telegram_config: config} do
      Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :local_mode, true))
      {:ok, settings} = Settings.update(%{"retention_hours" => "0"})
      entry = unconfirmed_entry()

      assert %Entry{purged_at: nil, stored_bytes: stored_bytes} =
               settled = Delivery.settle_unconfirmed(entry, settings)

      assert stored_bytes > 0
      assert Storage.video_path(settled) != nil
      assert Storage.thumbnail_path(settled) != nil
      assert_reaction_cleared(entry)
    end

    test "keeps only the final files like a delivery, with retention" do
      {:ok, settings} = Settings.update(%{"retention_hours" => "24"})
      entry = unconfirmed_entry()

      settled = Delivery.settle_unconfirmed(entry, settings)

      assert %Entry{purged_at: nil} = settled
      assert Storage.video_path(settled) != nil
      refute File.exists?(Path.join(entry.storage_path, "source.webm"))
      assert_reaction_cleared(entry)
    end

    test "deletes the files in cloud mode without retention: the upload was sent whole" do
      {:ok, settings} = Settings.update(%{"retention_hours" => "0"})
      entry = unconfirmed_entry()

      assert %Entry{purged_at: %DateTime{}, stored_bytes: 0} =
               Delivery.settle_unconfirmed(entry, settings)

      refute File.exists?(entry.storage_path)
      assert_reaction_cleared(entry)
    end

    test "deletes leftovers of an entry that was sent by a cached file_id" do
      entry = Entries.update!(unconfirmed_entry(), %{reused_file_id: true})

      assert %Entry{purged_at: %DateTime{}} = Delivery.settle_unconfirmed(entry, Settings.get())
      assert_reaction_cleared(entry)
    end

    test "keeps the files of an album like a delivery" do
      {:ok, settings} = Settings.update(%{"retention_hours" => "24"})
      entry = unconfirmed_album()

      assert %Entry{purged_at: nil} = settled = Delivery.settle_unconfirmed(entry, settings)

      assert [photo, video, thumbnail, cover] = Storage.album_files(settled)
      assert Enum.all?([photo, video, thumbnail, cover], &File.regular?/1)
      refute File.exists?(Path.join(entry.storage_path, "album/01/source.jpg"))
      assert_reaction_cleared(entry)
    end

    test "keeps an album's files a local Bot API server may still be uploading",
         %{telegram_config: config} do
      Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :local_mode, true))
      {:ok, settings} = Settings.update(%{"retention_hours" => "0"})
      entry = unconfirmed_album()

      assert %Entry{purged_at: nil} = settled = Delivery.settle_unconfirmed(entry, settings)
      assert length(Storage.album_files(settled)) == 4
      assert_reaction_cleared(entry)
    end
  end

  describe "sent_file/1" do
    test "takes the largest size of a photo, whatever their order" do
      [small, medium, large] = sent_photo(1)["photo"]

      assert Delivery.sent_file(%{"photo" => [small, large, medium]}) == large
      assert Delivery.sent_file(%{"photo" => [large, small]}) == large
    end

    test "takes a video, also when Telegram converted it" do
      video = sent_video(1)["video"]

      assert Delivery.sent_file(%{"video" => video}) == video
      assert Delivery.sent_file(%{"animation" => video}) == video
      assert Delivery.sent_file(%{"document" => video}) == video
    end

    test "never raises on unexpected answers" do
      for sent <- [
            nil,
            true,
            [],
            %{},
            %{"photo" => []},
            %{"photo" => [nil, "x"]},
            %{"video" => 1}
          ] do
        assert Delivery.sent_file(sent) == %{}
      end

      assert Delivery.sent_file(%{"photo" => [%{"file_id" => "A"}]}) == %{"file_id" => "A"}
    end
  end

  test "message_id/1 is nil for scheduled messages and unexpected answers" do
    assert Delivery.message_id(%{"message_id" => 42}) == 42

    for sent <- [%{"message_id" => 0}, %{"message_id" => "42"}, %{}, nil, []] do
      assert Delivery.message_id(sent) == nil
    end
  end

  # An entry whose prepared video was sent, but Telegram never confirmed it.
  defp unconfirmed_entry do
    entry = claimed_entry()
    {:ok, dir, entry} = Storage.prepare_dir(entry)
    %{video: video, thumbnail: thumbnail} = Storage.output_paths(dir)
    File.write!(video, "prepared video")
    File.write!(thumbnail, <<0xFF, 0xD8, 0xFF, 0xD9>>)
    File.write!(Path.join(dir, "source.webm"), "downloaded video")

    entry
    |> Storage.record_usage()
    |> Entries.mark_failed(:telegram, RetryPolicy.unconfirmed_text())
  end

  # The same for an album of a photo and a video.
  defp unconfirmed_album do
    entry = claimed_entry()
    {:ok, dir, entry} = Storage.prepare_dir(entry)

    for {name, content} <- [
          {"album/01/photo.jpg", "photo"},
          {"album/01/source.jpg", "downloaded photo"},
          {"album/02/video.mp4", "video"},
          {"album/02/thumbnail.jpg", "thumbnail"},
          {"thumbnail.jpg", "cover"}
        ] do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    items = [
      MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", bytes: 5}),
      MediaItem.new(%{
        type: :video,
        path: "album/02/video.mp4",
        thumbnail: "album/02/thumbnail.jpg",
        bytes: 5,
        duration: 12
      })
    ]

    entry
    |> Entries.update!(%{media_kind: :album, media_items: items})
    |> Storage.record_usage()
    |> Entries.mark_failed(:telegram, RetryPolicy.unconfirmed_text())
  end

  defp claimed_entry do
    {:ok, [_entry]} =
      Entries.enqueue([
        %{
          url: "https://fake.test/ok/#{unique_id()}",
          chat_id: unique_id(),
          chat_type: "private",
          message_id: unique_id()
        }
      ])

    [entry] = Entries.claim(1)
    entry
  end

  defp assert_reaction_cleared(%Entry{chat_id: chat_id}) do
    assert_receive {:bot_api, "setMessageReaction", %{"chat_id" => ^chat_id, "reaction" => []}},
                   @timeout

    refute_received {:bot_api, "sendMessage", _params}
  end
end
