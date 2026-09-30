defmodule Angler.Media.Ytdlp do
  @moduledoc """
  Downloads one video with yt-dlp, and reads the metadata of a post's items
  (`metadata/3`, `Angler.Media.Ytdlp.Metadata`).

  The format selection prefers H.264/AAC in MP4 up to 1080p that already fits the
  upload limit (yt-dlp's default picks AV1/Opus WebM for YouTube, which Telegram does
  not play inline), and falls back to the best available streams, which
  `Angler.Media.prepare/3` re-encodes.

  yt-dlp reports its progress and results through `--print`/`--progress-template`
  lines (parsed by `Angler.Media.Ytdlp.Progress`):

      [meta] {"is_live": false, "duration": 19}
      [progress] downloading 1024 433081 703516.3 0
      [postprocess] started Merger
      [result] "/data/media/<id>/source.mp4"

  Multi-entry posts (carousels, multi-video tweets) download the first entry that has
  video (`--max-downloads 1`, which makes yt-dlp exit with status 101).

  Limits: `--match-filters` and `--max-filesize` refuse videos whose duration or size
  yt-dlp knows before downloading. The source size is also enforced while the
  download runs (`Angler.Media.Ytdlp.Progress.size_guard/2`) and on the finished
  file, and `Angler.Media.download/3` checks the measured duration of the file.

  Every run goes through `Angler.Media.Ytdlp.Runner`: unless private networks are
  allowed, yt-dlp reaches the network only through an `Angler.Media.EgressProxy`,
  which refuses private addresses and connects directly (an outbound proxy
  configured through `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY`, which yt-dlp would
  otherwise use, is then not used), and it gets a private copy of the cookies file.

  Failures are classified into the error kinds of `Angler.Entries.Entry` by
  `Angler.Media.Ytdlp.Outcome`.
  """
  alias Angler.Media
  alias Angler.Media.{Command, Download, Error}
  alias Angler.Media.Ytdlp.{Metadata, Outcome, Progress, Runner}

  @default_timeout :timer.minutes(30)
  @format_sort "vcodec:h264,hdr:sdr,res:1080,fps:30,acodec:aac,ext:mp4:m4a,proto:https"
  @progress_template "download:[progress] %(progress.status)s %(progress.downloaded_bytes)s " <>
                       "%(progress.total_bytes,progress.total_bytes_estimate|NA)s " <>
                       "%(progress.speed|NA)s %(progress.eta|NA)s"
  @postprocess_template "postprocess:[postprocess] %(progress.status)s %(progress.postprocessor)s"
  @info_template "after_move:%(.{id,title,extractor_key,webpage_url,duration,width,height,vcodec,acodec})j"

  @doc """
  Downloads `url` into `dir`, see `c:Angler.Media.download/3`.

  Extra option: `:timeout` in milliseconds (default 30 minutes).
  """
  @spec download(String.t(), Path.t(), keyword()) :: {:ok, Download.t()} | {:error, Error.t()}
  def download(url, dir, opts) do
    dir = Path.expand(dir)

    build_args = fn run ->
      args(url, dir, opts |> Keyword.merge(run) |> Keyword.put(:ffmpeg, configured_ffmpeg()))
    end

    command_opts = [
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      on_line: Progress.handler(opts[:on_progress]),
      on_tick: Progress.size_guard(dir, opts[:max_source_bytes])
    ]

    case Runner.run(dir, build_args, command_opts) do
      {:ok, result, blocked} ->
        with {:error, error} <- outcome(result, dir, opts),
             do: {:error, Runner.blocked(error, blocked)}

      {:error, error} ->
        {:error, error}
    end
  catch
    :throw, {:source_too_large, _bytes} ->
      {:error, Error.new(:too_large, Outcome.too_big_message(opts[:max_source_bytes]))}
  end

  @doc """
  Reads the metadata of every item of the post at `url` without downloading
  anything, see `Angler.Media.Ytdlp.Metadata.run/3`.
  """
  @spec metadata(String.t(), Path.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  defdelegate metadata(url, dir, opts \\ []), to: Metadata, as: :run

  defp outcome(result, dir, opts) do
    case result do
      {:ok, %{exit_status: status, output: lines}} ->
        with {:ok, path} <- Outcome.interpret(status, lines, opts),
             do: build_download(path, dir, opts)

      {:error, :timeout, lines} ->
        timeout = Keyword.get(opts, :timeout, @default_timeout)
        message = "Download took longer than #{Media.format_duration(timeout)}"
        {:error, Error.new(:timeout, message, Outcome.error_output(lines))}

      {:error, :enoent} ->
        {:error, Error.new(:internal, "yt-dlp not found")}

      {:error, reason} ->
        {:error, Error.new(:internal, "Could not start yt-dlp: #{inspect(reason)}")}

      {:error, reason, lines} ->
        message = "yt-dlp failed: #{inspect(reason)}"
        {:error, Error.new(:internal, message, Outcome.error_output(lines))}
    end
  end

  @doc """
  The yt-dlp executable to run: the self-updating copy managed by
  `Angler.Media.Updater` when auto-update is enabled and the copy is usable (see
  `managed_copy_usable?/0`), otherwise the configured `:ytdlp_path`.
  """
  @spec executable() :: String.t()
  def executable do
    if Media.config(:ytdlp_update_channel) && managed_copy_usable?(),
      do: managed_path(),
      else: Media.config(:ytdlp_path, "yt-dlp")
  end

  @doc "Location of the self-updating yt-dlp copy: `<data_dir>/bin/yt-dlp`."
  @spec managed_path() :: Path.t()
  def managed_path, do: Path.join([Media.config(:data_dir), "bin", "yt-dlp"])

  @doc """
  Whether the managed copy is a regular file its owner may execute. An interrupted
  self-update can leave it missing or without the executable bit.
  """
  @spec managed_copy_usable?() :: boolean()
  def managed_copy_usable? do
    case File.stat(managed_path()) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o100) != 0
      _other -> false
    end
  end

  # yt-dlp merges formats with ffmpeg, which it only looks for in PATH by itself.
  defp configured_ffmpeg do
    case Command.find_executable(Media.config(:ffmpeg_path, "ffmpeg")) do
      {:ok, path} -> path
      {:error, :enoent} -> nil
    end
  end

  @doc """
  Command line arguments for downloading `url` into `dir`.

  Options: `:target_bytes`, `:max_source_bytes`, `:max_duration` (seconds), `:cookies`
  (path of the per-run cookies copy), `:cache_dir`, `:ffmpeg` (path of the ffmpeg
  binary used for merging) and `:proxy` (URL of the `Angler.Media.EgressProxy`). The
  URL always comes last, after `--`, so it can never be taken for an option.
  """
  @spec args(String.t(), Path.t(), keyword()) :: [String.t()]
  def args(url, dir, opts) do
    info_file = dir |> Path.join("info.jsonl") |> String.replace("%", "%%")

    List.flatten([
      ~w(--ignore-config --no-quiet --no-playlist --max-downloads 1 --ignore-no-formats-error),
      ~w(--color never --newline --progress --progress-delta 1),
      ["--progress-template", @progress_template, "--progress-template", @postprocess_template],
      ["-P", "home:" <> dir, "-P", "temp:" <> Path.join(dir, "tmp"), "-o", "source.%(ext)s"],
      ~w(--socket-timeout 30 --retries 5 --fragment-retries 10 --extractor-retries 3 -N 4),
      ["--match-filters", match_filter(opts[:max_duration])],
      option("--max-filesize", opts[:max_source_bytes]),
      ["-S", @format_sort, "-f", format_selector(opts[:target_bytes])],
      ["--merge-output-format", "mp4/mkv"],
      ["--print", "pre_process:[meta] %(.{is_live,duration})j"],
      ["--print", "after_move:[result] %(filepath)j"],
      ["--print-to-file", @info_template, info_file],
      option("--cache-dir", opts[:cache_dir] && Path.join(opts[:cache_dir], "yt-dlp")),
      option("--cookies", opts[:cookies]),
      option("--ffmpeg-location", opts[:ffmpeg]),
      option("--proxy", opts[:proxy]),
      ["--", url]
    ])
  end

  defp option(_flag, nil), do: []
  defp option(flag, value), do: [flag, to_string(value)]

  defp match_filter(nil), do: "!is_live"
  defp match_filter(max_duration), do: "!is_live & duration<?#{max_duration}"

  @doc """
  The `-f` format selector: video+audio whose known size leaves room within
  `target_bytes` (88% for the video part, 95% for pre-merged formats), falling back
  to the best available streams. Sizes are plain byte counts (`M` would mean 10^6
  in yt-dlp filters).
  """
  @spec format_selector(pos_integer() | nil) :: String.t()
  def format_selector(nil), do: "bv*+ba/b"

  def format_selector(target_bytes) do
    video = floor(target_bytes * 0.88)
    single = floor(target_bytes * 0.95)

    Enum.join(
      [
        "bv*[filesize<#{video}]+ba",
        "bv*[filesize_approx<#{video}]+ba",
        "b[filesize<#{single}]",
        "b[filesize_approx<#{single}]",
        "bv*+ba",
        "b"
      ],
      "/"
    )
  end

  defp build_download(path, dir, opts) do
    path = Path.expand(path, dir)
    info = read_info(Path.join(dir, "info.jsonl"))
    limit = opts[:max_source_bytes]

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
        cond do
          info["vcodec"] == "none" ->
            {:error, Error.new(:unsupported, "This post has no video")}

          # Sources without a Content-Length pass --max-filesize.
          is_integer(limit) and size > limit ->
            {:error, Error.new(:too_large, Outcome.too_big_message(limit))}

          true ->
            {:ok,
             %Download{
               path: path,
               size: size,
               title: info["title"],
               extractor: info["extractor_key"],
               webpage_url: info["webpage_url"],
               duration: if(is_number(info["duration"]), do: info["duration"] / 1),
               width: info["width"],
               height: info["height"],
               video_codec: info["vcodec"],
               audio_codec: if(info["acodec"] != "none", do: info["acodec"])
             }}
        end

      _other ->
        {:error, Error.new(:internal, "yt-dlp reported a missing or empty file: #{path}")}
    end
  end

  # Metadata of the downloaded entry: the last line yt-dlp appended to info.jsonl.
  defp read_info(path) do
    with {:ok, contents} <- File.read(path),
         line when is_binary(line) <- contents |> String.split("\n", trim: true) |> List.last(),
         {:ok, %{} = info} <- Jason.decode(line) do
      File.rm(path)
      info
    else
      _other -> %{}
    end
  end
end
