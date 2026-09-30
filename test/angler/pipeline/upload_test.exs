defmodule Angler.Pipeline.UploadTest do
  # Changes the global Telegram and media configuration; feedback runs in tasks.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  alias Angler.{Entries, Media, Settings, Storage}
  alias Angler.Entries.Entry
  alias Angler.Pipeline.{Caption, Upload}
  alias Broadway.Message

  @moduletag :tmp_dir
  @timeout 2_000
  # The follow-up text waits for the chat's next rate limiter slot.
  @follow_up_timeout 5_000
  # Longer than that slot (1050 ms after the upload): no follow-up means none came.
  @no_follow_up_wait 1_500

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

    test "posts the caption when re-sending a cached file" do
      entry = claimed_entry("Catch of the day")
      run(entry, {{:file_id, "FILE-1"}, nil})

      assert_received {:bot_api, "sendVideo", %{"video" => "FILE-1"} = params}
      assert params["caption"] == "Catch of the day"
      refute Map.has_key?(params, "parse_mode")

      assert %Entry{status: :done, reused_file_id: true} = Entries.get(entry.id)
      assert_reaction_cleared(entry)
    end

    test "sends a title too long for a caption as a message replying to the video" do
      title = String.duplicate("Long title 🎣 ", 200)
      assert utf16_length(title) > 1024
      sent = sent_video(0)
      stub_bot_api(%{"sendVideo" => sent})
      {entry, video} = prepared_video(claimed_entry(title))
      run(entry, video)

      assert_received {:bot_api, "sendVideo", %{"video" => %Plug.Upload{}} = params}
      refute Map.has_key?(params, "caption")

      # After the video, without a notification; cut nowhere.
      assert_receive {:bot_api, "sendMessage", follow_up}, @follow_up_timeout
      assert follow_up["text"] == String.trim(title)
      assert follow_up["reply_parameters"]["message_id"] == sent["message_id"]
      assert follow_up["disable_notification"] == true
      assert follow_up["link_preview_options"] == %{"is_disabled" => true}
      refute Map.has_key?(follow_up, "parse_mode")

      assert %Entry{status: :done, reply_message_id: reply_message_id} = Entries.get(entry.id)
      assert reply_message_id == sent["message_id"]
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    test "replies to the original message when the video's message id is unknown" do
      stub_bot_api(%{"sendVideo" => sent_video(0, %{"message_id" => 0})})
      entry = claimed_entry(String.duplicate("a", 1100))
      run(entry, {{:file_id, "FILE-1"}, nil})

      assert_received {:bot_api, "sendVideo", params}
      refute Map.has_key?(params, "caption")

      assert_receive {:bot_api, "sendMessage", %{"text" => text} = follow_up},
                     @follow_up_timeout

      assert text == String.duplicate("a", 1100)
      assert follow_up["reply_parameters"]["message_id"] == entry.message_id
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    @tag :capture_log
    test "sends no title on its own when Telegram never confirmed the video" do
      title = String.duplicate("Long title 🎣 ", 200)
      stub_unconfirmed_video()
      {entry, video} = prepared_video(claimed_entry(title))
      run(entry, video)

      assert_received {:bot_api, "sendVideo", params}
      refute Map.has_key?(params, "caption")
      assert %Entry{status: :failed, error_kind: :telegram} = Entries.get(entry.id)
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout

      # The video may appear much later, or never: the text would come first, or alone.
      refute_receive {:bot_api, "sendMessage", _params}, @no_follow_up_wait
    end

    test "with a local Bot API server, also posts a title too long for a caption cut to fit it",
         %{telegram_config: config} do
      Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :local_mode, true))
      title = String.duplicate("Long title 🎣 ", 200)
      sent = sent_video(0)
      stub_bot_api(%{"sendVideo" => sent})
      {entry, video} = prepared_video(claimed_entry(title))
      run(entry, video)

      assert_received {:bot_api, "sendVideo", %{"video" => "file://" <> _path} = params}
      assert params["caption"] == Caption.build(title)
      assert String.ends_with?(params["caption"], "…")
      assert utf16_length(params["caption"]) <= 1024

      # Delivered: the whole text follows the video.
      assert_receive {:bot_api, "sendMessage", follow_up}, @follow_up_timeout
      assert follow_up["text"] == String.trim(title)
      assert follow_up["reply_parameters"]["message_id"] == sent["message_id"]
      assert %Entry{status: :done} = Entries.get(entry.id)
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
    end

    @tag :capture_log
    test "with a local Bot API server, an unconfirmed video carries the title cut to fit",
         %{telegram_config: config} do
      # E.g. an upload over 500 s: the server closes the connection, then posts it.
      Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :local_mode, true))
      title = String.duplicate("Long title 🎣 ", 200)
      stub_unconfirmed_video()
      {entry, video} = prepared_video(claimed_entry(title))
      run(entry, video)

      assert_received {:bot_api, "sendVideo", params}
      assert params["caption"] == Caption.build(title)
      assert %Entry{status: :failed, error_kind: :telegram} = Entries.get(entry.id)
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      refute_receive {:bot_api, "sendMessage", _params}, @no_follow_up_wait
    end

    test "sends no title too long for a caption when Telegram refused the video" do
      stub_bot_api(%{"sendVideo" => {:error, 400, "Bad Request: VIDEO_INVALID"}})
      {entry, {video, output}} = prepared_video(claimed_entry(String.duplicate("a", 1100)))

      message = %Message{
        data: %{entry: entry, video: video, output: output, settings: Settings.get()},
        acknowledger: Broadway.NoopAcknowledger.init()
      }

      assert %Message{status: {:failed, _failure}} = Upload.run(message, %{})
      assert_received {:bot_api, "sendVideo", _params}
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      refute_receive {:bot_api, "sendMessage", _params}, 300
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

  # The request was sent, then the connection closed without an answer.
  defp stub_unconfirmed_video do
    stub_bot_api(%{
      "sendVideo" => fn conn ->
        :telemetry.execute([:finch, :recv, :start], %{}, %{})
        Req.Test.transport_error(conn, :closed)
      end
    })
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

  defp assert_reaction_cleared(%Entry{chat_id: chat_id}) do
    assert_receive {:bot_api, "setMessageReaction", %{"chat_id" => ^chat_id, "reaction" => []}},
                   @timeout

    refute_received {:bot_api, "sendMessage", _params}
  end
end
