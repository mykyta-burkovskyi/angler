defmodule Angler.Media.TikTokDownloadTest do
  # How Angler.Media.download/3 routes TikTok links: photo posts to the slideshow
  # download, videos to yt-dlp with the canonical URL, and everything else to yt-dlp
  # as before. Changes the Angler.Media application environment (fake yt-dlp).
  use ExUnit.Case, async: false

  import Angler.TikTokFixtures

  alias Angler.Media
  alias Angler.Media.{Download, Error}

  @moduletag :tmp_dir
  @moduletag :capture_log
  @fake_ytdlp Path.expand("../../fixtures/media/fake-yt-dlp", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    ytdlp = Path.join(tmp_dir, "yt-dlp")
    File.cp!(@fake_ytdlp, ytdlp)
    File.chmod!(ytdlp, 0o755)

    dir = Path.join(tmp_dir, "entry")
    File.mkdir_p!(dir)

    original = Application.get_env(:angler, Media)
    on_exit(fn -> Application.put_env(:angler, Media, original) end)

    Application.put_env(
      :angler,
      Media,
      Keyword.merge(original,
        data_dir: Path.join(tmp_dir, "data"),
        ytdlp_path: ytdlp,
        cookies_file: nil,
        ytdlp_update_channel: nil
      )
    )

    %{dir: dir}
  end

  defp download(url, dir, opts \\ []) do
    Media.download(url, dir, Keyword.merge([target_bytes: 50_000_000], opts))
  end

  # The URL the fake yt-dlp was called with, or nil when it did not run.
  defp ytdlp_url(dir) do
    case File.read(Path.join(dir, "args.txt")) do
      {:ok, args} -> args |> String.split("\n", trim: true) |> List.last()
      {:error, :enoent} -> nil
    end
  end

  test "downloads photo posts as slideshows, without yt-dlp", %{dir: dir} do
    stub_tiktok(fn conn ->
      case conn.host do
        "vt.tiktok.com" ->
          redirect(conn, "https://www.tiktok.com/@/photo/7587154199058795796")

        "www.tiktok.com" ->
          Req.Test.html(
            conn,
            page(detail(slideshow_item("7587154199058795796", 3, audio_url: "")))
          )

        _cdn ->
          bytes(conn, "jpeg " <> conn.request_path)
      end
    end)

    assert {:ok, %Download{kind: :slideshow, images: images, audio_path: nil} = download} =
             download("https://vt.tiktok.com/ZSaVMnnpj/", dir, max_source_bytes: 1_000_000)

    assert Enum.map(images, &Path.relative_to(&1, dir)) ==
             ["slides/01.jpg", "slides/02.jpg", "slides/03.jpg"]

    assert download.path == Path.join(dir, "slides")
    assert download.extractor == "TikTok"
    assert download.webpage_url == "https://www.tiktok.com/@hullcity/photo/7587154199058795796"
    assert ytdlp_url(dir) == nil
  end

  test "hands TikTok videos to yt-dlp with the canonical URL", %{dir: dir} do
    stub_tiktok(fn conn ->
      Req.Test.html(conn, page(detail(video_item("7449708266168274208"))))
    end)

    # The fake yt-dlp does not know the URL: only the arguments matter here.
    assert {:error, %Error{kind: :unsupported}} =
             download("https://m.tiktok.com/@memezar/video/7449708266168274208?lang=en", dir)

    assert ytdlp_url(dir) == "https://www.tiktok.com/@/video/7449708266168274208"
  end

  test "falls back to yt-dlp with the original link when TikTok can't be read", %{dir: dir} do
    stub_tiktok(&Req.Test.transport_error(&1, :econnrefused))
    url = "https://www.tiktok.com/@memezar/video/7449708266168274208"

    assert {:error, %Error{kind: :unsupported}} = download(url, dir)
    assert ytdlp_url(dir) == url
  end

  test "fails photo posts whose page can't be read, which yt-dlp does not support", %{dir: dir} do
    stub_tiktok(&Plug.Conn.send_resp(&1, 503, ""))

    assert {:error, %Error{kind: :transient, message: "Could not load the TikTok post" <> _}} =
             download("https://www.tiktok.com/@hullcity/photo/7553302113757990166", dir)

    assert ytdlp_url(dir) == nil
  end

  test "reports deleted posts and expired short links without yt-dlp", %{dir: dir} do
    stub_tiktok(fn conn ->
      case conn.host do
        "vm.tiktok.com" -> redirect(conn, "https://www.tiktok.com/?_r=1")
        "www.tiktok.com" -> Req.Test.html(conn, page(status_detail(10204)))
      end
    end)

    assert {:error, %Error{kind: :unavailable, message: "This TikTok post was deleted"}} =
             download("https://www.tiktok.com/@ughuwhguweghw/video/1", dir)

    assert {:error,
            %Error{kind: :unavailable, message: "This TikTok link has expired or is invalid"}} =
             download("https://vm.tiktok.com/ZGdh4WUhr/", dir)

    assert ytdlp_url(dir) == nil
  end

  test "leaves other links to yt-dlp without asking TikTok", %{dir: dir} do
    stub_tiktok(fn _conn -> flunk("unexpected request to TikTok") end)

    assert {:ok, %Download{kind: :video, images: [], audio_path: nil}} =
             download("https://fake.test/ok", dir)

    assert ytdlp_url(dir) == "https://fake.test/ok"
  end
end
