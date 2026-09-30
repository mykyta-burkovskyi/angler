defmodule Angler.Media.Slideshow.Sound do
  @moduledoc """
  Downloads the sound of a slideshow for `Angler.Media.Slideshow`: the sound of a
  TikTok photo post (`music.playUrl`), played as it is, or the song of an Instagram
  photo post with music, of which only the post's clip plays.

  Content types are unreliable (an MP3 was served as `video/mp4`), so the file is
  named after the container ffprobe finds (`audio.mp3`, `audio.m4a`, else `audio`),
  and its duration comes from there too, with the site's number as the fallback.

  A source with a clip `window` is then cut to that clip
  (`Angler.Media.Slideshow.Clip`): `clip.flac` replaces the song, and ffprobe
  measures its duration. A clip that is the whole song keeps the downloaded file.

  A sound larger than 50 MB is left out: the slideshow is silent. So is a sound the
  CDN refuses, that is not media or has no audio, or that can't be cut, but only
  on the final attempt: before that the download fails with `:transient`, so the
  pipeline tries again with freshly signed URLs instead of delivering (and
  caching) a silent video. Network trouble always fails with `:transient`, and
  ffprobe or ffmpeg taking too long with `:timeout`; a missing tool, another
  ffprobe failure or a failed write is `:internal`. Whenever no sound is
  returned, no sound file is left in the directory (except after a failed write).
  """
  require Logger

  alias Angler.Media.{Error, Fetch, Probe}
  alias Angler.Media.Slideshow.Clip

  @max_bytes 50_000_000

  @typedoc """
  Where the sound comes from: its URL (nil: the post has none), the site's
  duration of it in seconds, and the post's clip of it (nil: all of it plays).
  """
  @type source :: %{url: String.t() | nil, duration: float() | nil, window: Clip.window() | nil}

  @typedoc """
  The downloaded sound; `path` and `duration` are nil for a silent slideshow.
  `bytes` counts the downloaded file, also when a clip was cut from it.
  """
  @type t :: %{path: Path.t() | nil, bytes: non_neg_integer(), duration: float() | nil}

  @doc """
  Downloads the sound of `source` into the directory `dir` (and cuts its clip).

  Options:
    * `:fetch` - downloads a URL to a file, like (and by default)
      `Angler.Media.Fetch.to_file/3`, which is called with `max_bytes:` only
    * `:budget` - what is left of the slideshow's source limit in bytes, nil for
      none: a larger sound fails with `:too_large`
    * `:final_attempt` - default true, see the module documentation
    * `:on_progress` - `"Downloading sound"`, `"Preparing sound"`
  """
  @spec download(source(), Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def download(%{url: nil}, _dir, _opts), do: {:ok, none()}

  def download(%{url: url} = source, dir, opts) do
    report = Keyword.get(opts, :on_progress) || fn _progress -> :ok end
    fetch = Keyword.get(opts, :fetch, &Fetch.to_file/3)
    budget = Keyword.get(opts, :budget)
    final? = Keyword.get(opts, :final_attempt, true)

    report.(%{percent: nil, detail: "Downloading sound"})
    part = Path.join(dir, "audio.part")
    limit = if budget, do: max(min(budget, @max_bytes), 0), else: @max_bytes

    case fetch.(url, part, max_bytes: limit) do
      {:ok, bytes} ->
        with {:ok, audio} <- identify(part, bytes, source, final?),
             do: clip(audio, source.window, final?, report)

      {:error, :too_large} when limit < @max_bytes ->
        File.rm(part)
        {:error, Fetch.over_budget(budget)}

      {:error, {:write, _posix} = reason} ->
        {:error, Fetch.write_error(reason)}

      {:error, reason} ->
        File.rm(part)

        with {:skip, reasons} <-
               Fetch.failure([reason], "Could not download the slideshow sound", final?) do
          Logger.warning("Leaving out the slideshow sound: #{reasons}")
          {:ok, none()}
        end
    end
  end

  defp identify(part, bytes, source, final?) do
    case Probe.run(part) do
      {:ok, %Probe{has_audio?: true} = probe} ->
        path = Path.join(Path.dirname(part), "audio" <> extension(probe.format_name))

        case File.rename(part, path) do
          :ok ->
            {:ok, %{path: path, bytes: bytes, duration: probe.duration || source.duration}}

          {:error, posix} ->
            {:error, Fetch.write_error({:write, posix})}
        end

      {:ok, _probe} ->
        unusable(part, "it has no audio stream", final?)

      {:error, %Error{kind: :unsupported}} ->
        unusable(part, "it is not a media file", final?)

      {:error, error} ->
        File.rm(part)
        {:error, error}
    end
  end

  # A sound left out (on the final attempt) has nothing to cut.
  defp clip(%{path: path} = audio, window, _final?, _report)
       when is_nil(path) or is_nil(window),
       do: {:ok, audio}

  defp clip(audio, window, final?, report) do
    case Clip.window(audio.duration, window) do
      :whole -> {:ok, audio}
      cut -> cut(audio, cut, final?, report)
    end
  end

  defp cut(audio, cut, final?, report) do
    report.(%{percent: nil, detail: "Preparing sound"})
    output = Path.join(Path.dirname(audio.path), "clip.flac")

    case Clip.cut(audio.path, cut, output) do
      {:ok, seconds} ->
        File.rm(audio.path)
        {:ok, %{audio | path: output, duration: seconds}}

      {:failed, error} ->
        File.rm(output)
        Logger.warning("Could not cut the slideshow sound: #{error.message}")
        unusable(audio.path, "it could not be cut", final?)

      {:error, error} ->
        File.rm(output)
        File.rm(audio.path)
        {:error, error}
    end
  end

  defp unusable(path, reason, final?) do
    File.rm(path)

    if final? do
      Logger.warning("Leaving out the slideshow sound, it is unusable: #{reason}")
      {:ok, none()}
    else
      {:error, Error.new(:transient, "Could not use the slideshow sound (#{reason})")}
    end
  end

  @doc ~S'The file extension for an ffprobe `format_name`: `".mp3"`, `".m4a"` or `""`.'
  @spec extension(String.t() | nil) :: String.t()
  def extension("mp3" <> _rest), do: ".mp3"

  def extension(format) when is_binary(format),
    do: if(format =~ ~r/mp4|m4a/, do: ".m4a", else: "")

  def extension(_format), do: ""

  defp none, do: %{path: nil, bytes: 0, duration: nil}
end
