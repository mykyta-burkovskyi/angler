defmodule Angler.Media.SlideshowNetworkTest do
  # Live TikTok photo posts through Angler.Media.download/3 and prepare/3 (real TikTok,
  # its CDN, ffmpeg and ffprobe; the video control also needs yt-dlp). Excluded by
  # default; run with:
  #
  #   mix test test/angler/media/slideshow_network_test.exs --include network
  #
  # Not async: talks to TikTok without the Req.Test stub of the test configuration.
  use ExUnit.Case, async: false

  alias Angler.Media
  alias Angler.Media.{Download, Output, Probe}

  @moduletag :external
  @moduletag :network
  @moduletag :tmp_dir
  @moduletag timeout: :timer.minutes(10)

  @target 50_000_000

  setup do
    original = Application.get_env(:angler, Media.TikTok)
    Application.put_env(:angler, Media.TikTok, [])
    on_exit(fn -> Application.put_env(:angler, Media.TikTok, original) end)
  end

  # Downloads and prepares `url` like the pipeline does (`opts` override download
  # options), retrying transient failures (TikTok's firewall and CDN have bad
  # moments) a few times.
  defp deliver(url, dir, opts \\ [], attempts \\ 3) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    started = System.monotonic_time(:millisecond)

    # Like the pipeline: only the last attempt may leave out files the CDN refuses.
    download_opts =
      [target_bytes: @target, max_source_bytes: 1_024_000_000, max_duration: 1_800]
      |> Keyword.merge(opts)
      |> Keyword.put(:final_attempt, attempts == 1)

    with {:ok, download} <- Media.download(url, dir, download_opts),
         downloaded = System.monotonic_time(:millisecond),
         {:ok, output} <- Media.prepare(download, dir, target_bytes: @target) do
      finished = System.monotonic_time(:millisecond)
      {download, output, {downloaded - started, finished - downloaded}}
    else
      {:error, %Media.Error{kind: :transient}} when attempts > 1 ->
        deliver(url, dir, opts, attempts - 1)

      {:error, error} ->
        flunk("#{url}: #{inspect(error)}")
    end
  end

  defp report(url, %Download{} = download, %Output{} = output, {download_ms, prepare_ms}) do
    IO.puts(
      "\n#{url}: #{length(download.images)} images, " <>
        "sound #{inspect(download.audio_path && Path.basename(download.audio_path))}, " <>
        "#{output.width}x#{output.height}, #{output.duration} s, " <>
        "#{Float.round(output.size / 1_000_000, 2)} MB, " <>
        "download #{download_ms} ms, prepare #{prepare_ms} ms"
    )
  end

  defp assert_telegram_video(%Output{} = output, audio?) do
    assert %Output{video_codec: "h264", transcoded: true} = output
    assert output.size <= @target
    assert {:ok, probe} = Probe.run(output.path)

    assert %Probe{video_codec: "h264", pix_fmt: "yuv420p", faststart?: true, has_audio?: ^audio?} =
             probe

    assert {probe.width, probe.height} == {output.width, output.height}
    assert_in_delta probe.duration, output.duration, 0.5

    # Every planned frame is there: 30 fps for the whole video.
    {fields, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -select_streams v:0 -show_entries stream=nb_frames,duration -of json) ++
          [output.path]
      )

    %{"streams" => [%{"nb_frames" => frames, "duration" => seconds}]} = JSON.decode!(fields)
    assert_in_delta String.to_float(seconds), probe.duration, 0.05
    assert String.to_integer(frames) == round(String.to_float(seconds) * 30)

    assert {:ok, %Probe{width: tw, height: th}} = Probe.run(output.thumbnail_path)
    assert max(tw, th) <= 320

    assert Path.dirname(output.path) |> File.ls!() |> Enum.sort() == [
             "thumbnail.jpg",
             "video.mp4"
           ]
  end

  test "a photo post with an MP3 sound", %{tmp_dir: tmp_dir} do
    url = "https://www.tiktok.com/@hullcity/photo/7553302113757990166"
    {download, output, timings} = deliver(url, Path.join(tmp_dir, "hullcity"))
    report(url, download, output, timings)

    assert %Download{kind: :slideshow, extractor: "TikTok", images: [_, _]} = download
    assert Path.basename(download.audio_path) == "audio.mp3"
    assert_in_delta download.duration, 16.3, 0.2
    assert_telegram_video(output, true)
    assert output.duration == 16
  end

  test "a photo short link", %{tmp_dir: tmp_dir} do
    url = "https://vt.tiktok.com/ZSaVMnnpj/"
    {download, output, timings} = deliver(url, Path.join(tmp_dir, "short"))
    report(url, download, output, timings)

    assert %Download{kind: :slideshow, images: images} = download
    assert length(images) == 7
    assert download.audio_path
    assert_telegram_video(output, true)
  end

  test "a photo post that had no sound", %{tmp_dir: tmp_dir} do
    # TikTok served this post without its sound (an empty playUrl) during research;
    # whether it does changes over time and by region, so both are accepted. The
    # silent case is covered offline by the fixture page and the render tests.
    url = "https://www.tiktok.com/@itsevykins/photo/7367130722806648106"
    {download, output, timings} = deliver(url, Path.join(tmp_dir, "silent"))
    report(url, download, output, timings)

    assert %Download{kind: :slideshow, images: images} = download
    assert length(images) == 12
    assert_telegram_video(output, download.audio_path != nil)

    # Without sound: 3 seconds per image.
    if is_nil(download.audio_path), do: assert(output.duration == 36)
  end

  test "a shorter maximum duration caps the slideshow", %{tmp_dir: tmp_dir} do
    # 5 images and a 60 s sound, limited to 30 s.
    url = "https://www.tiktok.com/@chososfavhairtie/photo/7369836402751671585"
    {download, output, timings} = deliver(url, Path.join(tmp_dir, "capped"), max_duration: 30)
    report(url, download, output, timings)

    assert %Download{kind: :slideshow, max_duration: 30, images: [_, _, _, _, _]} = download
    assert_telegram_video(output, download.audio_path != nil)
    assert output.duration == 30
  end

  test "a slideshow behind a /video/ link", %{tmp_dir: tmp_dir} do
    url = "https://www.tiktok.com/@croatian_memes/video/7406655666472979745"
    {download, output, timings} = deliver(url, Path.join(tmp_dir, "video-link"))
    report(url, download, output, timings)

    assert %Download{kind: :slideshow, images: [_, _]} = download
    assert_telegram_video(output, true)
  end

  test "a regular video still goes through yt-dlp", %{tmp_dir: tmp_dir} do
    url = "https://www.tiktok.com/@memezar/video/7449708266168274208"
    {download, output, timings} = deliver(url, Path.join(tmp_dir, "video"))
    report(url, download, output, timings)

    assert %Download{kind: :video, extractor: "TikTok", images: []} = download
    assert %Output{video_codec: "h264"} = output
  end
end
