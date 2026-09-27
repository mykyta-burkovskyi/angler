defmodule Angler.Telegram.LocalModeTest do
  # Changes the global Telegram configuration.
  use ExUnit.Case, async: false

  import Angler.TelegramFixtures

  alias Angler.Telegram
  alias Angler.Telegram.Error

  setup do
    config = Application.fetch_env!(:angler, Angler.Telegram)

    Application.put_env(
      :angler,
      Angler.Telegram,
      Keyword.merge(config, local_mode: true, api_base_url: "http://telegram-bot-api:8081")
    )

    on_exit(fn -> Application.put_env(:angler, Angler.Telegram, config) end)
    %{chat_id: unique_id()}
  end

  @tag :tmp_dir
  test "send_video/3 passes local files as file:// URIs", %{chat_id: chat_id, tmp_dir: dir} do
    dir = Path.join(dir, "entry dir")
    File.mkdir_p!(dir)
    video = Path.join(dir, "video.mp4")
    thumbnail = Path.join(dir, "thumbnail.jpg")
    File.write!(video, "video")
    File.write!(thumbnail, "jpeg")
    test = self()

    Req.Test.stub(Angler.Telegram, fn conn ->
      send(test, {:request, conn.host, conn.port, conn.request_path, conn.body_params})
      Req.Test.json(conn, api_ok(sent_video(chat_id)))
    end)

    assert {:ok, _} =
             Telegram.send_video(chat_id, {:path, video},
               thumbnail: thumbnail,
               width: 1,
               height: 2
             )

    assert_received {:request, "telegram-bot-api", 8081, "/bot123456:TEST-TOKEN/sendVideo",
                     params}

    assert params == %{
             "chat_id" => chat_id,
             "video" => "file://" <> String.replace(video, " ", "%20"),
             "thumbnail" => "file://" <> String.replace(thumbnail, " ", "%20"),
             "width" => 1,
             "height" => 2,
             "supports_streaming" => true
           }

    assert String.starts_with?(params["video"], "file:///")
  end

  test "log_out_from_cloud/0 ignores the configured server" do
    test = self()

    Req.Test.stub(Angler.Telegram, fn conn ->
      send(test, {:request, conn.scheme, conn.host, conn.request_path})
      Req.Test.json(conn, api_ok(true))
    end)

    assert {:ok, true} = Telegram.log_out_from_cloud()
    assert_received {:request, :https, "api.telegram.org", "/bot123456:TEST-TOKEN/logOut"}

    assert {:ok, true} = Telegram.get_me()
    assert_received {:request, :http, "telegram-bot-api", "/bot123456:TEST-TOKEN/getMe"}
  end

  test "requests fail without a token" do
    config = Application.fetch_env!(:angler, Angler.Telegram)
    Application.put_env(:angler, Angler.Telegram, Keyword.put(config, :token, nil))
    stub_bot_api()

    assert {:error, %Error{method: "getMe", description: "TELEGRAM_BOT_TOKEN is not configured"}} =
             Telegram.get_me()

    refute_received {:bot_api, _, _}
  end
end
