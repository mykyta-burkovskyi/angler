defmodule Angler.Media.Slideshow.CommandsTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Slideshow.{Commands, Plan}

  defp image(width, height, opts \\ []) do
    %{
      path: "/data/media/e/slides/01.jpg",
      width: width,
      height: height,
      label: Keyword.get(opts, :label, "v:0"),
      alpha: Keyword.get(opts, :alpha, false)
    }
  end

  defp value_after(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  describe "canvas_filter/2" do
    test "fills the canvas when the aspect ratio is within 2%" do
      assert Commands.canvas_filter(image(1081, 1439), {1080, 1440}) ==
               "[0:v:0]scale=1080:1440:force_original_aspect_ratio=increase:flags=lanczos," <>
                 "crop=1080:1440,setsar=1,format=rgb24[v]"
    end

    test "fits other images over a blurred copy, at even sizes" do
      assert Commands.canvas_filter(image(1920, 1080), {1080, 1920}) ==
               "[0:v:0]split=2[fg0][bg0];" <>
                 "[bg0]scale=136:240:force_original_aspect_ratio=increase,crop=136:240," <>
                 "gblur=sigma=10,eq=brightness=-0.18:saturation=1.2," <>
                 "scale=1080:1920:flags=bicubic,setsar=1[bg];" <>
                 "[fg0]scale=1080:1920:force_original_aspect_ratio=decrease:force_divisible_by=2:" <>
                 "flags=lanczos,setsar=1[fg];" <>
                 "[bg][fg]overlay=x=(W-w)/2:y=(H-h)/2,format=rgb24[v]"

      assert Commands.canvas_filter(image(1000, 1000), {1080, 1440}) =~
               "[bg0]scale=136:180:force_original_aspect_ratio=increase,crop=136:180,"

      assert Commands.canvas_filter(image(1000, 1000), {720, 1280}) =~ "scale=90:160:"
    end

    test "composites transparent images over black and reads tile grids as a group" do
      assert Commands.canvas_filter(image(1080, 1350, alpha: true), {1080, 1350}) =~
               ~r/^\[0:v:0\]format=rgba,premultiply=inplace=1,scale=1080:1350:/

      assert Commands.canvas_filter(image(1080, 1440, label: "g:0"), {1080, 1920}) =~
               ~r/^\[0:g:0\]split=2/
    end
  end

  test "render_args/3 decodes once and writes one fast PNG" do
    args = Commands.render_args(image(1920, 1080), {1620, 1080}, "/w/canvas-001.png")

    assert [
             "-hide_banner",
             "-nostdin",
             "-loglevel",
             "error",
             "-y",
             "-i",
             "/data/media/e/slides/01.jpg" | _
           ] =
             args

    assert value_after(args, "-filter_complex") =~ "[v]"
    assert value_after(args, "-map") == "[v]"
    assert value_after(args, "-frames:v") == "1"
    assert value_after(args, "-c:v") == "png"
    # Always RGB, even for transparent images: the encode needs one pixel format.
    assert value_after(args, "-pix_fmt") == "rgb24"
    assert List.last(args) == "/w/canvas-001.png"
    refute "-loop" in args
  end

  test "probe_args/1 reads the first frame, streams and stream groups as JSON" do
    assert Commands.probe_args("/x/01.jpg") == [
             "-v",
             "error",
             "-show_stream_groups",
             "-show_streams",
             "-show_frames",
             "-read_intervals",
             "%+#1",
             "-select_streams",
             "v:0",
             "-of",
             "json",
             "/x/01.jpg"
           ]
  end

  describe "ffconcat/2" do
    test "lists every slot with the frame rate option and repeats the last file" do
      plan = Plan.timeline(2, 16.3265)

      assert Commands.ffconcat(plan, ["/w/canvas-001.png", "/w/canvas-002.png"]) == """
             ffconcat version 1.0
             file '/w/canvas-001.png'
             option framerate 30
             duration 5.433333
             file '/w/canvas-002.png'
             option framerate 30
             duration 5.466667
             file '/w/canvas-001.png'
             option framerate 30
             duration 5.433333
             file '/w/canvas-001.png'
             option framerate 30
             """
    end

    test "uses absolute paths and escapes quotes" do
      plan = Plan.timeline(1, nil)
      list = Commands.ffconcat(plan, ["/tmp/it's here/canvas-001.png"])

      assert list =~ ~S"file '/tmp/it'\''s here/canvas-001.png'"
      assert Commands.ffconcat(plan, ["relative.png"]) =~ "file '#{File.cwd!()}/relative.png'"
    end

    test "quote_path/1 closes, escapes and reopens the quote" do
      assert Commands.quote_path("/a/b.png") == "'/a/b.png'"
      assert Commands.quote_path("/a/'b'.png") == ~S"'/a/'\''b'\''.png'"
    end
  end

  describe "encode_args/4" do
    test "encodes H.264/AAC with the budget cap, trims the sound and fades it" do
      plan = Plan.timeline(3, 8.0)

      args =
        Commands.encode_args("/w/list.ffconcat", "/w/audio.mp3", plan,
          output: "/e/video.mp4",
          crf: 20,
          maxrate_kbps: 3000
        )

      # The filtergraph is never rebuilt mid-stream: that drops duplicated frames.
      assert Enum.take(args, 17) ==
               ~w(-hide_banner -nostdin -loglevel error -y -reinit_filter 0) ++
                 ~w(-f concat -safe 0 -i /w/list.ffconcat -stream_loop -1 -i /w/audio.mp3)

      assert value_after(args, "-filter_complex") ==
               "[0:v:0]scale=out_color_matrix=bt709:out_range=tv,format=yuv420p," <>
                 "setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709," <>
                 "setsar=1,fps=30[v];" <>
                 "[1:a:0]asetpts=N/SR/TB,atrim=end=9,afade=t=out:st=7.5:d=1.5[a]"

      assert Enum.count(args, &(&1 == "-map")) == 2
      assert value_after(args, "-map") == "[v]"
      assert "[a]" in args
      assert value_after(args, "-c:v") == "libx264"
      assert value_after(args, "-preset") == "veryfast"
      assert value_after(args, "-pix_fmt") == "yuv420p"
      assert value_after(args, "-crf") == "20"
      assert value_after(args, "-maxrate") == "3000k"
      assert value_after(args, "-bufsize") == "6000k"
      assert value_after(args, "-c:a") == "aac"
      assert value_after(args, "-b:a") == "128k"
      assert value_after(args, "-ac") == "2"
      assert value_after(args, "-t") == "9"
      assert value_after(args, "-movflags") == "+faststart"
      assert value_after(args, "-progress") == "pipe:1"
      assert List.last(args) == "/e/video.mp4"
    end

    test "does not loop a sound that is long enough" do
      args =
        Commands.encode_args("/w/list", "/w/audio.m4a", Plan.timeline(4, 55.4),
          output: "/e/v.mp4",
          crf: 22,
          maxrate_kbps: 2000
        )

      refute "-stream_loop" in args
      assert value_after(args, "-filter_complex") =~ ";[1:a:0]asetpts=N/SR/TB,atrim=end=55.4[a]"
      assert value_after(args, "-t") == "55.4"
      assert value_after(args, "-crf") == "22"
    end

    test "leaves out everything audio without a sound" do
      args =
        Commands.encode_args("/w/list", nil, Plan.timeline(12, nil),
          output: "/e/v.mp4",
          crf: 20,
          maxrate_kbps: 3000
        )

      assert value_after(args, "-filter_complex") =~ ~r/fps=30\[v\]$/
      refute Enum.any?(args, &(&1 in ["[a]", "-c:a", "-stream_loop", "-b:a"]))
      assert Enum.count(args, &(&1 == "-i")) == 1
      assert value_after(args, "-t") == "36"
    end
  end

  test "audio_filter/1 puts the sample-count timestamps before the trim" do
    assert Commands.audio_filter(%Plan{duration: 90.0, audio_fade: 1.5}) ==
             "[1:a:0]asetpts=N/SR/TB,atrim=end=90,afade=t=out:st=88.5:d=1.5[a]"

    assert Commands.audio_filter(%Plan{duration: 490 / 30, audio_fade: nil}) ==
             "[1:a:0]asetpts=N/SR/TB,atrim=end=16.333333[a]"
  end

  test "thumbnail_args/3 scales the first canvas to at most 320 px" do
    args = Commands.thumbnail_args("/w/canvas-001.png", "/e/thumbnail.jpg", 4)

    assert value_after(args, "-i") == "/w/canvas-001.png"

    assert value_after(args, "-vf") ==
             "scale=320:320:force_original_aspect_ratio=decrease:force_divisible_by=2:" <>
               "flags=lanczos,format=yuvj420p"

    assert value_after(args, "-q:v") == "4"
    assert List.last(args) == "/e/thumbnail.jpg"
  end

  test "number/1 formats seconds without trailing zeros" do
    assert Commands.number(3) == "3"
    assert Commands.number(90.0) == "90"
    assert Commands.number(77 / 30) == "2.566667"
    assert Commands.number(0.5) == "0.5"
    assert Commands.number(0.0) == "0"
    assert Commands.number(100) == "100"
  end
end
