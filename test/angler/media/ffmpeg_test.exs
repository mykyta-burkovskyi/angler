defmodule Angler.Media.FfmpegTest do
  use ExUnit.Case, async: true

  alias Angler.Media.{Error, Ffmpeg, Probe}

  @params %{
    video_kbps: 1_000,
    audio_kbps: 96,
    audio_channels: nil,
    short_side: 720,
    fps: nil,
    preset: "medium"
  }

  defp value_after(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  describe "scale_filter/2" do
    test "targets the short side, keeps even sizes and converts to yuv420p" do
      assert Ffmpeg.scale_filter(720, nil) ==
               "scale=w='if(gte(iw,ih),-2,trunc(min(720,iw)/2)*2)':h='if(gte(iw,ih),trunc(min(720,ih)/2)*2,-2)',format=yuv420p"
    end

    test "caps the frame rate when asked" do
      assert Ffmpeg.scale_filter(360, 30) =~ ~r/,fps=30,format=yuv420p$/
    end
  end

  describe "transcode_args/5" do
    test "first pass analyses the video only" do
      args = Ffmpeg.transcode_args("/in/source.webm", "/in/video.mp4", @params, 1, "/in/x264")

      assert Enum.take(args, 7) == ~w(-hide_banner -loglevel error -nostdin -y -i /in/source.webm)
      assert value_after(args, "-map") == "0:V:0"
      assert "-an" in args
      assert value_after(args, "-vf") == Ffmpeg.scale_filter(720, nil)
      assert value_after(args, "-c:v") == "libx264"
      assert value_after(args, "-preset") == "medium"
      assert value_after(args, "-profile:v") == "high"
      assert value_after(args, "-b:v") == "1000k"
      assert value_after(args, "-pass") == "1"
      assert value_after(args, "-passlogfile") == "/in/x264"
      assert value_after(args, "-progress") == "pipe:1"
      assert Enum.take(args, -3) == ~w(-f null /dev/null)
      refute "/in/video.mp4" in args
    end

    test "second pass encodes video and audio into a fast-start MP4" do
      args = Ffmpeg.transcode_args("/in/source.webm", "/in/video.mp4", @params, 2, "/in/x264")

      assert ["0:V:0", "0:a:0?"] ==
               args
               |> Enum.chunk_every(2, 1)
               |> Enum.filter(&(hd(&1) == "-map"))
               |> Enum.map(&List.last/1)

      assert value_after(args, "-b:v") == "1000k"
      assert value_after(args, "-maxrate") == "1500k"
      assert value_after(args, "-bufsize") == "2000k"
      assert value_after(args, "-pass") == "2"
      assert value_after(args, "-c:a") == "aac"
      assert value_after(args, "-b:a") == "96k"
      refute "-ac" in args
      assert value_after(args, "-map_metadata") == "-1"
      assert value_after(args, "-movflags") == "+faststart"
      assert value_after(args, "-stats_period") == "1"
      assert List.last(args) == "/in/video.mp4"
    end

    test "second pass downmixes when asked and drops audio when there is none" do
      mono =
        Ffmpeg.transcode_args(
          "/in/a.mkv",
          "/in/b.mp4",
          %{@params | audio_kbps: 64, audio_channels: 1},
          2,
          "/in/x"
        )

      assert value_after(mono, "-ac") == "1"

      silent =
        Ffmpeg.transcode_args("/in/a.mkv", "/in/b.mp4", %{@params | audio_kbps: 0}, 2, "/in/x")

      assert "-an" in silent
      refute "0:a:0?" in silent
      refute "-c:a" in silent
    end

    test "uses the preset from the plan" do
      args = Ffmpeg.transcode_args("/a", "/b", %{@params | preset: "veryfast"}, 1, "/x")
      assert value_after(args, "-preset") == "veryfast"
    end
  end

  test "remux_args/2 copies the first video and audio stream" do
    assert Ffmpeg.remux_args("/in/source.mkv", "/in/video.mp4") ==
             ~w(-hide_banner -loglevel error -nostdin -y -i /in/source.mkv -map 0:V:0 -map 0:a:0? -c copy -movflags +faststart /in/video.mp4)
  end

  test "audio_args/3 copies video, encodes AAC and downmixes surround" do
    stereo = Ffmpeg.audio_args("/in/a.mkv", "/in/b.mp4", 2)
    assert value_after(stereo, "-c:v") == "copy"
    assert value_after(stereo, "-c:a") == "aac"
    assert value_after(stereo, "-b:a") == "128k"
    refute "-ac" in stereo

    assert value_after(Ffmpeg.audio_args("/in/a.mkv", "/in/b.mp4", 6), "-ac") == "2"
  end

  test "thumbnail_args/4 grabs one frame scaled into 320x320" do
    args = Ffmpeg.thumbnail_args("/in/video.mp4", "/in/thumbnail.jpg", 1.0, 4)

    assert value_after(args, "-ss") == "1.000"
    assert value_after(args, "-i") == "/in/video.mp4"
    assert value_after(args, "-frames:v") == "1"
    assert value_after(args, "-vf") == "scale=320:320:force_original_aspect_ratio=decrease"
    assert value_after(args, "-q:v") == "4"
    assert List.last(args) == "/in/thumbnail.jpg"
  end

  test "progress_percent/2 reads out_time in microseconds" do
    assert Ffmpeg.progress_percent("out_time_us=1000000", 4.0) == 25.0
    assert Ffmpeg.progress_percent("out_time_ms=2000000", 4.0) == 50.0
    assert Ffmpeg.progress_percent("out_time_us=9000000", 4.0) == 100.0
    assert Ffmpeg.progress_percent("out_time_us=N/A", 4.0) == nil
    assert Ffmpeg.progress_percent("frame=12", 4.0) == nil
    assert Ffmpeg.progress_percent("out_time_us=1000000", nil) == nil
  end

  test "timeout/1 allows four times the duration within 10 minutes and 3 hours" do
    assert Ffmpeg.timeout(10) == :timer.minutes(10)
    assert Ffmpeg.timeout(1_200) == :timer.minutes(80)
    assert Ffmpeg.timeout(187.3) == :timer.minutes(13)
    assert Ffmpeg.timeout(10_000) == :timer.hours(3)
    assert Ffmpeg.timeout(nil) == :timer.minutes(10)
  end

  describe "interpret/2" do
    test "reports running out of time as too large, which is not retried" do
      lines = ["frame=120", "out_time_us=4000000", "[libx264 @ 0x1] slow"]

      assert Ffmpeg.interpret({:error, :timeout, lines}, :timer.minutes(12)) ==
               {:error,
                %Error{
                  kind: :too_large,
                  message: "Processing the video took longer than 12 minutes",
                  output: "[libx264 @ 0x1] slow"
                }}
    end

    test "reports failures as internal" do
      assert Ffmpeg.interpret({:ok, %{exit_status: 0, output: []}}, 1_000) == :ok

      assert {:error, %Error{kind: :internal, message: "ffmpeg failed (exit 1): Bad input"}} =
               Ffmpeg.interpret({:ok, %{exit_status: 1, output: ["frame=1", "Bad input"]}}, 1_000)

      assert {:error, %Error{kind: :internal, message: "ffmpeg not found"}} =
               Ffmpeg.interpret({:error, :enoent}, 1_000)
    end
  end

  @tag :tmp_dir
  test "remove_pass_logs/1 deletes the x264 statistics", %{tmp_dir: dir} do
    passlog = Path.join(dir, "x264")

    for suffix <- ["-0.log", "-0.log.mbtree", "-0.log.temp"],
        do: File.write!(passlog <> suffix, "x")

    File.write!(Path.join(dir, "video.mp4"), "keep")

    assert Ffmpeg.remove_pass_logs(passlog) == :ok
    assert File.ls!(dir) == ["video.mp4"]
  end

  describe "with ffmpeg" do
    @describetag :external
    @describetag :tmp_dir

    defp ffmpeg!(args) do
      {output, status} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args, stderr_to_stdout: true)

      assert status == 0, output
    end

    test "thumbnail/3 writes a small JPEG within 320x320", %{tmp_dir: dir} do
      video = Path.join(dir, "video.mp4")
      thumbnail = Path.join(dir, "thumbnail.jpg")
      ffmpeg!(~w(-f lavfi -i testsrc2=size=1280x720:rate=25 -t 3 -c:v libx264) ++ [video])

      assert Ffmpeg.thumbnail(video, thumbnail, 3.0) == thumbnail
      assert {:ok, %Probe{width: 320, height: 180}} = Probe.run(thumbnail)
      assert File.stat!(thumbnail).size < 200_000
    end

    @tag :capture_log
    test "thumbnail/3 returns nil instead of failing", %{tmp_dir: dir} do
      input = Path.join(dir, "broken.mp4")
      File.write!(input, "not a video")
      thumbnail = Path.join(dir, "thumbnail.jpg")

      assert Ffmpeg.thumbnail(input, thumbnail, nil) == nil
      refute File.exists?(thumbnail)
    end

    test "failures are internal errors with ffmpeg's message", %{tmp_dir: dir} do
      input = Path.join(dir, "broken.mp4")
      File.write!(input, "not a video")

      assert {:error, %Error{kind: :internal, message: message}} =
               Ffmpeg.remux(input, Path.join(dir, "video.mp4"), nil)

      assert message =~ "ffmpeg failed (exit"
      assert message =~ "Invalid data"
    end
  end
end
