defmodule Angler.PipelineTest do
  # Starts whole pipelines: their stages and feedback tasks share the test's
  # database connection and Req.Test stubs.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  alias Angler.{Entries, FakeMedia, Pipeline, Settings, Storage}
  alias Angler.Entries.Entry

  @moduletag :capture_log
  @moduletag :tmp_dir

  # Generous: a single test waits for several attempts and rate limited sends.
  @timeout 10_000

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

  describe "start_link/1 and info/0" do
    test "returns :ignore when disabled" do
      assert Pipeline.start_link(enabled: false) == :ignore
    end

    test "reports whether the pipeline is running" do
      assert %{running: false, download_concurrency: 2, upload_concurrency: 2} = Pipeline.info()

      start_supervised!({Pipeline, enabled: true, media: FakeMedia, poll_interval: 50})
      assert %{running: true} = Pipeline.info()
      assert [_producer] = Broadway.producer_names(Pipeline)
    end

    test "refuses to start twice under the same name, leaving in-flight entries alone" do
      name = start_pipeline()
      {:ok, [entry]} = enqueue("https://fake.test/unsupported/#{unique_id()}", group_chat_id())
      entry_id = entry.id
      assert_receive {:entry_updated, %Entry{id: ^entry_id, status: :failed} = failed}, @timeout
      assert_reactions("👀", 1)
      assert_reactions("🤷", 1)

      # Pretend the running pipeline works on it: a second start must not recover it.
      Entries.update!(failed, %{status: :downloading})

      assert {:error, {:already_started, _pid}} =
               Pipeline.start_link(enabled: true, name: name, media: FakeMedia)

      assert %Entry{status: :downloading} = Entries.get(entry_id)
    end
  end

  describe "delivery" do
    test "downloads, prepares and replies with the video" do
      start_pipeline()
      chat_id = group_chat_id()
      sent = sent_video(chat_id)
      test = self()

      stub_bot_api(%{
        "sendVideo" => fn conn ->
          send(test, {:uploaded, File.read!(conn.body_params["video"].path)})
          Req.Test.json(conn, api_ok(sent))
        end
      })

      url = "https://fake.test/ok/#{unique_id()}"

      {:ok, [entry]} =
        enqueue(url, chat_id, chat_type: "supergroup", message_id: 42, message_thread_id: 7)

      id = entry.id

      for status <- [:downloading, :processing, :uploading] do
        assert_receive {:entry_updated, %Entry{id: ^id, status: ^status}}, @timeout
      end

      assert_receive {:entry_updated, %Entry{id: ^id, status: :done}}, @timeout

      # Media got the limits from the default settings and a directory for the entry.
      assert_received {:fake_media, :download, ^url, dir, download_opts}
      assert Path.basename(dir) == id
      assert download_opts[:target_bytes] == 50_000_000
      assert download_opts[:max_source_bytes] == 1_024_000_000
      assert download_opts[:max_duration] == 30 * 60
      assert is_function(download_opts[:on_progress], 1)
      assert_received {:fake_media, :prepare, %Angler.Media.Download{}, ^dir, prepare_opts}
      assert prepare_opts[:target_bytes] == 50_000_000

      assert_received {:entry_progress, ^id,
                       %{stage: :downloading, percent: 50.0, detail: "1.0 MB of 2.0 MB"}}

      assert_received {:entry_progress, ^id, %{stage: :processing, percent: 100.0}}

      assert_received {:entry_progress, ^id,
                       %{stage: :uploading, percent: nil, detail: "Sending to Telegram"}}

      # The upload: multipart with the video bytes intact, as a reply in the topic,
      # with the title as a plain-text caption.
      assert_received {:uploaded, video_bytes}
      assert video_bytes == FakeMedia.video_bytes()
      assert_received {:bot_api, "sendVideo", params}
      refute Map.has_key?(params, "parse_mode")

      assert %{
               "caption" => "Fake video",
               "message_thread_id" => "7",
               "duration" => "12",
               "width" => "720",
               "height" => "1280",
               "supports_streaming" => "true",
               "thumbnail" => "attach://thumb",
               "video" => %Plug.Upload{},
               "thumb" => %Plug.Upload{}
             } = params

      assert params["chat_id"] == Integer.to_string(chat_id)

      assert Jason.decode!(params["reply_parameters"]) ==
               %{"message_id" => 42, "allow_sending_without_reply" => true}

      # 👀 while working, the "sending video" action, then the reaction is cleared.
      assert_receive {:bot_api, "setMessageReaction",
                      %{"message_id" => 42, "reaction" => [%{"emoji" => "👀"}]}},
                     @timeout

      assert_receive {:bot_api, "sendChatAction",
                      %{"action" => "upload_video", "message_thread_id" => 7}},
                     @timeout

      assert_receive {:bot_api, "setMessageReaction", %{"message_id" => 42, "reaction" => []}},
                     @timeout

      assert %Entry{
               status: :done,
               attempts: 1,
               error: nil,
               error_kind: nil,
               title: "Fake video",
               extractor: "Fake",
               source_bytes: source_bytes,
               output_bytes: output_bytes,
               transcoded: true,
               duration: 12.0,
               width: 720,
               height: 1280,
               video_codec: "h264",
               reused_file_id: false,
               claimed_at: nil,
               finished_at: %DateTime{}
             } = done = Entries.get(id)

      assert source_bytes > 0
      assert output_bytes == byte_size(FakeMedia.video_bytes())
      assert done.telegram_file_id == sent["video"]["file_id"]
      assert done.telegram_file_unique_id == sent["video"]["file_unique_id"]
      assert done.reply_message_id == sent["message_id"]
    end

    test "re-sends the Telegram file of an earlier delivery of the same URL" do
      start_pipeline()

      stub_bot_api(%{
        "sendVideo" =>
          sent_video(0, %{
            "message_id" => 0,
            "video" => %{"file_id" => "FILE-1", "file_unique_id" => "UNIQUE-1"}
          })
      })

      url = "https://fake.test/ok/#{unique_id()}"
      {:ok, [first]} = enqueue(url, unique_id())
      first_id = first.id
      assert_receive {:entry_updated, %Entry{id: ^first_id, status: :done}}, @timeout
      assert_received {:fake_media, :download, ^url, _dir, _opts}
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout

      second_chat_id = unique_id()
      {:ok, [second]} = enqueue(url, second_chat_id, message_id: 5)
      second_id = second.id
      assert_receive {:entry_updated, %Entry{id: ^second_id, status: :done}}, @timeout

      # Sent by file_id: no media work, no upload, no thumbnail. The title of the
      # first delivery is the caption again.
      refute_received {:fake_media, :download, ^url, _dir, _opts}
      assert_received {:bot_api, "sendVideo", %{"chat_id" => ^second_chat_id} = params}

      assert params == %{
               "chat_id" => second_chat_id,
               "video" => "FILE-1",
               "caption" => "Fake video",
               "duration" => 12,
               "width" => 720,
               "height" => 1280,
               "supports_streaming" => true,
               "reply_parameters" => %{"message_id" => 5, "allow_sending_without_reply" => true}
             }

      assert %Entry{
               reused_file_id: true,
               telegram_file_id: "FILE-1",
               telegram_file_unique_id: "UNIQUE-1",
               # Scheduled messages come back with message_id 0: unknown.
               reply_message_id: nil,
               title: "Fake video",
               duration: 12.0,
               output_bytes: output_bytes,
               source_bytes: source_bytes
             } = Entries.get(second_id)

      assert output_bytes == Entries.get(first_id).output_bytes
      assert source_bytes == Entries.get(first_id).source_bytes

      assert_receive {:bot_api, "setMessageReaction",
                      %{"chat_id" => ^second_chat_id, "reaction" => []}},
                     @timeout

      refute_received {:bot_api, "sendChatAction", %{"chat_id" => ^second_chat_id}}
      assert_reactions("👀", 2)
    end

    test "sends no caption while titles are turned off" do
      {:ok, _setting} = Settings.update(%{"title_captions" => "false"})
      start_pipeline()
      stub_bot_api(%{"sendVideo" => sent_video(0)})

      {:ok, [entry]} = enqueue("https://fake.test/ok/#{unique_id()}", unique_id())
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :done, title: "Fake video"}},
                     @timeout

      assert_received {:bot_api, "sendVideo", params}
      refute Map.has_key?(params, "caption")

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reactions("👀", 1)
    end

    test "downloads again when Telegram rejects the cached file, even with one attempt" do
      url = "https://fake.test/ok/#{unique_id()}"
      older = done_entry(url, "OLDER-FILE")
      newest = done_entry(url, "NEWEST-FILE")
      start_pipeline()

      stub_bot_api(%{
        "sendVideo" => fn conn ->
          case conn.body_params["video"] do
            file_id when is_binary(file_id) ->
              conn
              |> Plug.Conn.put_status(400)
              |> Req.Test.json(
                api_error(400, "Bad Request: wrong file identifier/HTTP URL specified")
              )

            %Plug.Upload{} ->
              Req.Test.json(conn, api_ok(sent_video(0)))
          end
        end
      })

      {:ok, [entry]} = enqueue(url, unique_id(), max_attempts: 1)
      id = entry.id

      assert_receive {:entry_updated,
                      %Entry{id: ^id, status: :queued, error_kind: :transient, attempts: 0}},
                     @timeout

      assert_receive {:entry_updated, %Entry{id: ^id, status: :done}}, @timeout

      # The most recent cached file is tried first; afterwards no cached file is left.
      assert_received {:bot_api, "sendVideo", %{"video" => "NEWEST-FILE", "caption" => "Cached"}}

      assert_received {:bot_api, "sendVideo",
                       %{"video" => %Plug.Upload{}, "caption" => "Fake video"}}

      refute_received {:bot_api, "sendVideo", %{"video" => "OLDER-FILE"}}
      assert_received {:fake_media, :download, ^url, _dir, _opts}

      assert %Entry{attempts: 1, reused_file_id: false, telegram_file_id: file_id} =
               Entries.get(id)

      assert is_binary(file_id)
      assert Entries.get(newest.id).telegram_file_id == nil
      assert Entries.get(older.id).telegram_file_id == nil

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      # The reaction stays while the entry is retried.
      assert_reactions("👀", 1)
    end
  end

  describe "media failures" do
    test "fail right away for permanent kinds, with a reply in private chats" do
      start_pipeline()

      replies = %{
        "unsupported" => "I couldn't find anything to send at this link.",
        "unavailable" => "This post is private, removed or unavailable.",
        "too-large" => "This is too large or too long to send here (the limit is 50 MB)."
      }

      for {path, reply} <- replies do
        chat_id = unique_id()
        {:ok, [entry]} = enqueue("https://fake.test/#{path}/#{unique_id()}", chat_id)
        id = entry.id

        assert_receive {:entry_updated, %Entry{id: ^id, status: :failed} = failed}, @timeout
        assert failed.attempts == 1
        assert failed.error == "Fake #{failed.error_kind} failure"

        assert_receive {:bot_api, "sendMessage", %{"chat_id" => ^chat_id, "text" => ^reply}},
                       @timeout

        assert_receive {:bot_api, "setMessageReaction",
                        %{"chat_id" => ^chat_id, "reaction" => [%{"emoji" => "🤷"}]}},
                       @timeout
      end

      kinds = Enum.map(Entries.list(filter: :failed), & &1.error_kind)
      assert Enum.sort(kinds) == Enum.sort([:unsupported, :unavailable, :too_large])
      assert_reactions("👀", 3)
    end

    test "only reply in private chats by default" do
      start_pipeline()
      group_id = group_chat_id()
      {:ok, [entry]} = enqueue("https://fake.test/unsupported/#{unique_id()}", group_id)
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :failed}}, @timeout

      assert_receive {:bot_api, "setMessageReaction",
                      %{"chat_id" => ^group_id, "reaction" => [%{"emoji" => "🤷"}]}},
                     @timeout

      refute_receive {:bot_api, "sendMessage", _params}, 300
      assert_reactions("👀", 1)
    end

    test "are retried for transient kinds until max_attempts" do
      start_pipeline()
      url = "https://fake.test/transient/#{unique_id()}"
      {:ok, [entry]} = enqueue(url, group_chat_id(), max_attempts: 3)
      id = entry.id

      for attempts <- [1, 2] do
        assert_receive {:entry_updated,
                        %Entry{
                          id: ^id,
                          status: :queued,
                          error_kind: :transient,
                          attempts: ^attempts
                        }},
                       @timeout
      end

      assert_receive {:entry_updated, %Entry{id: ^id, status: :failed} = failed}, @timeout
      assert %Entry{attempts: 3, error_kind: :transient, error: "Fake transient failure"} = failed

      for _attempt <- 1..3, do: assert_received({:fake_media, :download, ^url, _dir, _opts})
      assert_reactions("👀", 1)
      assert_reactions("🤷", 1)
      refute_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👀"}]}}, 100
    end

    test "retry crashes and failed conversions as internal errors" do
      start_pipeline()
      crash = "https://fake.test/raise/#{unique_id()}"
      conversion = "https://fake.test/prepare-fails/#{unique_id()}"
      {:ok, [crashing]} = enqueue(crash, group_chat_id(), max_attempts: 2)
      {:ok, [failing]} = enqueue(conversion, group_chat_id(), max_attempts: 2)

      for entry <- [crashing, failing] do
        id = entry.id
        assert_receive {:entry_updated, %Entry{id: ^id, status: :failed}}, @timeout
      end

      assert %Entry{
               attempts: 2,
               error_kind: :internal,
               error: "** (RuntimeError) fake media crashed"
             } =
               Entries.get(crashing.id)

      assert %Entry{attempts: 2, error_kind: :internal, error: "ffmpeg exited with status 187"} =
               Entries.get(failing.id)

      assert_received {:fake_media, :prepare, _download, _dir, _opts}
      assert_received {:fake_media, :prepare, _download, _dir, _opts}
      assert_reactions("👀", 2)
      assert_reactions("🤷", 2)
    end
  end

  describe "Telegram failures" do
    test "429 is postponed without using an attempt or the prepared video" do
      start_pipeline()
      calls = :counters.new(1, [])

      stub_bot_api(%{
        "sendVideo" => fn conn ->
          :counters.add(calls, 1, 1)

          # The client itself retries twice; the pipeline retries the third 429.
          if :counters.get(calls, 1) <= 3 do
            conn
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(
              api_error(429, "Too Many Requests: retry after 0", %{"retry_after" => 0})
            )
          else
            Req.Test.json(conn, api_ok(sent_video(0)))
          end
        end
      })

      url = "https://fake.test/ok/#{unique_id()}"
      {:ok, [entry]} = enqueue(url, unique_id(), max_attempts: 1)
      id = entry.id

      assert_receive {:entry_updated,
                      %Entry{id: ^id, status: :queued, error_kind: :transient, attempts: 0}},
                     @timeout

      assert_receive {:entry_updated, %Entry{id: ^id, status: :done, attempts: 1}}, @timeout
      assert :counters.get(calls, 1) == 4

      # Downloaded and prepared once; the retry sent the same file.
      assert_received {:fake_media, :download, ^url, _dir, _opts}
      refute_received {:fake_media, :download, ^url, _dir, _opts}
      assert_received {:fake_media, :prepare, _download, _dir, _opts}
      refute_received {:fake_media, :prepare, _download, _dir, _opts}

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reactions("👀", 1)
    end

    test "429 with a long retry_after reschedules the entry" do
      start_pipeline()

      stub_bot_api(%{
        "sendVideo" => {:error, 429, "Too Many Requests: retry after 90", %{"retry_after" => 90}}
      })

      {:ok, [entry]} = enqueue("https://fake.test/ok/#{unique_id()}", unique_id())
      id = entry.id

      assert_receive {:entry_updated,
                      %Entry{id: ^id, status: :queued, error_kind: :transient, attempts: 0} =
                        queued},
                     @timeout

      assert DateTime.diff(queued.available_at, DateTime.utc_now()) in 85..90
      assert queued.error =~ "retry after 90"
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reactions("👀", 1)
    end

    test "a failed upload is retried with the video prepared by the first attempt" do
      start_pipeline()
      calls = :counters.new(1, [])
      test = self()

      stub_bot_api(%{
        "sendVideo" => fn conn ->
          :counters.add(calls, 1, 1)
          send(test, {:uploaded, File.read!(conn.body_params["video"].path)})

          case :counters.get(calls, 1) do
            1 -> conn |> Plug.Conn.put_status(502) |> Req.Test.json(api_error(502, "Bad Gateway"))
            # Nothing reached Telegram: safe to send again.
            2 -> Req.Test.transport_error(conn, :econnrefused)
            _ -> Req.Test.json(conn, api_ok(sent_video(0)))
          end
        end
      })

      url = "https://fake.test/ok/#{unique_id()}"
      {:ok, [entry]} = enqueue(url, group_chat_id(), max_attempts: 3)
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :done} = done}, @timeout
      assert %Entry{attempts: 3, output_bytes: output_bytes} = done
      assert output_bytes == byte_size(FakeMedia.video_bytes())

      assert_received {:fake_media, :download, ^url, _dir, _opts}
      refute_received {:fake_media, :download, ^url, _dir, _opts}

      for _attempt <- 1..3, do: assert_received({:uploaded, bytes} when bytes != "")
      assert Storage.video_path(Entries.get(id)) != nil
      assert_reactions("👀", 1)
    end

    test "an upload Telegram never confirmed is not sent again" do
      start_pipeline()
      chat_id = unique_id()

      # The request was sent, then the connection closed without an answer.
      stub_bot_api(%{
        "sendVideo" => fn conn ->
          request_sent()
          Req.Test.transport_error(conn, :closed)
        end
      })

      url = "https://fake.test/ok/#{unique_id()}"
      {:ok, [entry]} = enqueue(url, chat_id, max_attempts: 3)
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :failed} = failed}, @timeout

      assert %Entry{
               attempts: 1,
               error_kind: :telegram,
               error:
                 "Telegram did not confirm the upload in time; it may still appear in the chat"
             } = failed

      assert_received {:bot_api, "sendVideo", _params}
      assert_received {:fake_media, :download, ^url, _dir, _opts}

      # No failure feedback: the video may still appear. The reaction is cleared.
      assert_receive {:bot_api, "setMessageReaction", %{"chat_id" => ^chat_id, "reaction" => []}},
                     @timeout

      refute_receive {:bot_api, "sendMessage", _params}, 300
      refute_received {:bot_api, "sendVideo", _params}
      refute_received {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "🤷"}]}}

      # A local Bot API server may still be reading the video from its path.
      assert %Entry{status: :failed, purged_at: nil} = unconfirmed = Entries.get(id)
      assert Storage.video_path(unconfirmed) != nil
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reactions("👀", 1)
    end

    test "a delivery is recorded even while the database can't be reached" do
      start_pipeline(db_retry_delays: [10, 10, 10])
      fail_updates_to("done", 2)
      stub_bot_api(%{"sendVideo" => sent_video(0)})

      {:ok, [entry]} = enqueue("https://fake.test/ok/#{unique_id()}", unique_id())
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :done, attempts: 1}}, @timeout
      assert_received {:bot_api, "sendVideo", _params}
      refute_receive {:bot_api, "sendVideo", _params}, 300
      assert %Entry{status: :done, attempts: 1, error: nil} = Entries.get(id)

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reactions("👀", 1)
    end

    test "a blocked bot fails the entry without retries" do
      start_pipeline()
      chat_id = group_chat_id()

      stub_bot_api(%{
        "sendVideo" => {:error, 403, "Forbidden: bot was kicked from the supergroup chat"}
      })

      {:ok, [entry]} = enqueue("https://fake.test/ok/#{unique_id()}", chat_id)
      id = entry.id

      assert_receive {:entry_updated, %Entry{id: ^id, status: :failed} = failed}, @timeout
      assert %Entry{attempts: 1, error_kind: :telegram} = failed
      assert failed.error =~ "bot was kicked"

      assert_receive {:bot_api, "setMessageReaction",
                      %{"chat_id" => ^chat_id, "reaction" => [%{"emoji" => "🤷"}]}},
                     @timeout

      refute_receive {:bot_api, "sendMessage", _params}, 300
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      assert_reactions("👀", 1)
    end
  end

  describe "restart recovery" do
    test "queues entries interrupted by a restart again, failing those without attempts left" do
      test = self()

      stub_bot_api(%{
        "sendVideo" => fn conn ->
          send(test, {:uploaded, File.read!(conn.body_params["video"].path)})
          Req.Test.json(conn, api_ok(sent_video(0)))
        end
      })

      {:ok, [interrupted]} = enqueue("https://fake.test/ok/#{unique_id()}", unique_id())
      exhausted_chat_id = unique_id()
      {:ok, [exhausted]} = enqueue("https://fake.test/ok/#{unique_id()}", exhausted_chat_id)
      assert length(Entries.claim(2)) == 2

      # One was uploading the video it had prepared, one ran its last attempt.
      interrupted = prepared_entry(Entries.get!(interrupted.id))
      Entries.update!(interrupted, %{status: :uploading})
      {:ok, dir, exhausted} = Storage.prepare_dir(Entries.get!(exhausted.id))
      File.write!(Path.join(dir, "source.webm"), "partial download")
      Entries.update!(exhausted, %{attempts: 3})

      start_pipeline()

      interrupted_id = interrupted.id
      assert_receive {:entry_updated, %Entry{id: ^interrupted_id, status: :done} = done}, @timeout
      assert done.attempts == 2

      # Sent the prepared video without downloading it again.
      refute_received {:fake_media, :download, _url, _dir, _opts}
      assert_received {:uploaded, "prepared video"}

      assert %Entry{
               status: :failed,
               error_kind: :internal,
               error: "Interrupted by a restart after the last attempt",
               purged_at: %DateTime{},
               stored_bytes: 0
             } = Entries.get(exhausted.id)

      refute File.exists?(dir)

      # The usual failure feedback.
      assert_receive {:bot_api, "setMessageReaction",
                      %{"chat_id" => ^exhausted_chat_id, "reaction" => [%{"emoji" => "🤷"}]}},
                     @timeout

      assert_receive {:bot_api, "sendMessage",
                      %{
                        "chat_id" => ^exhausted_chat_id,
                        "text" => "Something went wrong while fetching this."
                      }},
                     @timeout

      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => []}}, @timeout
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
      # Recovered entries keep the reaction of their first attempt.
      refute_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "👀"}]}}, 100
    end

    test "with a local Bot API server, fails interrupted uploads instead of sending them again" do
      telegram_config = Application.fetch_env!(:angler, Angler.Telegram)

      Application.put_env(
        :angler,
        Angler.Telegram,
        Keyword.put(telegram_config, :local_mode, true)
      )

      on_exit(fn -> Application.put_env(:angler, Angler.Telegram, telegram_config) end)

      stub_bot_api(%{"sendVideo" => sent_video(0)})
      uploading_chat_id = unique_id()
      {:ok, [uploading]} = enqueue("https://fake.test/ok/#{unique_id()}", uploading_chat_id)
      processing_chat_id = unique_id()
      {:ok, [processing]} = enqueue("https://fake.test/ok/#{unique_id()}", processing_chat_id)
      assert length(Entries.claim(2)) == 2

      # The server may still be uploading the first one, and will post it.
      uploading = prepared_entry(Entries.get!(uploading.id))
      Entries.update!(uploading, %{status: :uploading})
      Entries.update!(Entries.get!(processing.id), %{status: :processing})

      start_pipeline()

      processing_id = processing.id
      assert_receive {:entry_updated, %Entry{id: ^processing_id, status: :done}}, @timeout
      assert_received {:bot_api, "sendVideo", %{"chat_id" => ^processing_chat_id}}

      assert %Entry{
               status: :failed,
               attempts: 1,
               error_kind: :telegram,
               error:
                 "Telegram did not confirm the upload in time; it may still appear in the chat",
               purged_at: nil
             } = failed = Entries.get(uploading.id)

      # Its video stays where the server reads it from.
      assert Storage.video_path(failed) != nil

      # The reaction is cleared, without failure feedback.
      assert_receive {:bot_api, "setMessageReaction",
                      %{"chat_id" => ^uploading_chat_id, "reaction" => []}},
                     @timeout

      assert_receive {:bot_api, "setMessageReaction",
                      %{"chat_id" => ^processing_chat_id, "reaction" => []}},
                     @timeout

      refute_receive {:bot_api, "sendMessage", _params}, 300
      refute_received {:bot_api, "sendVideo", %{"chat_id" => ^uploading_chat_id}}
      refute_received {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => "🤷"}]}}
      assert_receive {:bot_api, "sendChatAction", _params}, @timeout
    end

    test "with a local Bot API server, sends no post text on its own for an interrupted upload" do
      telegram_config = Application.fetch_env!(:angler, Angler.Telegram)

      Application.put_env(
        :angler,
        Angler.Telegram,
        Keyword.put(telegram_config, :local_mode, true)
      )

      on_exit(fn -> Application.put_env(:angler, Angler.Telegram, telegram_config) end)

      chat_id = unique_id()
      title = String.duplicate("Long title ", 200)
      {:ok, [entry]} = enqueue("https://fake.test/ok/#{unique_id()}", chat_id)
      [_claimed] = Entries.claim(1)

      # Its request may have been sent (with the text cut to fit the caption, see
      # Delivery.caption/1) or not: e.g. it was still waiting for its rate limiter slot.
      entry = prepared_entry(Entries.get!(entry.id))
      Entries.update!(entry, %{status: :uploading, title: title})

      start_pipeline()

      assert_receive {:bot_api, "setMessageReaction", %{"chat_id" => ^chat_id, "reaction" => []}},
                     @timeout

      assert %Entry{status: :failed, error_kind: :telegram} = Entries.get(entry.id)

      # The video may never appear: the text would be posted alone.
      refute_receive {:bot_api, "sendMessage", %{"chat_id" => ^chat_id}}, 1_500
      refute_received {:bot_api, "sendVideo", _params}
    end
  end

  defp start_pipeline(opts \\ []) do
    name = :"#{inspect(__MODULE__)}.Pipeline#{unique_id()}"

    start_supervised!(
      {Pipeline,
       Keyword.merge(
         [
           enabled: true,
           name: name,
           media: FakeMedia,
           retry_base_delay: 10,
           poll_interval: 50
         ],
         opts
       )}
    )

    name
  end

  defp enqueue(url, chat_id, attrs \\ []) do
    chat_type = if chat_id < 0, do: "supergroup", else: "private"

    [url: url, chat_id: chat_id, chat_type: chat_type, message_id: unique_id()]
    |> Keyword.merge(attrs)
    |> Map.new()
    |> List.wrap()
    |> Entries.enqueue()
  end

  defp done_entry(url, file_id) do
    {:ok, [entry]} = enqueue(url, unique_id())

    Entries.mark_done(entry, %{
      telegram_file_id: file_id,
      title: "Cached",
      duration: 3.0,
      width: 640,
      height: 360
    })
  end

  defp group_chat_id, do: -1_000_000_000_000 - unique_id()

  # An entry whose earlier attempt prepared its video.
  defp prepared_entry(entry) do
    {:ok, dir, entry} = Storage.prepare_dir(entry)
    %{video: video, thumbnail: thumbnail} = Storage.output_paths(dir)
    File.write!(video, "prepared video")
    File.write!(thumbnail, <<0xFF, 0xD8, 0xFF, 0xD9>>)

    Entries.update!(entry, %{
      output_bytes: byte_size("prepared video"),
      duration: 3.0,
      width: 640,
      height: 360
    })
  end

  # What Finch reports in the calling process once a request was sent completely.
  defp request_sent, do: :telemetry.execute([:finch, :recv, :start], %{}, %{})

  # The next `count` updates that set `status` fail like a database outage would
  # (rolled back with the test's transaction).
  defp fail_updates_to(status, count) do
    for sql <- [
          "CREATE SEQUENCE test_outage",
          """
          CREATE FUNCTION test_outage() RETURNS trigger AS $$
          BEGIN
            IF NEW.status = '#{status}' AND nextval('test_outage') <= #{count} THEN
              RAISE EXCEPTION 'simulated database outage';
            END IF;
            RETURN NEW;
          END $$ LANGUAGE plpgsql
          """,
          "CREATE TRIGGER test_outage BEFORE UPDATE ON entries " <>
            "FOR EACH ROW EXECUTE FUNCTION test_outage()"
        ] do
      Angler.Repo.query!(sql)
    end
  end

  # Feedback runs in tasks: wait for all of them, so none outlives the test's stubs.
  defp assert_reactions(emoji, count) do
    for _reaction <- 1..count do
      assert_receive {:bot_api, "setMessageReaction", %{"reaction" => [%{"emoji" => ^emoji}]}},
                     @timeout
    end
  end
end
