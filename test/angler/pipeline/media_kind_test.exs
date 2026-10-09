defmodule Angler.Pipeline.MediaKindTest do
  # Runs whole pipelines with Angler.FakeMedia (see Angler.PipelineTest): entries
  # remember whether they were a video or a TikTok slideshow, and media learns
  # whether a failed download will be retried (slideshows only leave out files on
  # the final attempt).
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  alias Angler.{Entries, FakeMedia, Pipeline}
  alias Angler.Entries.Entry

  @moduletag :capture_log
  @moduletag :tmp_dir

  @timeout 10_000

  setup %{tmp_dir: tmp_dir} do
    media_config = Application.fetch_env!(:angler, Angler.Media)
    Application.put_env(:angler, Angler.Media, Keyword.put(media_config, :data_dir, tmp_dir))
    on_exit(fn -> Application.put_env(:angler, Angler.Media, media_config) end)

    Req.Test.set_req_test_to_shared()
    stub_bot_api(%{"sendVideo" => &Req.Test.json(&1, api_ok(sent_video(0)))})
    Process.register(self(), FakeMedia)
    :ok = Entries.subscribe()

    start_supervised!(
      {Pipeline,
       enabled: true,
       name: :"#{inspect(__MODULE__)}.Pipeline#{unique_id()}",
       media: FakeMedia,
       retry_base_delay: 10,
       poll_interval: 50}
    )

    :ok
  end

  defp deliver(url, chat_id \\ unique_id()) do
    {:ok, [entry]} =
      Entries.enqueue([
        %{url: url, chat_id: chat_id, chat_type: "private", message_id: unique_id()}
      ])

    id = entry.id
    assert_receive {:entry_updated, %Entry{id: ^id, status: :done}}, @timeout
    done = Entries.get(id)

    # Feedback runs in tasks: wait for all of them, so none outlives the stubs.
    assert_receive {:bot_api, "setMessageReaction",
                    %{"chat_id" => ^chat_id, "reaction" => [%{"emoji" => "👀"}]}},
                   @timeout

    assert_receive {:bot_api, "setMessageReaction", %{"chat_id" => ^chat_id, "reaction" => []}},
                   @timeout

    unless done.reused_file_id do
      assert_receive {:bot_api, "sendChatAction", %{"chat_id" => ^chat_id}}, @timeout
    end

    done
  end

  test "stores the media kind of slideshows and videos" do
    slideshow_url = "https://fake.test/slideshow/#{unique_id()}"

    assert %Entry{media_kind: :slideshow, transcoded: true, title: "Fake video"} =
             deliver(slideshow_url)

    assert_received {:fake_media, :prepare, %Angler.Media.Download{kind: :slideshow}, _dir, _opts}

    assert %Entry{media_kind: :video} = deliver("https://fake.test/ok/#{unique_id()}")
  end

  test "tells media whether a transient failure will be retried" do
    url = "https://fake.test/transient/#{unique_id()}"
    chat_id = -1_000_000_000_000 - unique_id()

    {:ok, [entry]} =
      Entries.enqueue([
        %{
          url: url,
          chat_id: chat_id,
          chat_type: "supergroup",
          message_id: unique_id(),
          max_attempts: 2
        }
      ])

    id = entry.id
    assert_receive {:entry_updated, %Entry{id: ^id, status: :failed, attempts: 2}}, @timeout

    assert_received {:fake_media, :download, ^url, _dir, first}
    assert_received {:fake_media, :download, ^url, _dir, last}
    assert first[:final_attempt] == false
    assert last[:final_attempt] == true

    # Feedback runs in tasks: wait for them, so none outlives the stubs. The 👀
    # reaction is set once and stays while the entry is retried.
    for emoji <- ["👀", "🤷"] do
      assert_receive {:bot_api, "setMessageReaction",
                      %{"chat_id" => ^chat_id, "reaction" => [%{"emoji" => ^emoji}]}},
                     @timeout
    end
  end

  test "keeps the media kind when an earlier delivery's file is sent again" do
    url = "https://fake.test/slideshow/#{unique_id()}"
    assert %Entry{media_kind: :slideshow, reused_file_id: false} = deliver(url)

    assert %Entry{media_kind: :slideshow, reused_file_id: true} = deliver(url)
  end
end
