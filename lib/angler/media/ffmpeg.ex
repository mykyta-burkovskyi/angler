defmodule Angler.Media.Ffmpeg do
  @moduledoc """
  Runs ffmpeg: stream-copy remuxes, audio re-encodes, two-pass H.264 transcodes that
  hit a size budget (see `Angler.Media.Plan`), and thumbnails.

  Transcodes scale to a target short side with a filter that keeps both dimensions
  even (libx264 rejects odd sizes) and works for portrait video, convert to 8-bit
  `yuv420p`, and auto-rotate (the output has no display matrix, so its dimensions
  are the display dimensions). Cover-art streams are skipped (`-map 0:V:0`).

  Known limitation: HDR sources (PQ/HLG) are converted to 8-bit SDR `yuv420p`
  without tone mapping, so their colors look washed out.
  """
  require Logger

  alias Angler.Media
  alias Angler.Media.{Command, Error, Plan, Probe}

  @min_timeout :timer.minutes(10)
  @max_timeout :timer.hours(3)
  @thumbnail_timeout :timer.minutes(1)
  @thumbnail_max_bytes 200_000
  @pass_log_suffixes ["-0.log", "-0.log.mbtree", "-0.log.temp", "-0.log.mbtree.temp"]
  @error_output_lines 30

  @doc "Copies the first video and audio stream into a fast-start MP4."
  @spec remux(Path.t(), Path.t(), number() | nil) :: :ok | {:error, Error.t()}
  def remux(input, output, duration), do: run(remux_args(input, output), timeout(duration))

  @doc "ffmpeg arguments for `remux/3`."
  @spec remux_args(Path.t(), Path.t()) :: [String.t()]
  def remux_args(input, output) do
    common_input_args(input) ++
      ~w(-map 0:V:0 -map 0:a:0? -c copy -movflags +faststart) ++ [output]
  end

  @doc "Copies the video and re-encodes the audio to AAC (downmixing surround to stereo)."
  @spec reencode_audio(Path.t(), Path.t(), Probe.t()) :: :ok | {:error, Error.t()}
  def reencode_audio(input, output, probe) do
    run(audio_args(input, output, probe.audio_channels), timeout(probe.duration))
  end

  @doc "ffmpeg arguments for `reencode_audio/3`, given the source's audio channel count."
  @spec audio_args(Path.t(), Path.t(), pos_integer() | nil) :: [String.t()]
  def audio_args(input, output, channels) do
    downmix = if is_integer(channels) and channels > 2, do: ["-ac", "2"], else: []

    common_input_args(input) ++
      ~w(-map 0:V:0 -map 0:a:0 -c:v copy -c:a aac -b:a 128k) ++
      downmix ++ ~w(-movflags +faststart) ++ [output]
  end

  @doc """
  Two-pass H.264/AAC encode of `input` into `output` with `Plan` params.

  Options:

    * `:passlog` (required) - path prefix of the x264 pass log files
    * `:duration` - source duration in seconds, for progress and the time limit
    * `:on_progress` - `t:Angler.Media.progress_fun/0`; pass 1 reports 0-50%,
      pass 2 50-100%
  """
  @spec transcode(Path.t(), Path.t(), Plan.params(), keyword()) :: :ok | {:error, Error.t()}
  def transcode(input, output, params, opts) do
    passlog = Keyword.fetch!(opts, :passlog)
    duration = Keyword.get(opts, :duration)
    report = Media.throttle(Keyword.get(opts, :on_progress) || fn _progress -> :ok end)

    run_pass = fn pass ->
      args = transcode_args(input, output, params, pass, passlog)
      run(args, timeout(duration), progress_handler(report, pass, params, duration))
    end

    with :ok <- run_pass.(1), do: run_pass.(2)
  end

  @doc "ffmpeg arguments for pass 1 or 2 of `transcode/4`."
  @spec transcode_args(Path.t(), Path.t(), Plan.params(), 1 | 2, Path.t()) :: [String.t()]
  def transcode_args(input, _output, params, 1, passlog) do
    common_input_args(input) ++
      ~w(-map 0:V:0 -an -sn -dn) ++
      video_args(params) ++
      ["-pass", "1", "-passlogfile", passlog] ++
      progress_args() ++ ~w(-f null /dev/null)
  end

  def transcode_args(input, output, params, 2, passlog) do
    video_kbps = params.video_kbps

    common_input_args(input) ++
      ~w(-map 0:V:0) ++
      if(params.audio_kbps > 0, do: ~w(-map 0:a:0?), else: []) ++
      ~w(-sn -dn -map_metadata -1 -map_chapters -1) ++
      video_args(params) ++
      ["-maxrate", "#{floor(video_kbps * 1.5)}k", "-bufsize", "#{video_kbps * 2}k"] ++
      ["-pass", "2", "-passlogfile", passlog] ++
      audio_encode_args(params) ++
      ~w(-movflags +faststart) ++ progress_args() ++ [output]
  end

  defp video_args(params) do
    ["-vf", scale_filter(params.short_side, params.fps)] ++
      ["-c:v", "libx264", "-preset", params.preset, "-profile:v", "high"] ++
      ["-b:v", "#{params.video_kbps}k"]
  end

  defp audio_encode_args(%{audio_kbps: 0}), do: ["-an"]

  defp audio_encode_args(params) do
    channels = if params.audio_channels, do: ["-ac", "#{params.audio_channels}"], else: []
    ["-c:a", "aac", "-b:a", "#{params.audio_kbps}k"] ++ channels
  end

  defp common_input_args(input), do: ~w(-hide_banner -loglevel error -nostdin -y -i) ++ [input]

  defp progress_args, do: ~w(-progress pipe:1 -nostats -stats_period 1)

  @doc """
  Video filter scaling to short side `short_side` without upscaling, keeping both
  dimensions even for landscape and portrait input, optionally capping the frame
  rate, and converting to `yuv420p`. Passed to ffmpeg as a single argument.
  """
  @spec scale_filter(pos_integer(), pos_integer() | nil) :: String.t()
  def scale_filter(short_side, fps) do
    s = Integer.to_string(short_side)

    scale =
      "scale=w='if(gte(iw,ih),-2,trunc(min(#{s},iw)/2)*2)'" <>
        ":h='if(gte(iw,ih),trunc(min(#{s},ih)/2)*2,-2)'"

    Enum.join([scale] ++ if(fps, do: ["fps=#{fps}"], else: []) ++ ["format=yuv420p"], ",")
  end

  defp progress_handler(report, pass, params, duration) do
    detail = "Encoding #{params.short_side}p · pass #{pass}/2"

    fn line ->
      with percent when is_float(percent) <- progress_percent(line, duration) do
        report.(%{percent: (pass - 1) * 50 + percent / 2, detail: detail})
      end
    end
  end

  @doc """
  Percent done from an ffmpeg `-progress` line (`out_time_us=...`, or `out_time_ms=...`
  which is also in microseconds), or nil for other lines.
  """
  @spec progress_percent(String.t(), number() | nil) :: float() | nil
  def progress_percent(line, duration) when is_number(duration) and duration > 0 do
    with [key, value] when key in ["out_time_us", "out_time_ms"] <-
           String.split(line, "=", parts: 2),
         {microseconds, ""} <- Integer.parse(value) do
      (microseconds / 1_000_000 / duration * 100) |> max(0.0) |> min(100.0)
    else
      _other -> nil
    end
  end

  def progress_percent(_line, _duration), do: nil

  @doc """
  Writes a JPEG thumbnail (at most 320x320 and under 200 kB, as Telegram requires)
  from about one second into the video. Returns its path, or nil when it could not be
  created: a missing thumbnail never fails a job.
  """
  @spec thumbnail(Path.t(), Path.t(), number() | nil) :: Path.t() | nil
  def thumbnail(input, output, duration) do
    seek = if is_number(duration) and duration > 0, do: min(1.0, duration / 2), else: 0.0

    result =
      Enum.find_value([4, 10], {:error, :too_large}, fn quality ->
        with :ok <- run(thumbnail_args(input, output, seek, quality), @thumbnail_timeout),
             {:ok, %File.Stat{size: size}} when size > 0 <- File.stat(output) do
          if size < @thumbnail_max_bytes, do: {:ok, output}
        else
          {:error, %Error{message: message}} -> {:error, message}
          _empty_or_missing -> {:error, :no_output}
        end
      end)

    case result do
      {:ok, path} ->
        path

      {:error, reason} ->
        Logger.warning("Could not create a thumbnail for #{input}: #{inspect(reason)}")
        File.rm(output)
        nil
    end
  end

  @doc "ffmpeg arguments for `thumbnail/3`, seeking to `seek` seconds with JPEG `quality` (2-31)."
  @spec thumbnail_args(Path.t(), Path.t(), float(), pos_integer()) :: [String.t()]
  def thumbnail_args(input, output, seek, quality) do
    ~w(-hide_banner -loglevel error -nostdin -y -ss) ++
      [:erlang.float_to_binary(seek, decimals: 3), "-i", input] ++
      ~w(-map 0:V:0 -frames:v 1 -update 1) ++
      ["-vf", "scale=320:320:force_original_aspect_ratio=decrease", "-q:v", "#{quality}", output]
  end

  @doc "Deletes the x264 two-pass log files written with prefix `passlog`."
  @spec remove_pass_logs(Path.t()) :: :ok
  def remove_pass_logs(passlog) do
    Enum.each(@pass_log_suffixes, &File.rm(passlog <> &1))
  end

  @doc """
  Time limit for one ffmpeg run over a video of `duration` seconds: four times its
  duration rounded up to whole minutes, at least 10 minutes and at most 3 hours.
  """
  @spec timeout(number() | nil) :: pos_integer()
  def timeout(duration) when is_number(duration) do
    minutes = ceil(duration * 4 / 60)
    (minutes * 60_000) |> max(@min_timeout) |> min(@max_timeout)
  end

  def timeout(_duration), do: @min_timeout

  defp run(args, timeout, on_line \\ nil) do
    :ffmpeg_path
    |> Media.config("ffmpeg")
    |> Command.run(args, timeout: timeout, on_line: on_line)
    |> interpret(timeout)
  end

  @doc """
  Turns the `Angler.Media.Command` result of an ffmpeg run limited to `timeout`
  milliseconds into `:ok` or an error.

  Running out of time is `:too_large` rather than a retried `:timeout`: the limit
  scales with the video's duration, so a retry on the same machine takes as long.
  """
  @spec interpret(Command.result(), pos_integer()) :: :ok | {:error, Error.t()}
  def interpret(result, timeout) do
    case result do
      {:ok, %{exit_status: 0}} ->
        :ok

      {:ok, %{exit_status: status, output: lines}} ->
        messages = Enum.reject(lines, &progress_line?/1)
        detail = if messages == [], do: "", else: ": " <> List.last(messages)

        {:error,
         Error.new(:internal, "ffmpeg failed (exit #{status})" <> detail, output(messages))}

      {:error, :timeout, lines} ->
        message = "Processing the video took longer than #{Media.format_duration(timeout)}"
        {:error, Error.new(:too_large, message, output(lines))}

      {:error, :enoent} ->
        {:error, Error.new(:internal, "ffmpeg not found")}

      {:error, reason} ->
        {:error, Error.new(:internal, "Could not start ffmpeg: #{inspect(reason)}")}

      {:error, reason, lines} ->
        {:error, Error.new(:internal, "ffmpeg failed: #{inspect(reason)}", output(lines))}
    end
  end

  defp progress_line?(line), do: Regex.match?(~r/^[a-z0-9_]+=/, line)

  defp output(lines) do
    lines |> Enum.reject(&progress_line?/1) |> Enum.take(-@error_output_lines) |> Enum.join("\n")
  end
end
