defmodule Angler.Pipeline.UploadTest do
  # Changes the global Telegram and media configuration; feedback runs in tasks.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  alias Angler.{Entries, Media, Settings, Storage}
  alias Angler.Entries.Entry
  alias Angler.Pipeline.{RetryPolicy, Upload}
  alias Broadway.Message

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

  describe "settle_unconfirmed/2" do
    test "keeps the video a local Bot API server may still be uploading, even without retention",
         %{telegram_config: config} do
      Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :local_mode, true))
      {:ok, settings} = Settings.update(%{"retention_hours" => "0"})
      entry = unconfirmed_entry()

      assert %Entry{purged_at: nil, stored_bytes: stored_bytes} =
               settled = Upload.settle_unconfirmed(entry, settings)

      assert stored_bytes > 0
      assert Storage.video_path(settled) != nil
      assert Storage.thumbnail_path(settled) != nil
      assert_reaction_cleared(entry)
    end

    test "keeps only the final files like a delivery, with retention" do
      {:ok, settings} = Settings.update(%{"retention_hours" => "24"})
      entry = unconfirmed_entry()

      settled = Upload.settle_unconfirmed(entry, settings)

      assert %Entry{purged_at: nil} = settled
      assert Storage.video_path(settled) != nil
      refute File.exists?(Path.join(entry.storage_path, "source.webm"))
      assert_reaction_cleared(entry)
    end

    test "deletes the files in cloud mode without retention: the upload was sent whole" do
      {:ok, settings} = Settings.update(%{"retention_hours" => "0"})
      entry = unconfirmed_entry()

      assert %Entry{purged_at: %DateTime{}, stored_bytes: 0} =
               Upload.settle_unconfirmed(entry, settings)

      refute File.exists?(entry.storage_path)
      assert_reaction_cleared(entry)
    end

    test "deletes leftovers of an entry that was sent by a cached file_id" do
      entry = Entries.update!(unconfirmed_entry(), %{reused_file_id: true})

      assert %Entry{purged_at: %DateTime{}} = Upload.settle_unconfirmed(entry, Settings.get())
      assert_reaction_cleared(entry)
    end
  end

  describe "run/2 captions" do
    setup do
      stub_bot_api(%{"sendVideo" => sent_video(0)})
      :ok
    end

    test "posts the title as the plain-text caption of an upload" do
      {entry, video} =
        prepared_video(
          claimed_entry("Fishing trip 🎣  \r\n\r\n\r\nDay 1: <b>no</b> *bites* @ann #fyp ")
        )

      run(entry, video)

      assert_received {:bot_api, "sendVideo", %{"video" => %Plug.Upload{}} = params}
      assert params["caption"] == "Fishing trip 🎣\n\nDay 1: <b>no</b> *bites* @ann #fyp"
      refute Map.has_key?(params, "parse_mode")
      refute Map.has_key?(params, "caption_entities")

      assert %Entry{status: :done} = Entries.get(entry.id)
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reaction_cleared(entry)
    end

    test "posts the caption with a file a local Bot API server reads from disk",
         %{telegram_config: config} do
      Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :local_mode, true))
      {entry, video} = prepared_video(claimed_entry("Catch of the day"))
      run(entry, video)

      assert_received {:bot_api, "sendVideo", %{"video" => "file://" <> _path} = params}
      assert params["caption"] == "Catch of the day"
      refute Map.has_key?(params, "parse_mode")

      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reaction_cleared(entry)
    end

    test "posts the caption when re-sending a cached file, trimmed to Telegram's limit" do
      title = String.duplicate("Long title 🎣 ", 200)
      entry = claimed_entry(title)
      run(entry, {{:file_id, "FILE-1"}, nil})

      assert_received {:bot_api, "sendVideo", %{"video" => "FILE-1"} = params}
      assert %{"caption" => caption} = params
      assert utf16_length(caption) <= 1024
      assert String.ends_with?(caption, "…")
      assert String.starts_with?(title, String.trim_trailing(caption, "…"))
      refute Map.has_key?(params, "parse_mode")

      assert %Entry{status: :done, reused_file_id: true} = Entries.get(entry.id)
      assert_reaction_cleared(entry)
    end

    test "sends no caption when titles are turned off, even after the entry was claimed" do
      # Read when the entry was claimed, with captions on; turned off since.
      claimed_settings = Settings.get()
      assert claimed_settings.title_captions
      {:ok, %{title_captions: false}} = Settings.update(%{"title_captions" => "false"})

      for kind <- [:upload, :file_id] do
        {entry, video} =
          case kind do
            :upload -> prepared_video(claimed_entry("A title"))
            :file_id -> {claimed_entry("A title"), {{:file_id, "FILE-1"}, nil}}
          end

        run(entry, video, claimed_settings)

        assert_received {:bot_api, "sendVideo", params}
        refute Map.has_key?(params, "caption")
        assert %Entry{status: :done} = Entries.get(entry.id)
        if kind == :upload, do: assert_receive({:bot_api, "sendChatAction", _params}, @timeout)
        assert_reaction_cleared(entry)
      end
    end

    test "posts the caption once titles are turned back on" do
      {:ok, _} = Settings.update(%{"title_captions" => "false"})
      claimed_settings = Settings.get()
      {:ok, %{title_captions: true}} = Settings.update(%{"title_captions" => "true"})
      entry = claimed_entry("A title")

      run(entry, {{:file_id, "FILE-1"}, nil}, claimed_settings)

      assert_received {:bot_api, "sendVideo", %{"caption" => "A title"}}
      assert_reaction_cleared(entry)
    end

    test "sends no caption for a missing or blank title, or one that is the link or id" do
      for title <- [nil, "", " \n\t ", :url, :id] do
        entry = claimed_entry(nil)
        [id] = entry.url |> URI.parse() |> Map.fetch!(:path) |> Path.split() |> Enum.take(-1)

        title =
          case title do
            :url -> entry.url
            :id -> id
            title -> title
          end

        entry = Entries.update!(entry, %{title: title})
        run(entry, {{:file_id, "FILE-1"}, nil})

        assert_received {:bot_api, "sendVideo", params}
        refute Map.has_key?(params, "caption"), "caption sent for the title #{inspect(title)}"
        assert_reaction_cleared(entry)
      end
    end
  end

  # Runs the upload step for an entry with its video and prepared output (nil for
  # a cached file), as the pipeline does; `settings` were read when it was claimed.
  defp run(entry, {video, output}, settings \\ Settings.get()) do
    message = %Message{
      data: %{entry: entry, video: video, output: output, settings: settings},
      acknowledger: Broadway.NoopAcknowledger.init()
    }

    assert %Message{status: :ok} = Upload.run(message, %{})
  end

  # A claimed entry with this title.
  defp claimed_entry(title) do
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
    Entries.update!(entry, %{title: title, duration: 3.0, width: 640, height: 360})
  end

  # Prepares a video for `entry`: returns the entry and `{video, output}`.
  defp prepared_video(entry) do
    {:ok, dir, entry} = Storage.prepare_dir(entry)
    %{video: video, thumbnail: thumbnail} = Storage.output_paths(dir)
    File.write!(video, "prepared video")
    File.write!(thumbnail, <<0xFF, 0xD8, 0xFF, 0xD9>>)

    output = %Media.Output{
      path: video,
      size: byte_size("prepared video"),
      thumbnail_path: thumbnail,
      duration: 3,
      width: 640,
      height: 360
    }

    {Storage.record_usage(entry), {{:path, video}, output}}
  end

  # An entry whose prepared video was sent, but Telegram never confirmed it.
  defp unconfirmed_entry do
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
    {:ok, dir, entry} = Storage.prepare_dir(entry)
    %{video: video, thumbnail: thumbnail} = Storage.output_paths(dir)
    File.write!(video, "prepared video")
    File.write!(thumbnail, <<0xFF, 0xD8, 0xFF, 0xD9>>)
    File.write!(Path.join(dir, "source.webm"), "downloaded video")

    entry
    |> Storage.record_usage()
    |> Entries.mark_failed(:telegram, RetryPolicy.unconfirmed_text())
  end

  defp assert_reaction_cleared(%Entry{chat_id: chat_id}) do
    assert_receive {:bot_api, "setMessageReaction", %{"chat_id" => ^chat_id, "reaction" => []}},
                   @timeout

    refute_received {:bot_api, "sendMessage", _params}
  end
end
