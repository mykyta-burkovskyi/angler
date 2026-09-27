defmodule Angler.Media.Slideshow.RenderTest do
  # Renders real slideshows with ffmpeg through Angler.Media.prepare/3.
  use ExUnit.Case, async: true

  alias Angler.Media
  alias Angler.Media.{Download, Error, Output, Probe}

  @moduletag :external
  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: :timer.minutes(3)

  @mb 1_000_000

  defp ffmpeg!(args) do
    {output, status} =
      System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args, stderr_to_stdout: true)

    assert status == 0, output
  end

  # A still of `source` (a lavfi video source) at `size`, with extra output arguments.
  defp image!(slides, name, source, size, args \\ []) do
    path = Path.join(slides, name)
    separator = if String.contains?(source, "="), do: ":", else: "="

    ffmpeg!(
      ["-f", "lavfi", "-i", "#{source}#{separator}size=#{size}", "-frames:v", "1"] ++
        args ++ [path]
    )

    path
  end

  # A PNG (named `name`) of a solid `color` like "0xff000080" in pixel format `format`.
  defp png!(slides, name, color, size, format) do
    path = Path.join(slides, name)
    source = "color=c=#{color}:size=#{size},format=#{format}"
    ffmpeg!(["-f", "lavfi", "-i", source] ++ ~w(-frames:v 1 -f image2 -c:v png) ++ [path])
    path
  end

  defp sound!(slides, name, seconds, args) do
    path = Path.join(slides, name)

    ffmpeg!(
      ~w(-f lavfi -i sine=frequency=330:sample_rate=44100:duration=#{seconds}) ++ args ++ [path]
    )

    path
  end

  defp slideshow(dir, images, audio \\ nil) do
    slides = Path.join(dir, "slides")

    %Download{
      kind: :slideshow,
      path: slides,
      size: 1,
      images: images,
      audio_path: audio,
      duration: audio && elem(Float.parse(ffprobe!(audio, "format=duration")), 0),
      extractor: "TikTok"
    }
  end

  defp ffprobe!(path, entries, stream \\ nil) do
    select = if stream, do: ["-select_streams", stream], else: []

    {output, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error) ++ select ++ ["-show_entries", entries, "-of", "default=nw=1:nk=1", path]
      )

    String.trim(output)
  end

  defp prepare(download, dir, target \\ 50 * @mb) do
    test = self()
    Media.prepare(download, dir, target_bytes: target, on_progress: &send(test, {:progress, &1}))
  end

  defp progress_messages do
    receive do
      {:progress, progress} -> [progress | progress_messages()]
    after
      0 -> []
    end
  end

  # Checks the video against what Telegram and the plan expect.
  defp assert_video(%Output{} = output, {width, height}, duration, opts \\ []) do
    assert %Output{video_codec: "h264", transcoded: true, width: ^width, height: ^height} = output
    assert output.duration == round(duration)
    assert output.size == File.stat!(output.path).size

    assert {:ok, %Probe{} = probe} = Probe.run(output.path)
    assert %Probe{video_codec: "h264", pix_fmt: "yuv420p", width: ^width, height: ^height} = probe
    assert rem(width, 2) == 0 and rem(height, 2) == 0
    assert probe.faststart?
    assert_in_delta probe.duration, duration, 0.1
    assert_in_delta probe.fps, 30.0, 0.01

    # Whole frames at 30 fps, BT.709 tags.
    assert ffprobe!(output.path, "stream=nb_frames", "v:0") == "#{round(duration * 30)}"
    assert ffprobe!(output.path, "stream=color_primaries", "v:0") == "bt709"

    if Keyword.get(opts, :audio, true) do
      assert %Probe{has_audio?: true, audio_codec: "aac", audio_channels: 2} = probe
    else
      refute probe.has_audio?
    end

    assert {:ok, %Probe{width: tw, height: th}} = Probe.run(output.thumbnail_path)
    assert max(tw, th) <= 320
    assert File.stat!(output.thumbnail_path).size < 200_000
  end

  defp assert_only_outputs(dir),
    do: assert(dir |> File.ls!() |> Enum.sort() == ["thumbnail.jpg", "video.mp4"])

  test "mixed images with a short looping sound, skipping a corrupted image", %{tmp_dir: dir} do
    slides = Path.join(dir, "slides")
    File.mkdir_p!(slides)

    corrupted = Path.join(slides, "04.jpg")
    File.write!(corrupted, <<0xFF, 0xD8, 0xFF, 0xE0>> <> "truncated")

    images = [
      image!(slides, "01.jpg", "testsrc2", "1080x1440"),
      image!(slides, "02.jpg", "testsrc2", "1920x1080"),
      # PNG bytes with an alpha channel, named .jpg
      png!(slides, "03.jpg", "0x3366ff66", "1080x1350", "rgba"),
      corrupted,
      image!(slides, "05.jpg", "testsrc2", "1080x1440", ~w(-vf format=gray)),
      image!(slides, "06.jpg", "testsrc2", "1000x1000"),
      image!(slides, "07.jpg", "testsrc2", "1082x1440", ~w(-vf scale=1081:1439 -pix_fmt yuvj444p))
    ]

    audio = sound!(slides, "audio.mp3", 8, ~w(-c:a libmp3lame -b:a 128k))

    assert {:ok, output} = prepare(slideshow(dir, images, audio), dir)

    # 6 readable images, 3 of them 3:4; 3 s each (18 s) with the 8 s sound looped.
    assert_video(output, {1080, 1440}, 18.0)
    assert output.path == Path.join(dir, "video.mp4")
    assert output.thumbnail_path == Path.join(dir, "thumbnail.jpg")
    assert output.size <= 50 * @mb
    assert_only_outputs(dir)

    assert_in_delta String.to_float(ffprobe!(output.path, "stream=duration", "a:0")), 18.0, 0.05

    progress = progress_messages()
    assert %{percent: 100.0, detail: "Rendering slides 6/6"} in progress
    assert Enum.any?(progress, &match?(%{detail: "Encoding slideshow"}, &1))
    assert Enum.all?(progress, &(is_nil(&1.percent) or (&1.percent >= 0 and &1.percent <= 100)))
  end

  # The average colour of the frame at `seconds`, as {r, g, b}.
  defp color_at!(path, seconds) do
    {rgb, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-v error -ss #{seconds} -i #{path} -frames:v 1 -vf scale=1:1 -f rawvideo -pix_fmt rgb24 -)
      )

    <<r, g, b>> = rgb
    {r, g, b}
  end

  test "transparent and palette images that fill the canvas keep every frame", %{tmp_dir: dir} do
    # Such canvases once came out as RGBA PNGs between RGB ones, and the encode
    # dropped the frames around each change of pixel format.
    slides = Path.join(dir, "slides")
    File.mkdir_p!(slides)

    images = [
      image!(slides, "01.jpg", "color=c=white", "1080x1440"),
      png!(slides, "02.jpg", "0xff000080", "1080x1440", "rgba"),
      png!(slides, "03.jpg", "0x00ff00", "1080x1440", "pal8"),
      image!(slides, "04.jpg", "color=c=white", "1080x1440"),
      png!(slides, "05.jpg", "0xffffff80", "1080x1440", "ya8"),
      image!(slides, "06.jpg", "color=c=0x0000ff", "1080x1440")
    ]

    assert {:ok, probed} = Angler.Media.Slideshow.Images.probe(images)
    assert Enum.map(probed, & &1.alpha) == [false, true, true, false, true, false]

    assert {:ok, output} = prepare(slideshow(dir, images), dir)

    # 3 s per image, every slide in order (transparent areas over black).
    assert_video(output, {1080, 1440}, 18.0, audio: false)

    colors = for n <- 0..5, do: output.path |> color_at!(n * 3 + 1.5) |> color_name()
    assert colors == [:white, :half_red, :green, :white, :half_white, :blue]
  end

  defp color_name({r, g, b}) do
    half = 100..160

    cond do
      r >= 230 and g >= 230 and b >= 230 -> :white
      r in half and g in half and b in half -> :half_white
      r in half and g < 30 and b < 30 -> :half_red
      g >= 220 and r < 40 and b < 40 -> :green
      b >= 220 and r < 40 and g < 40 -> :blue
      true -> {r, g, b}
    end
  end

  test "a single image without sound shows for 3 seconds", %{tmp_dir: dir} do
    slides = Path.join(dir, "slides")
    File.mkdir_p!(slides)
    image = image!(slides, "01.jpg", "testsrc2", "2048x1366")

    assert {:ok, output} = prepare(slideshow(dir, [image]), dir)

    assert_video(output, {1620, 1080}, 3.0, audio: false)
    assert_only_outputs(dir)
  end

  test "many images with a long sound", %{tmp_dir: dir} do
    slides = Path.join(dir, "slides")
    File.mkdir_p!(slides)

    images =
      for n <- 1..12 do
        name = String.pad_leading("#{n}", 2, "0") <> ".jpg"
        image!(slides, name, "testsrc2", if(rem(n, 3) == 0, do: "640x360", else: "360x640"))
      end

    audio = sound!(slides, "audio.m4a", 40, ~w(-c:a aac -b:a 96k))

    assert {:ok, output} = prepare(slideshow(dir, images, audio), dir)

    # 12 images at clamp(40 / 12, 3, 6) = 3.33 s each: one pass of 40 s, no loop.
    assert_video(output, {1080, 1920}, 40.0)
    assert_only_outputs(dir)
  end

  test "stays within the download's maximum duration", %{tmp_dir: dir} do
    slides = Path.join(dir, "slides")
    File.mkdir_p!(slides)
    images = for n <- 1..3, do: image!(slides, "0#{n}.jpg", "testsrc2", "1080x1920")
    audio = sound!(slides, "audio.m4a", 20, ~w(-c:a aac -b:a 96k))

    download = %{slideshow(dir, images, audio) | max_duration: 10}
    assert {:ok, output} = prepare(download, dir)

    # 10 s of the 20 s sound in two slots of 5 s, faded out.
    assert_video(output, {1080, 1920}, 10.0)
    assert_in_delta String.to_float(ffprobe!(output.path, "stream=duration", "a:0")), 10.0, 0.05
  end

  test "falls back to the 720 canvas when the 1080 video is too large", %{tmp_dir: dir} do
    make = fn subdir ->
      entry = Path.join(dir, subdir)
      slides = Path.join(entry, "slides")
      File.mkdir_p!(slides)
      image = image!(slides, "01.jpg", "mandelbrot", "1080x1920")
      {entry, slideshow(entry, [image, image])}
    end

    {entry, download} = make.("large")
    assert {:ok, %Output{size: hd_size, width: 1080, height: 1920}} = prepare(download, entry)

    {entry, download} = make.("small")
    assert {:ok, %Output{size: size} = output} = prepare(download, entry, hd_size - 1)
    assert size < hd_size
    assert_video(output, {720, 1280}, 6.0, audio: false)
    assert_only_outputs(entry)
  end

  test "fails when even the 720 video is too large", %{tmp_dir: dir} do
    slides = Path.join(dir, "slides")
    File.mkdir_p!(slides)
    image = image!(slides, "01.jpg", "testsrc2", "1080x1920")

    assert {:error,
            %Error{kind: :too_large, message: "Could not make the slideshow fit into" <> _}} =
             prepare(slideshow(dir, [image]), dir, 5_000)
  end

  test "fails when no image can be read", %{tmp_dir: dir} do
    slides = Path.join(dir, "slides")
    File.mkdir_p!(slides)
    garbage = Path.join(slides, "01.jpg")
    File.write!(garbage, "not an image")

    assert {:error, %Error{kind: :unsupported, message: "Could not read the slideshow images"}} =
             prepare(slideshow(dir, [garbage, Path.join(slides, "02.jpg")]), dir)
  end
end
