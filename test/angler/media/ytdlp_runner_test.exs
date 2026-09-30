defmodule Angler.Media.YtdlpRunnerTest do
  # Angler.Media.Ytdlp.download/3 through Angler.Media.Ytdlp.Runner, which it shares
  # with the metadata runs: proxy, cookies copy, cleanup and the size guard. Uses
  # the fake yt-dlp and changes the Angler.Media application environment.
  use ExUnit.Case, async: false

  alias Angler.Media
  alias Angler.Media.{Download, Error, Ytdlp}

  @moduletag :tmp_dir
  @fake_ytdlp Path.expand("../../fixtures/media/fake-yt-dlp", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    ytdlp = Path.join(tmp_dir, "yt-dlp")
    File.cp!(@fake_ytdlp, ytdlp)
    File.chmod!(ytdlp, 0o755)

    dir = Path.join(tmp_dir, "entry")
    File.mkdir_p!(dir)

    original = Application.get_env(:angler, Media)
    on_exit(fn -> Application.put_env(:angler, Media, original) end)

    cookies = Path.join(tmp_dir, "cookies.txt")
    File.write!(cookies, ".example.com\tTRUE\t/\tFALSE\t0\tsession\tS3SSION\n")

    Application.put_env(
      :angler,
      Media,
      Keyword.merge(original,
        data_dir: Path.join(tmp_dir, "data"),
        ytdlp_path: ytdlp,
        cookies_file: cookies,
        ytdlp_update_channel: nil,
        allow_private_networks: false
      )
    )

    %{dir: dir}
  end

  test "downloads with the cookies copy and the proxy, then cleans up", %{dir: dir} do
    assert {:ok, %Download{path: path, title: ~s(A "quoted" title)}} =
             Ytdlp.download("https://fake.test/ok", dir, target_bytes: 50_000_000)

    assert path == Path.join(dir, "source.mp4")
    args = dir |> Path.join("args.txt") |> File.read!() |> String.split("\n", trim: true)
    assert Enum.take(args, -2) == ["--", "https://fake.test/ok"]
    assert "--cookies" in args
    assert "--proxy" in args
    assert File.read!(Path.join(dir, "cookies-seen.txt")) =~ "S3SSION"
    refute File.exists?(Path.join(dir, "cookies.txt"))
    refute File.exists?(Path.join(dir, "tmp"))
  end

  test "stops a download that grows beyond the source limit, and cleans up", %{dir: dir} do
    assert {:error, %Error{kind: :too_large, message: "Source file is larger than 1 MB"}} =
             Ytdlp.download("https://fake.test/endless", dir,
               max_source_bytes: 1_000_000,
               timeout: 30_000
             )

    refute File.exists?(Path.join(dir, "cookies.txt"))
    refute File.exists?(Path.join(dir, "tmp"))
  end

  test "reports hosts the proxy refused", %{dir: dir} do
    assert {:error, %Error{kind: :unavailable, message: message}} =
             Ytdlp.download("https://fake.test/blocked", dir, [])

    assert message ==
             "Downloads may not reach private network addresses (127.0.0.1); " <>
               "set ALLOW_PRIVATE_NETWORK_DOWNLOADS=true to allow them"
  end
end
