defmodule Angler.Media.Prepare do
  @moduledoc """
  Makes a downloaded video Telegram-ready (`c:Angler.Media.prepare/3` for
  everything but slideshows).

  The source is probed and `Angler.Media.Plan` picks the cheapest step:

    * `:as_is` - the source is moved into place (remuxed instead when it is not an
      `.mp4` file in the output directory)
    * `:remux` / `:audio_reencode` - the video stream is copied; when the copy no
      longer fits the target (container overhead, re-encoded audio) it is
      transcoded after all
    * `{:transcode, params}` - encoded with ffmpeg, retried with a lower bitrate
      (up to twice) while the result is too large

  Every output is probed before it is accepted, and the thumbnail is taken from it.
  """
  require Logger

  alias Angler.Media
  alias Angler.Media.{Download, Error, Ffmpeg, Output, Plan, Probe}

  @max_encode_retries 2

  @doc "Prepares `download` in `dir`, see `Angler.Media.prepare/3`."
  @spec run(Download.t(), Path.t(), keyword()) :: {:ok, Output.t()} | {:error, Error.t()}
  def run(%Download{path: source} = download, dir, opts) do
    target = Keyword.fetch!(opts, :target_bytes)
    paths = Angler.Storage.output_paths(dir)

    job = %{
      dir: Path.expand(dir),
      video: paths.video,
      target: target,
      passlog: Path.join(dir, "x264"),
      on_progress: Keyword.get(opts, :on_progress) || fn _progress -> :ok end
    }

    try do
      with {:ok, probe} <- probe_source(source),
           probe = %{probe | duration: probe.duration || download.duration},
           {:ok, output, transcoded?} <- produce(Plan.decide(probe, target), probe, job) do
        thumbnail = Ffmpeg.thumbnail(output.path, paths.thumbnail, output.duration)
        if output.path != source, do: File.rm(source)

        {:ok,
         %Output{
           path: output.path,
           size: output.size,
           thumbnail_path: thumbnail,
           duration: output.duration && round(output.duration),
           width: output.display_width,
           height: output.display_height,
           video_codec: output.video_codec,
           transcoded: transcoded?
         }}
      end
    after
      Ffmpeg.remove_pass_logs(job.passlog)
    end
  end

  defp probe_source(path) do
    case Probe.run(path) do
      {:ok, %Probe{has_video?: false}} ->
        {:error, Error.new(:unsupported, "This post has no video")}

      {:ok, probe} ->
        {:ok, probe}

      {:error, %Error{kind: :unsupported} = error} ->
        {:error, %{error | message: "Downloaded file is not a playable video"}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp produce(:as_is, probe, job) do
    in_place? =
      Path.extname(probe.path) == ".mp4" and Path.dirname(Path.expand(probe.path)) == job.dir

    if in_place? and File.rename(probe.path, job.video) == :ok do
      {:ok, %{probe | path: job.video}, false}
    else
      produce(:remux, probe, job)
    end
  end

  defp produce(:remux, probe, job) do
    job.on_progress.(%{percent: nil, detail: "Remuxing"})

    with :ok <- Ffmpeg.remux(probe.path, job.video, probe.duration) do
      check_copied(probe, job)
    end
  end

  defp produce(:audio_reencode, probe, job) do
    job.on_progress.(%{percent: nil, detail: "Converting audio"})

    with :ok <- Ffmpeg.reencode_audio(probe.path, job.video, probe) do
      check_copied(probe, job)
    end
  end

  defp produce({:transcode, params}, probe, job), do: transcode(probe, params, job, 0)

  defp produce({:error, :too_long}, _probe, job) do
    {:error,
     Error.new(:too_large, "Video is too long to fit into #{Media.format_mb(job.target)}")}
  end

  defp produce({:error, :unknown_duration}, _probe, _job) do
    {:error, Error.new(:unsupported, "Could not determine the video duration")}
  end

  # A stream copy can end up slightly larger than its source (container overhead,
  # re-encoded audio): fall back to a transcode when it no longer fits.
  defp check_copied(probe, job) do
    with {:ok, size} <- output_size(job.video) do
      if size <= job.target do
        with {:ok, output} <- probe_output(job.video), do: {:ok, output, false}
      else
        produce(Plan.transcode(probe, job.target), probe, job)
      end
    end
  end

  defp transcode(probe, params, job, attempt) do
    opts = [passlog: job.passlog, duration: probe.duration, on_progress: job.on_progress]

    with :ok <- Ffmpeg.transcode(probe.path, job.video, params, opts),
         {:ok, size} <- output_size(job.video) do
      cond do
        size <= job.target ->
          with {:ok, output} <- probe_output(job.video), do: {:ok, output, true}

        attempt < @max_encode_retries ->
          Logger.info(
            "Encoded #{size} bytes for a #{job.target} byte target, retrying with a lower bitrate"
          )

          transcode(probe, Plan.retry_params(params, attempt + 1), job, attempt + 1)

        true ->
          message = "Could not make the video fit into #{Media.format_mb(job.target)}"
          {:error, Error.new(:too_large, message)}
      end
    end
  end

  defp output_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        {:ok, size}

      {:error, reason} ->
        {:error, Error.new(:internal, "ffmpeg wrote no output file (#{reason})")}
    end
  end

  defp probe_output(path) do
    case Probe.run(path) do
      {:ok, %Probe{has_video?: true} = probe} ->
        {:ok, probe}

      {:ok, _probe} ->
        {:error, Error.new(:internal, "ffmpeg produced a file without video")}

      {:error, error} ->
        {:error, %{error | kind: :internal, message: "ffmpeg produced an unreadable file"}}
    end
  end
end
