defmodule Angler.Media.InstagramDownloadTest do
  # How Angler.Media.download/3 routes Instagram links: single videos (reels) to
  # yt-dlp with the canonical post URL and the post text as the title, hidden posts
  # to an error without yt-dlp, and other links to yt-dlp without asking Instagram.
  # Changes the Angler.Media application environment (fake yt-dlp).
  use ExUnit.Case, async: false

  import Angler.InstagramFixtures

  alias Angler.Media
  alias Angler.Media.{Download, Error}

  @moduletag :tmp_dir
  @moduletag :capture_log
  @fake_ytdlp Path.expand("../../fixtures/media/fake-yt-dlp", __DIR__)

  # The fake yt-dlp downloads a video for the post code "ok" (its title:
  # `A "quoted" title`).
  @reel "https://www.instagram.com/reel/ok/?igsh=abc"
  @canonical "https://www.instagram.com/p/ok/"

  setup %{tmp_dir: tmp_dir} do
    ytdlp = Path.join(tmp_dir, "yt-dlp")
    File.cp!(@fake_ytdlp, ytdlp)
    File.chmod!(ytdlp, 0o755)

    # yt-dlp's metadata of the reel: the video entry of a recorded carousel.
    [_photo, video] = ytdlp_entries("DduKfFmDxsG")
    reel = video |> Map.drop(~w(playlist_index playlist_id)) |> Map.put("id", "ok")
    File.mkdir_p!(Path.join(tmp_dir, "metadata"))
    File.write!(Path.join([tmp_dir, "metadata", "ok.jsonl"]), Jason.encode!(reel) <> "\n")

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
        ytdlp_update_channel: nil,
        allow_private_networks: false
      )
    )

    %{dir: dir}
  end

  defp download(url, dir), do: Media.download(url, dir, target_bytes: 50_000_000)

  # The URL the fake yt-dlp downloaded, or nil when it did not download anything.
  defp ytdlp_url(dir) do
    case File.read(Path.join(dir, "args.txt")) do
      {:ok, args} ->
        args = String.split(args, "\n", trim: true)
        if "--skip-download" in args, do: nil, else: List.last(args)

      {:error, :enoent} ->
        nil
    end
  end

  defp stub_reel(caption) do
    stub_graphql(%{"ok" => graphql_answer(post([video()], code: "ok", caption: caption))})
  end

  test "downloads a reel with yt-dlp, with the post text as its title", %{dir: dir} do
    stub_reel("The reel's text\n\n#tag")

    assert {:ok, %Download{kind: :video, title: "The reel's text\n\n#tag"} = download} =
             download(@reel, dir)

    assert download.path == Path.join(dir, "source.mp4")
    assert ytdlp_url(dir) == @canonical
  end

  test "keeps yt-dlp's title when the reel has no text", %{dir: dir} do
    for caption <- [nil, "  \n "] do
      stub_reel(caption)

      assert {:ok, %Download{title: ~s(A "quoted" title)}} = download(@reel, dir)
      assert ytdlp_url(dir) == @canonical
    end
  end

  test "downloads a reel yt-dlp's metadata found when Instagram can't be read", %{dir: dir} do
    stub_instagram(&Plug.Conn.send_resp(&1, 500, ""))

    assert {:ok, %Download{kind: :video, title: title}} = download(@reel, dir)
    assert title =~ "Ready to post your next photo dump?"
    assert ytdlp_url(dir) == @canonical
    refute File.exists?(Path.join(dir, "items.jsonl"))
  end

  test "reports hidden posts without yt-dlp", %{dir: dir} do
    stub_graphql(%{"ok" => graphql("DdwalmrkTSX")})

    assert {:error, %Error{kind: :unavailable, message: message}} = download(@reel, dir)
    assert message == "This Instagram post is private, deleted or age-restricted"
    refute File.exists?(Path.join(dir, "args.txt"))
  end

  test "leaves other links to yt-dlp without asking Instagram", %{dir: dir} do
    stub_instagram(fn _conn -> flunk("unexpected request to Instagram") end)

    assert {:ok, %Download{kind: :video}} = download("https://fake.test/ok", dir)
    assert ytdlp_url(dir) == "https://fake.test/ok"
  end
end
