defmodule Angler.Media.YtdlpMetadataTest do
  # Angler.Media.Ytdlp.metadata/3 with the fake yt-dlp (test/fixtures/media/fake-yt-dlp).
  # Changes the Angler.Media application environment.
  use ExUnit.Case, async: false

  import Angler.InstagramFixtures, only: [fixture_path: 1]

  alias Angler.Media
  alias Angler.Media.{Error, Ytdlp}
  alias Angler.Media.Ytdlp.Metadata

  @moduletag :tmp_dir
  @moduletag :capture_log
  @fake_ytdlp Path.expand("../../fixtures/media/fake-yt-dlp", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    ytdlp = Path.join(tmp_dir, "yt-dlp")
    File.cp!(@fake_ytdlp, ytdlp)
    File.chmod!(ytdlp, 0o755)

    File.mkdir_p!(Path.join(tmp_dir, "metadata"))

    File.cp!(
      fixture_path("ytdlp_carousel_photo_video_DduKfFmDxsG.jsonl"),
      Path.join(tmp_dir, "metadata/DduKfFmDxsG.jsonl")
    )

    dir = Path.join(tmp_dir, "entry")
    File.mkdir_p!(dir)

    original = Application.get_env(:angler, Media)
    on_exit(fn -> Application.put_env(:angler, Media, original) end)

    put_media_env(
      data_dir: Path.join(tmp_dir, "data"),
      ytdlp_path: ytdlp,
      cookies_file: nil,
      ytdlp_update_channel: nil,
      allow_private_networks: false
    )

    %{dir: dir}
  end

  defp put_media_env(values) do
    Application.put_env(
      :angler,
      Media,
      Keyword.merge(Application.get_env(:angler, Media), values)
    )
  end

  defp recorded_args(dir),
    do: dir |> Path.join("args.txt") |> File.read!() |> String.split("\n", trim: true)

  defp value_after(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  test "returns every item of a post, read from the file yt-dlp prints them to", %{dir: dir} do
    url = "https://www.instagram.com/p/DduKfFmDxsG/"

    assert {:ok, [photo, video]} = Ytdlp.metadata(url, dir)
    assert %{"id" => "DduH-i6vAtD", "playlist_index" => 1, "formats" => []} = photo
    assert %{"id" => "DduH-0FD_Pc", "playlist_index" => 2, "formats" => [_ | _]} = video
    assert photo["description"] =~ "Ready to post your next photo dump?"

    args = recorded_args(dir)
    assert Enum.take(args, -2) == ["--", url]

    for flag <- ~w(--ignore-config --skip-download --ignore-no-formats-error --no-warnings),
        do: assert(flag in args)

    assert value_after(args, "--print-to-file") == "video:%()j"

    assert Enum.at(args, Enum.find_index(args, &(&1 == "--print-to-file")) + 2) ==
             Path.join(dir, "items.jsonl")

    assert value_after(args, "-P") == "home:" <> dir
    assert value_after(args, "--socket-timeout") == "30"
    assert value_after(args, "--extractor-retries") == "3"
    refute "--cookies" in args
    refute "--no-playlist" in args

    # Through the egress proxy, like downloads.
    assert "http://127.0.0.1:" <> _port = value_after(args, "--proxy")
    assert File.read!(Path.join(dir, "env.txt")) =~ "http_proxy=http://127.0.0.1:"

    refute File.exists?(Path.join(dir, "items.jsonl"))
    refute File.exists?(Path.join(dir, "tmp"))
  end

  test "gives yt-dlp a private copy of the cookies file and deletes it afterwards", %{
    dir: dir,
    tmp_dir: tmp_dir
  } do
    cookies = Path.join(tmp_dir, "cookies.txt")
    File.write!(cookies, ".instagram.com\tTRUE\t/\tTRUE\t0\tsessionid\tS3SSION\n")
    put_media_env(cookies_file: cookies)

    assert {:ok, [_, _]} = Ytdlp.metadata("https://www.instagram.com/p/DduKfFmDxsG/", dir)

    assert value_after(recorded_args(dir), "--cookies") == Path.join(dir, "cookies.txt")
    assert File.read!(Path.join(dir, "cookies-seen.txt")) =~ "S3SSION"
    assert File.read!(Path.join(dir, "cookies-mode.txt")) == "-rw-------\n"
    refute File.exists?(Path.join(dir, "cookies.txt"))
  end

  test "classifies yt-dlp's errors", %{dir: dir} do
    for {code, kind, message} <- [
          {"private", :unavailable, "only available for registered users"},
          {"rate-limited", :transient, "rate-limit"},
          {"no-video", :unsupported, "No video found at this link"},
          {"empty", :unsupported, "yt-dlp found nothing at this link"},
          {"unknown", :unsupported, "Unsupported URL"}
        ] do
      assert {:error, %Error{kind: ^kind, message: text}} =
               Ytdlp.metadata("https://www.instagram.com/p/#{code}/", dir)

      assert text =~ message
      refute File.exists?(Path.join(dir, "items.jsonl"))
    end
  end

  test "stops yt-dlp after the timeout", %{dir: dir} do
    assert {:error, %Error{kind: :timeout, message: "Reading the post took longer than 1 second"}} =
             Ytdlp.metadata("https://www.instagram.com/p/hang/", dir, timeout: 1_000)
  end

  test "reports a missing yt-dlp", %{dir: dir, tmp_dir: tmp_dir} do
    put_media_env(ytdlp_path: Path.join(tmp_dir, "missing"))

    assert {:error, %Error{kind: :internal, message: "yt-dlp not found"}} =
             Ytdlp.metadata("https://www.instagram.com/p/DduKfFmDxsG/", dir)
  end

  test "args/3 escapes % in the file path and passes the run's options" do
    args =
      Metadata.args("https://www.instagram.com/p/x/", "/data/100%",
        cookies: "/data/100%/cookies.txt",
        cache_dir: "/cache",
        proxy: "http://127.0.0.1:1"
      )

    assert "/data/100%%/items.jsonl" in args
    assert value_after(args, "--cookies") == "/data/100%/cookies.txt"
    assert value_after(args, "--cache-dir") == "/cache/yt-dlp"
    assert value_after(args, "--proxy") == "http://127.0.0.1:1"
    assert Enum.take(args, -2) == ["--", "https://www.instagram.com/p/x/"]
  end
end
