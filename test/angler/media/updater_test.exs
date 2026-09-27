defmodule Angler.Media.UpdaterTest do
  # Registers a global name and changes the Angler.Media application environment.
  use ExUnit.Case, async: false

  alias Angler.Media
  alias Angler.Media.{Updater, Ytdlp}

  @moduletag :tmp_dir
  @moduletag :capture_log
  @fake_ytdlp Path.expand("../../fixtures/media/fake-yt-dlp", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    # The configured (image) binary lives in its own directory, like /usr/local/bin.
    ytdlp = Path.join([tmp_dir, "image-bin", "yt-dlp"])
    File.mkdir_p!(Path.dirname(ytdlp))
    File.cp!(@fake_ytdlp, ytdlp)
    File.chmod!(ytdlp, 0o755)

    original = Application.get_env(:angler, Media)
    on_exit(fn -> Application.put_env(:angler, Media, original) end)

    config =
      Keyword.merge(original,
        data_dir: Path.join(tmp_dir, "data"),
        ytdlp_path: ytdlp,
        ytdlp_update_channel: "nightly"
      )

    Application.put_env(:angler, Media, config)
    Media.forget_tool_versions()
    on_exit(&Media.forget_tool_versions/0)

    %{ytdlp: ytdlp}
  end

  defp start_updater(opts \\ []) do
    pid = start_supervised!({Updater, Keyword.merge([initial_delay: :infinity], opts)})
    _ = :sys.get_state(pid)
    pid
  end

  test "does not start without an update channel" do
    assert Updater.start_link(channel: nil) == :ignore
    assert Updater.start_link(channel: "") == :ignore

    assert Media.update_ytdlp() ==
             {:error, "auto-update is disabled (set YTDLP_UPDATE_CHANNEL)"}
  end

  test "installs a managed copy of yt-dlp on start", %{ytdlp: ytdlp} do
    managed = Ytdlp.managed_path()
    refute File.exists?(managed)
    assert Ytdlp.executable() == ytdlp

    start_updater()

    assert File.read!(managed) == File.read!(ytdlp)
    assert Bitwise.band(File.stat!(managed).mode, 0o777) == 0o755
    assert Ytdlp.executable() == managed
  end

  test "keeps an existing managed copy" do
    managed = Ytdlp.managed_path()
    File.mkdir_p!(Path.dirname(managed))
    File.write!(managed, "#!/bin/sh\necho 2026.09.01\n")
    File.chmod!(managed, 0o755)

    start_updater()

    assert File.read!(managed) == "#!/bin/sh\necho 2026.09.01\n"
  end

  test "reinstalls a managed copy that an interrupted update left without the executable bit",
       %{ytdlp: ytdlp} do
    managed = Ytdlp.managed_path()
    File.mkdir_p!(Path.dirname(managed))
    File.write!(managed, "#!/bin/sh\necho 2026.09.01\n")
    File.chmod!(managed, 0o644)
    assert Ytdlp.executable() == ytdlp

    start_updater()

    assert File.read!(managed) == File.read!(ytdlp)
    assert Bitwise.band(File.stat!(managed).mode, 0o777) == 0o755
    assert Ytdlp.executable() == managed
  end

  test "replaces a managed copy that is older than the configured yt-dlp", %{ytdlp: ytdlp} do
    managed = Ytdlp.managed_path()
    File.mkdir_p!(Path.dirname(managed))
    File.write!(managed, "#!/bin/sh\necho 2026.01.02\n")
    File.chmod!(managed, 0o755)

    start_updater()

    assert File.read!(managed) == File.read!(ytdlp)
  end

  test "replaces a managed copy that does not run", %{ytdlp: ytdlp} do
    managed = Ytdlp.managed_path()
    File.mkdir_p!(Path.dirname(managed))
    File.write!(managed, "#!/bin/sh\nexit 1\n")
    File.chmod!(managed, 0o755)

    start_updater()

    assert File.read!(managed) == File.read!(ytdlp)
  end

  test "keeps a working managed copy when the configured yt-dlp is gone" do
    managed = Ytdlp.managed_path()
    File.mkdir_p!(Path.dirname(managed))
    File.write!(managed, "#!/bin/sh\necho 2026.09.01\n")
    File.chmod!(managed, 0o755)

    config = Application.get_env(:angler, Media)
    Application.put_env(:angler, Media, Keyword.put(config, :ytdlp_path, "/nonexistent/yt-dlp"))
    start_updater()

    assert File.read!(managed) == "#!/bin/sh\necho 2026.09.01\n"
  end

  test "update_ytdlp/0 updates the managed copy and returns its version", %{ytdlp: ytdlp} do
    start_updater()

    assert Media.update_ytdlp() == {:ok, "2026.09.20.000000"}
    # The update changed the managed copy only (the fake keeps its version next to itself).
    assert File.read!(Path.join(Path.dirname(Ytdlp.managed_path()), "fake-version")) =~
             "2026.09.20"

    refute File.exists?(Path.join(Path.dirname(ytdlp), "fake-version"))
  end

  test "reports failed updates" do
    start_updater(channel: "broken")

    assert {:error, "yt-dlp update failed: exit status 100: ERROR: Unable to write to " <> _} =
             Media.update_ytdlp()
  end

  test "updates on schedule" do
    pid = start_updater()
    version_file = Path.join(Path.dirname(Ytdlp.managed_path()), "fake-version")
    refute File.exists?(version_file)

    send(pid, :update)
    _ = :sys.get_state(pid)

    assert File.exists?(version_file)
  end

  test "reports a configured yt-dlp that cannot be copied" do
    config = Application.get_env(:angler, Media)
    Application.put_env(:angler, Media, Keyword.put(config, :ytdlp_path, "/nonexistent/yt-dlp"))
    start_updater()

    refute File.exists?(Ytdlp.managed_path())

    assert Media.update_ytdlp() ==
             {:error,
              "yt-dlp update failed: could not install a self-updating copy of yt-dlp: no such file or directory"}
  end

  test "reinstalls the managed copy before updating when it went missing" do
    start_updater()
    File.rm!(Ytdlp.managed_path())

    assert {:ok, _version} = Media.update_ytdlp()
    assert File.exists?(Ytdlp.managed_path())
  end

  test "tool_versions/0 reports missing tools as nil and caches the result" do
    config = Application.get_env(:angler, Media)
    Application.put_env(:angler, Media, Keyword.put(config, :ffmpeg_path, "/nonexistent/ffmpeg"))

    assert %{"yt-dlp" => "2026.08.19", "ffmpeg" => nil} = versions = Media.tool_versions()
    assert Map.has_key?(versions, "deno")

    Application.put_env(:angler, Media, config)
    assert Media.tool_versions() == versions
  end

  @tag :external
  test "tool_versions/0 reads the ffmpeg version" do
    assert %{"ffmpeg" => version} = Media.tool_versions()
    assert version =~ ~r/^\d+\.\d+/
  end

  test "tool_versions/0 reports the managed yt-dlp version and refreshes after updates" do
    start_updater()
    assert %{"yt-dlp" => "2026.08.19"} = Media.tool_versions()

    assert {:ok, "2026.09.20.000000"} = Media.update_ytdlp()
    assert %{"yt-dlp" => "2026.09.20.000000"} = Media.tool_versions()
  end
end
