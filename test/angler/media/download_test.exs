defmodule Angler.Media.DownloadTest do
  # Changes the Angler.Media application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Angler.Media
  alias Angler.Media.{Download, Error, Ytdlp}

  @moduletag :tmp_dir
  @fake_ytdlp Path.expand("../../fixtures/media/fake-yt-dlp", __DIR__)
  @probe_fixture Path.expand("../../fixtures/media/probe_no_audio.json", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    ytdlp = Path.join(tmp_dir, "yt-dlp")
    File.cp!(@fake_ytdlp, ytdlp)
    File.chmod!(ytdlp, 0o755)

    dir = Path.join(tmp_dir, "entry")
    File.mkdir_p!(dir)
    data_dir = Path.join(tmp_dir, "data")

    original = Application.get_env(:angler, Media)
    on_exit(fn -> Application.put_env(:angler, Media, original) end)

    put_media_env(
      data_dir: data_dir,
      ytdlp_path: ytdlp,
      cookies_file: nil,
      ytdlp_update_channel: nil,
      allow_private_networks: false
    )

    %{dir: dir, data_dir: data_dir, ytdlp: ytdlp}
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

  test "downloads a video and returns its metadata", %{dir: dir, data_dir: data_dir} do
    test = self()

    assert {:ok, download} =
             Media.download("https://fake.test/ok", dir,
               target_bytes: 50_000_000,
               max_source_bytes: 1_000_000_000,
               max_duration: 1_800,
               on_progress: &send(test, {:progress, &1})
             )

    assert download == %Download{
             path: Path.join(dir, "source.mp4"),
             size: 10,
             title: ~s(A "quoted" title),
             extractor: "Fake",
             webpage_url: "https://fake.test/ok",
             duration: 12.5,
             width: 1280,
             height: 720,
             video_codec: "avc1.64001F",
             audio_codec: nil
           }

    assert_received {:progress, %{percent: 50.0, detail: "1 kB of 2 kB · 1 kB/s · 0:01 left"}}
    assert_received {:progress, %{percent: nil, detail: "Merging formats"}}

    args = recorded_args(dir)
    assert Enum.take(args, -2) == ["--", "https://fake.test/ok"]
    assert value_after(args, "--max-filesize") == "1000000000"
    assert value_after(args, "--match-filters") == "!is_live & duration<?1800"
    assert value_after(args, "--cache-dir") == Path.join([data_dir, "cache", "yt-dlp"])
    refute "--cookies" in args

    cache = Path.join(data_dir, "cache")
    assert File.dir?(cache)
    env = File.read!(Path.join(dir, "env.txt"))
    assert env =~ "HOME=#{cache}\n"
    assert env =~ "XDG_CACHE_HOME=#{cache}\n"
    assert env =~ "PWD=#{dir}\n"

    refute File.exists?(Path.join(dir, "tmp"))
    refute File.exists?(Path.join(dir, "info.jsonl"))
  end

  test "sends every request through a proxy that is stopped afterwards", %{dir: dir} do
    assert {:ok, %Download{}} = Media.download("https://fake.test/ok", dir, [])

    proxy = value_after(recorded_args(dir), "--proxy")
    assert %URI{scheme: "http", host: "127.0.0.1", port: port} = URI.parse(proxy)

    # yt-dlp passes the proxy on to ffmpeg; deno reads HTTPS_PROXY.
    env = File.read!(Path.join(dir, "env.txt"))
    assert env =~ "http_proxy=#{proxy}\n"
    assert env =~ "HTTPS_PROXY=#{proxy}\n"
    assert env =~ "no_proxy=unset\n"

    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [])
  end

  test "refuses to reach private network addresses", %{dir: dir} do
    assert {:error, %Error{kind: :unavailable, message: message}} =
             Media.download("https://fake.test/blocked", dir, [])

    assert message ==
             "Downloads may not reach private network addresses (127.0.0.1); " <>
               "set ALLOW_PRIVATE_NETWORK_DOWNLOADS=true to allow them"

    assert File.read!(Path.join(dir, "blocked-status.txt")) == "403\n"
  end

  test "warns once that a proxy from the environment is not used", %{dir: dir} do
    original = System.get_env("HTTPS_PROXY")

    on_exit(fn ->
      if original,
        do: System.put_env("HTTPS_PROXY", original),
        else: System.delete_env("HTTPS_PROXY")
    end)

    System.put_env("HTTPS_PROXY", "http://user:pass@proxy-#{System.unique_integer()}.test:3128")

    log = capture_log(fn -> assert {:ok, _} = Media.download("https://fake.test/ok", dir, []) end)
    assert log =~ ~r/Downloads ignore the proxy set in [^:]*HTTPS_PROXY/
    assert log =~ "ALLOW_PRIVATE_NETWORK_DOWNLOADS=true"
    refute log =~ "user:pass"

    log = capture_log(fn -> Media.download("https://fake.test/ok", dir, []) end)
    refute log =~ "Downloads ignore the proxy"

    put_media_env(allow_private_networks: true)
    System.put_env("HTTPS_PROXY", "http://proxy-#{System.unique_integer()}.test:3128")
    log = capture_log(fn -> Media.download("https://fake.test/ok", dir, []) end)
    refute log =~ "Downloads ignore the proxy"
  end

  test "runs yt-dlp without the proxy when private networks are allowed", %{dir: dir} do
    put_media_env(allow_private_networks: true)

    assert {:ok, %Download{}} = Media.download("https://fake.test/ok", dir, [])
    refute "--proxy" in recorded_args(dir)
  end

  describe "source size limit" do
    test "stops a download that grows beyond it while it runs", %{dir: dir} do
      assert {:error, %Error{kind: :too_large, message: "Source file is larger than 1 MB"}} =
               Media.download("https://fake.test/endless", dir,
                 max_source_bytes: 1_000_000,
                 timeout: 30_000
               )

      refute File.exists?(Path.join(dir, "tmp"))
    end

    test "stops a download that grows beyond it without printing progress", %{dir: dir} do
      # yt-dlp prints nothing while ffmpeg downloads an HLS stream for it.
      assert {:error, %Error{kind: :too_large, message: "Source file is larger than 1 MB"}} =
               Media.download("https://fake.test/silent", dir,
                 max_source_bytes: 1_000_000,
                 timeout: 20_000
               )

      refute File.exists?(Path.join(dir, "tmp"))
    end

    test "refuses a finished download larger than it", %{dir: dir} do
      assert {:error, %Error{kind: :too_large, message: "Source file is larger than 0.1 MB"}} =
               Media.download("https://fake.test/unsized", dir, max_source_bytes: 100_000)

      assert {:ok, %Download{size: 200_000}} =
               Media.download("https://fake.test/unsized", dir, max_source_bytes: 200_000)
    end
  end

  describe "the duration limit" do
    setup %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "fake-source.mp4"), "fake video")

      # ffprobe measures 15 minutes.
      probe = Path.join(tmp_dir, "probe.json")
      File.write!(probe, @probe_fixture |> File.read!() |> String.replace("2.000000", "900.0"))
      ffprobe = Path.join(tmp_dir, "ffprobe")
      File.write!(ffprobe, "#!/bin/sh\ncat '#{probe}'\n")
      File.chmod!(ffprobe, 0o755)
      put_media_env(ffprobe_path: ffprobe)
    end

    test "refuses videos yt-dlp did not know the duration of when ffprobe finds them longer",
         %{dir: dir} do
      assert {:error, %Error{kind: :too_large, message: "Video is longer than 10 minutes"}} =
               Media.download("https://fake.test/no-duration", dir, max_duration: 600)
    end

    test "refuses videos longer than yt-dlp reported", %{dir: dir} do
      # yt-dlp reports 12.5 seconds (e.g. the durations an HLS playlist claims).
      assert {:error, %Error{kind: :too_large, message: "Video is longer than 10 minutes"}} =
               Media.download("https://fake.test/ok", dir, max_duration: 600)
    end

    test "returns the duration ffprobe measured", %{dir: dir} do
      assert {:ok, %Download{duration: 900.0}} =
               Media.download("https://fake.test/no-duration", dir, max_duration: 1_800)

      assert {:ok, %Download{duration: 900.0}} =
               Media.download("https://fake.test/ok", dir, max_duration: 1_800)

      # Without a limit the file is only probed by prepare/3.
      assert {:ok, %Download{duration: nil}} =
               Media.download("https://fake.test/no-duration", dir, [])

      assert {:ok, %Download{duration: 12.5}} = Media.download("https://fake.test/ok", dir, [])
    end

    test "keeps yt-dlp's duration when ffprobe cannot read the file", %{dir: dir} do
      put_media_env(ffprobe_path: "/nonexistent/ffprobe")

      assert {:ok, %Download{duration: 12.5}} =
               Media.download("https://fake.test/ok", dir, max_duration: 1_800)
    end
  end

  test "passes the configured ffmpeg when it exists", %{dir: dir} do
    put_media_env(ffmpeg_path: "/bin/echo")
    assert {:ok, %Download{}} = Media.download("https://fake.test/ok", dir, [])
    assert value_after(recorded_args(dir), "--ffmpeg-location") == "/bin/echo"

    put_media_env(ffmpeg_path: "/nonexistent/ffmpeg")
    assert {:ok, %Download{}} = Media.download("https://fake.test/ok", dir, [])
    refute "--ffmpeg-location" in recorded_args(dir)
  end

  test "accepts exit status 101 from --max-downloads", %{dir: dir} do
    assert {:ok, %Download{audio_codec: "mp4a.40.2"}} =
             Media.download("https://fake.test/max-downloads", dir, [])
  end

  test "passes a private copy of the cookies file and deletes it afterwards", %{
    tmp_dir: tmp_dir,
    dir: dir
  } do
    cookies = Path.join(tmp_dir, "cookies.txt")
    File.write!(cookies, "# Netscape HTTP Cookie File\n")
    File.chmod!(cookies, 0o444)
    put_media_env(cookies_file: cookies)

    assert {:ok, %Download{}} = Media.download("https://fake.test/ok", dir, [])

    assert value_after(recorded_args(dir), "--cookies") == Path.join(dir, "cookies.txt")
    assert File.read!(Path.join(dir, "cookies-seen.txt")) == "# Netscape HTTP Cookie File\n"
    # Readable by the app user only, whatever the mode of the configured file.
    assert File.read!(Path.join(dir, "cookies-mode.txt")) == "-rw-------\n"
    refute File.exists?(Path.join(dir, "cookies.txt"))
    assert File.read!(cookies) == "# Netscape HTTP Cookie File\n"
  end

  @tag :capture_log
  test "downloads without cookies when the cookies file is unreadable", %{dir: dir} do
    put_media_env(cookies_file: "/nonexistent/cookies.txt")

    assert {:ok, %Download{}} = Media.download("https://fake.test/ok", dir, [])
    refute "--cookies" in recorded_args(dir)
  end

  for {name, kind, message} <- [
        {"audio-only", :unsupported, "This post has no video"},
        {"too-long", :too_large, "Video is longer than 30 minutes"},
        {"live", :unsupported, "Live streams are not supported"},
        {"too-big", :too_large, "Source file is larger than 0.1 MB"},
        {"private", :unavailable,
         "[youtube] abc: Private video. Sign in if you've been granted access to this video"},
        {"other", :unsupported, "Unsupported URL: https://fake.test/other"}
      ] do
    test "reports #{name} as #{kind}", %{dir: dir} do
      assert {:error, %Error{kind: unquote(kind), message: unquote(message)}} =
               Media.download("https://fake.test/" <> unquote(name), dir, max_duration: 1_800)

      refute File.exists?(Path.join(dir, "tmp"))
    end
  end

  test "kills yt-dlp when the download takes too long", %{dir: dir} do
    assert {:error, %Error{kind: :timeout, message: "Download took longer than 0 seconds"}} =
             Media.download("https://fake.test/hang", dir, timeout: 300)
  end

  test "reports a missing yt-dlp", %{dir: dir} do
    put_media_env(ytdlp_path: "/nonexistent/yt-dlp")

    assert {:error, %Error{kind: :internal, message: "yt-dlp not found"}} =
             Media.download("https://fake.test/ok", dir, [])
  end

  describe "Ytdlp.executable/0" do
    test "uses the managed copy only when auto-update is enabled and it exists", %{ytdlp: ytdlp} do
      managed = Ytdlp.managed_path()
      assert Ytdlp.executable() == ytdlp

      put_media_env(ytdlp_update_channel: "nightly")
      assert Ytdlp.executable() == ytdlp

      File.mkdir_p!(Path.dirname(managed))
      File.cp!(ytdlp, managed)
      assert Ytdlp.executable() == managed

      put_media_env(ytdlp_update_channel: nil)
      assert Ytdlp.executable() == ytdlp
    end

    test "skips a managed copy that is not executable", %{ytdlp: ytdlp} do
      managed = Ytdlp.managed_path()
      put_media_env(ytdlp_update_channel: "nightly")
      File.mkdir_p!(Path.dirname(managed))
      File.cp!(ytdlp, managed)
      File.chmod!(managed, 0o644)

      assert Ytdlp.executable() == ytdlp
    end
  end
end
