defmodule Angler.Media.Slideshow.Render do
  @moduledoc """
  Assembles downloaded slideshow images and sound into a Telegram-ready MP4, at
  most 90 s long (or the download's `:max_duration`, when shorter).

    1. probe every image (`Angler.Media.Slideshow.Images`), skipping unreadable ones
    2. pick the canvas and timeline (`Angler.Media.Slideshow.Plan`)
    3. render each image once onto a canvas PNG, a few at a time; images ffmpeg
       can't render are skipped too
    4. encode once: the PNGs through the concat demuxer, the sound looped and
       trimmed, H.264 (CRF with a VBV cap from the size budget) and AAC, fast start
    5. if the file exceeds the upload limit, repeat 3-4 on the 720 canvas presets
       with CRF 22; still too large fails with `:too_large`
    6. a thumbnail from the first canvas; the `slides` directory is deleted

  Commands are built by `Angler.Media.Slideshow.Commands`. Slides change with hard
  cuts. A crossfade would be possible without per-transition memory growth (unlike
  an `xfade` chain, ~24 MB per transition at 1080x1920): a single `blend` instance
  over the stream and a copy delayed with `tpad`, its opacity driven per
  transition window by `sendcmd` (see the slideshow research notes).
  """
  require Logger

  alias Angler.Media
  alias Angler.Media.{Download, Error, Ffmpeg, Output}
  alias Angler.Media.Slideshow.{Commands, Images, Plan, Tools}

  @render_timeout :timer.minutes(2)
  @thumbnail_timeout :timer.minutes(1)
  @thumbnail_max_bytes 200_000

  @doc """
  Turns a `%Download{kind: :slideshow}` into an `Angler.Media.Output`, see
  `c:Angler.Media.prepare/3` for `dir` and the options.
  """
  @spec run(Download.t(), Path.t(), keyword()) :: {:ok, Output.t()} | {:error, Error.t()}
  def run(%Download{kind: :slideshow} = download, dir, opts) do
    paths = Angler.Storage.output_paths(dir)

    job = %{
      work: Path.expand(download.path),
      video: paths.video,
      target: Keyword.fetch!(opts, :target_bytes),
      audio: audio(download),
      max_duration: download.max_duration,
      report: Keyword.get(opts, :on_progress) || fn _progress -> :ok end
    }

    with {:ok, images} <- Images.probe(download.images),
         {:ok, result} <- produce(images, :hd, job) do
      thumbnail = thumbnail(result.first_canvas, paths.thumbnail)
      remove_work_dir(job.work, dir)
      {width, height} = result.canvas

      {:ok,
       %Output{
         path: job.video,
         size: result.size,
         thumbnail_path: thumbnail,
         duration: round(result.plan.duration),
         width: width,
         height: height,
         video_codec: "h264",
         transcoded: true
       }}
    end
  end

  defp audio(%Download{audio_path: nil}), do: nil

  defp audio(%Download{audio_path: path, duration: duration})
       when is_number(duration) and duration > 0.1,
       do: %{path: path, duration: duration}

  defp audio(%Download{}) do
    Logger.warning("The slideshow sound has no known duration, leaving it out")
    nil
  end

  defp produce([], _size, _job),
    do: {:error, Error.new(:unsupported, "Could not read the slideshow images")}

  defp produce(images, size, job) do
    canvas = Plan.canvas(Enum.map(images, &{&1.width, &1.height}), size)

    with {:ok, rendered} <- render_all(images, canvas, job),
         plan = Plan.timeline(length(rendered), job.audio && job.audio.duration, job.max_duration),
         :ok <- encode(Enum.map(rendered, &elem(&1, 1)), plan, size, job),
         {:ok, bytes} <- output_size(job.video) do
      cond do
        bytes <= job.target ->
          {:ok, %{canvas: canvas, plan: plan, size: bytes, first_canvas: elem(hd(rendered), 1)}}

        size == :hd ->
          Logger.info(
            "Slideshow is #{bytes} bytes for a #{job.target} byte target, retrying at 720p"
          )

          produce(Enum.map(rendered, &elem(&1, 0)), :sd, job)

        true ->
          {:error,
           Error.new(
             :too_large,
             "Could not make the slideshow fit into #{Media.format_mb(job.target)}"
           )}
      end
    end
  end

  # Renders every image onto the canvas, returning the {image, png} pairs that worked.
  defp render_all(images, canvas, job) do
    total = length(images)

    images
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {image, index} ->
        png = Path.join(job.work, "canvas-#{String.pad_leading("#{index}", 3, "0")}.png")

        {image, png,
         Tools.ffmpeg(Commands.render_args(image, canvas, png), timeout: @render_timeout)}
      end,
      max_concurrency: Images.concurrency(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({[], 0}, fn {:ok, {image, png, result}}, {rendered, done} ->
      job.report.(%{
        percent: (done + 1) / total * 100,
        detail: "Rendering slides #{done + 1}/#{total}"
      })

      case result do
        :ok ->
          {:cont, {[{image, png} | rendered], done + 1}}

        {:failed, error} ->
          Logger.warning(
            "Skipping slideshow image #{Path.basename(image.path)}: #{error.message}"
          )

          {:cont, {rendered, done + 1}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      {[], _done} -> {:error, Error.new(:unsupported, "Could not read the slideshow images")}
      {rendered, _done} -> {:ok, Enum.reverse(rendered)}
    end
  end

  defp encode(canvases, plan, size, job) do
    list = Path.join(job.work, "list.ffconcat")
    quality = Plan.quality(size)
    maxrate = Plan.maxrate_kbps(plan.duration, job.target, job.audio != nil, quality.max_kbps)
    report = Media.throttle(job.report)

    args =
      Commands.encode_args(list, job.audio && job.audio.path, plan,
        output: job.video,
        crf: quality.crf,
        maxrate_kbps: maxrate
      )

    on_line = fn line ->
      with percent when is_float(percent) <- Ffmpeg.progress_percent(line, plan.duration) do
        report.(%{percent: percent, detail: "Encoding slideshow"})
      end
    end

    job.report.(%{percent: 0.0, detail: "Encoding slideshow"})

    with :ok <- write_list(list, Commands.ffconcat(plan, canvases)) do
      case Tools.ffmpeg(args, timeout: Ffmpeg.timeout(plan.duration), on_line: on_line) do
        :ok -> :ok
        {_failed_or_error, error} -> {:error, error}
      end
    end
  end

  defp write_list(path, contents) do
    case File.write(path, contents) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.new(:internal, "Could not write #{path}: #{:file.format_error(reason)}")}
    end
  end

  defp output_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> {:ok, size}
      _other -> {:error, Error.new(:internal, "ffmpeg wrote no slideshow video")}
    end
  end

  # A missing thumbnail never fails a job.
  defp thumbnail(canvas, output) do
    case Enum.find_value([4, 10], &thumbnail(canvas, output, &1)) do
      nil ->
        Logger.warning("Could not create a thumbnail for the slideshow")
        File.rm(output)
        nil

      path ->
        path
    end
  end

  defp thumbnail(canvas, output, quality) do
    args = Commands.thumbnail_args(canvas, output, quality)

    with :ok <- Tools.ffmpeg(args, timeout: @thumbnail_timeout),
         {:ok, %File.Stat{size: size}} when size > 0 and size < @thumbnail_max_bytes <-
           File.stat(output) do
      output
    else
      _other -> nil
    end
  end

  # The slides directory holds the downloads and canvases (about 1.5 MB per 1080p
  # canvas); it always lies inside the entry directory.
  defp remove_work_dir(work, dir) do
    if Path.dirname(work) == Path.expand(dir), do: File.rm_rf(work)
  end
end
