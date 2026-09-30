defmodule Angler.Media.Slideshow.Commands do
  @moduledoc """
  Argument lists, filtergraphs and the concat list for slideshows (pure).

  Each image is decoded once and rendered to a canvas-sized RGB PNG
  (`render_args/3`): images within 2% of the canvas aspect ratio fill it (scaled to
  cover, then cropped); others are fitted over a blurred, darkened copy of
  themselves ("blur pad", blurred at 1/8 size, which is cheap and smooth).
  Transparent areas are composited over black. HEIC/AVIF tile grids are read as
  stream group `g:0` (`[0:v]` would be a single 512 px tile).

  One encode then plays the PNGs through the concat demuxer (`ffconcat/2`): the
  `option framerate` line gives every image a 1/30 time base, so cuts land exactly
  on the planned frames. The RGB to BT.709 conversion runs once per image and `fps`
  duplicates frames by reference.

  A post's clip of a longer song is cut into a FLAC file of its own first
  (`clip_args/3`), so the encode can loop it like any other sound.
  """
  alias Angler.Media.Slideshow.{Clip, Plan}

  @base ~w(-hide_banner -nostdin -loglevel error -y)
  @fill_tolerance 0.02
  @bt709 "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p," <>
           "setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709"
  @thumbnail_filter "scale=320:320:force_original_aspect_ratio=decrease:force_divisible_by=2:" <>
                      "flags=lanczos,format=yuvj420p"

  @typedoc "A probed image, see `Angler.Media.Slideshow.Images`."
  @type image :: %{
          path: Path.t(),
          width: pos_integer(),
          height: pos_integer(),
          label: String.t(),
          alpha: boolean()
        }

  @doc """
  ffprobe arguments reading the first stream, stream groups and first frame of an
  image as JSON: frame dimensions and side data carry the EXIF rotation, stream
  groups the HEIC/AVIF tile grid.
  """
  @spec probe_args(Path.t()) :: [String.t()]
  def probe_args(path) do
    ~w(-v error -show_stream_groups -show_streams -show_frames -read_intervals %+#1) ++
      ~w(-select_streams v:0 -of json) ++ [path]
  end

  @doc """
  ffmpeg arguments rendering `image` onto a `{width, height}` canvas PNG at `output`.

  The PNG is always RGB without alpha: ffmpeg would otherwise write RGBA for some
  images (it adds an alpha conversion after `premultiply`), and the concat demuxer
  drops frames where the pixel format of its input changes.
  """
  @spec render_args(image(), {pos_integer(), pos_integer()}, Path.t()) :: [String.t()]
  def render_args(image, canvas, output) do
    @base ++
      ["-i", image.path, "-filter_complex", canvas_filter(image, canvas), "-map", "[v]"] ++
      ~w(-frames:v 1 -update 1 -c:v png -pix_fmt rgb24 -compression_level 1) ++ [output]
  end

  @doc "The filtergraph of `render_args/3`, with output label `[v]`."
  @spec canvas_filter(image(), {pos_integer(), pos_integer()}) :: String.t()
  def canvas_filter(image, {w, h}) do
    input =
      "[0:#{image.label}]" <> if(image.alpha, do: "format=rgba,premultiply=inplace=1,", else: "")

    if abs(:math.log(image.width / image.height / (w / h))) < @fill_tolerance do
      input <>
        "scale=#{w}:#{h}:force_original_aspect_ratio=increase:flags=lanczos," <>
        "crop=#{w}:#{h},setsar=1,format=rgb24[v]"
    else
      {bw, bh} = {even(div(w, 8)), even(div(h, 8))}

      input <>
        "split=2[fg0][bg0];" <>
        "[bg0]scale=#{bw}:#{bh}:force_original_aspect_ratio=increase,crop=#{bw}:#{bh}," <>
        "gblur=sigma=10,eq=brightness=-0.18:saturation=1.2," <>
        "scale=#{w}:#{h}:flags=bicubic,setsar=1[bg];" <>
        "[fg0]scale=#{w}:#{h}:force_original_aspect_ratio=decrease:force_divisible_by=2:" <>
        "flags=lanczos,setsar=1[fg];" <>
        "[bg][fg]overlay=x=(W-w)/2:y=(H-h)/2,format=rgb24[v]"
    end
  end

  defp even(n), do: n + rem(n, 2)

  @doc """
  The concat demuxer list playing the plan's slots, where `canvases` holds the PNG
  of each image index. The last file is listed again without a duration (the
  demuxer only honours a duration when another entry follows); `-t` trims it.
  """
  @spec ffconcat(Plan.t(), [Path.t()]) :: String.t()
  def ffconcat(%Plan{slots: slots, fps: fps}, canvases) do
    canvases = List.to_tuple(canvases)
    {last_index, _frames} = List.last(slots)

    entries =
      Enum.map(slots, fn {index, frames} ->
        [file_entry(elem(canvases, index), fps), "duration #{number(frames / fps)}\n"]
      end)

    IO.iodata_to_binary([
      "ffconcat version 1.0\n",
      entries,
      file_entry(elem(canvases, last_index), fps)
    ])
  end

  defp file_entry(path, fps),
    do: "file #{quote_path(Path.expand(path))}\noption framerate #{fps}\n"

  @doc ~S|Quotes a path for a concat list: `'` becomes `'\''`.|
  @spec quote_path(Path.t()) :: String.t()
  def quote_path(path), do: "'" <> String.replace(path, "'", ~S('\'')) <> "'"

  @doc """
  ffmpeg arguments encoding the concat list `list` (plus `audio`, a path or nil)
  into an H.264/AAC fast-start MP4, following `plan`.

  `-reinit_filter 0` keeps the filtergraph when a canvas has other frame
  properties than the first (the leading `scale` adapts to each frame): rebuilding
  it mid-stream loses the frames the concat demuxer duplicated.

  Options: `:output` (required), `:crf` (required), `:maxrate_kbps` (required).
  """
  @spec encode_args(Path.t(), Path.t() | nil, Plan.t(), keyword()) :: [String.t()]
  def encode_args(list, audio, %Plan{} = plan, opts) do
    maxrate = Keyword.fetch!(opts, :maxrate_kbps)
    video = "[0:v:0]#{@bt709},setsar=1,fps=#{plan.fps}[v]"

    {audio_input, graph, audio_output} =
      if audio do
        loop = if plan.audio_loop, do: ~w(-stream_loop -1), else: []

        {loop ++ ["-i", audio], video <> ";" <> audio_filter(plan),
         ~w(-map [a] -c:a aac -b:a 128k -ac 2)}
      else
        {[], video, []}
      end

    @base ++
      ~w(-reinit_filter 0 -f concat -safe 0 -i) ++
      [list] ++
      audio_input ++
      ["-filter_complex", graph, "-map", "[v]"] ++
      ~w(-c:v libx264 -preset veryfast -tune stillimage -profile:v high -pix_fmt yuv420p) ++
      ["-crf", "#{Keyword.fetch!(opts, :crf)}", "-maxrate", "#{maxrate}k"] ++
      ["-bufsize", "#{2 * maxrate}k", "-g", "#{plan.fps * 10}"] ++
      audio_output ++
      ["-t", number(plan.duration)] ++
      ~w(-map_metadata -1 -movflags +faststart -progress pipe:1 -nostats) ++
      [Keyword.fetch!(opts, :output)]
  end

  @doc """
  The audio filtergraph of `encode_args/4`: sample-count timestamps first (the
  timestamps of a `-stream_loop` input are not reliable for trimming), trimmed to
  the video length, faded out when the sound does not end with the video.
  """
  @spec audio_filter(Plan.t()) :: String.t()
  def audio_filter(%Plan{duration: duration, audio_fade: fade}) do
    fade_out =
      if fade, do: ",afade=t=out:st=#{number(duration - fade)}:d=#{number(fade)}", else: ""

    "[1:a:0]asetpts=N/SR/TB,atrim=end=#{number(duration)}" <> fade_out <> "[a]"
  end

  @doc """
  ffmpeg arguments cutting the window `cut` out of the song at `input` into a
  16-bit FLAC file at `output`, faded out over `cut.fade` seconds when set.

  The song is decoded from its start and trimmed on sample-count timestamps, which
  is sample exact whatever the container's timestamps or an MP3 seek table say (an
  input `-ss` is approximate for VBR MP3; a stream copy cuts on packet boundaries
  and clicks where the clip loops). The second `asetpts` makes the fade's start
  relative to the clip. `asetnsamples` hands the encoder frames of 4096 samples:
  ffmpeg opens the FLAC encoder with the first frame's sample count as its block
  size, and after `atrim` that frame is the rest of a decoded frame, which can be
  a few samples long (under 16 fails the cut, a few hundred bloat the file).
  """
  @spec clip_args(Path.t(), Clip.cut(), Path.t()) :: [String.t()]
  def clip_args(input, %{start: start, stop: stop, fade: fade}, output) do
    fade_out =
      if fade, do: ",afade=t=out:st=#{number(stop - start - fade)}:d=#{number(fade)}", else: ""

    filter =
      "asetpts=N/SR/TB,atrim=start=#{number(start)}:end=#{number(stop)},asetpts=N/SR/TB" <>
        fade_out <> ",asetnsamples=n=4096:p=0"

    @base ++
      ["-i", input, "-map", "0:a:0", "-af", filter] ++
      ~w(-c:a flac -sample_fmt s16 -map_metadata -1 -f flac) ++ [output]
  end

  @doc "ffmpeg arguments for a JPEG thumbnail (at most 320x320) of a canvas PNG."
  @spec thumbnail_args(Path.t(), Path.t(), pos_integer()) :: [String.t()]
  def thumbnail_args(canvas, output, quality) do
    @base ++
      ["-i", canvas, "-vf", @thumbnail_filter] ++
      ~w(-frames:v 1 -update 1 -q:v) ++ ["#{quality}", output]
  end

  @doc ~S'Formats seconds for filter arguments: `2.566667`, `3`, `0.5`.'
  @spec number(number()) :: String.t()
  def number(value) do
    formatted =
      (value / 1)
      |> :erlang.float_to_binary(decimals: 6)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    if formatted in ["", "-0"], do: "0", else: formatted
  end
end
