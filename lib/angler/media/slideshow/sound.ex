defmodule Angler.Media.Slideshow.Sound do
  @moduledoc """
  Downloads the sound of a TikTok photo post (`music.playUrl`) for
  `Angler.Media.Slideshow`.

  Content types are unreliable (an MP3 was served as `video/mp4`), so the file is
  named after the container ffprobe finds (`audio.mp3`, `audio.m4a`, else `audio`),
  and its duration comes from there too, with TikTok's number as the fallback.

  A sound larger than 50 MB is left out: the slideshow is silent. So is a sound the
  CDN refuses or that ffprobe can't read, but only on the final attempt: before
  that the download fails with `:transient`, so the pipeline tries again with
  freshly signed URLs instead of delivering (and caching) a silent video. Network
  trouble always fails with `:transient`.
  """
  require Logger

  alias Angler.Media.{Error, Fetch, Probe}
  alias Angler.Media.TikTok.Post

  @max_bytes 50_000_000

  @typedoc "The downloaded sound; `path` and `duration` are nil for a silent slideshow."
  @type t :: %{path: Path.t() | nil, bytes: non_neg_integer(), duration: float() | nil}

  @doc """
  Downloads the sound of `post` into the `slides` directory.

  Options: `:budget` (what is left of the slideshow's source limit in bytes, nil
  for none: a larger sound fails with `:too_large`), `:final_attempt` (default
  true, see the module documentation) and `:on_progress` (`"Downloading sound"`).
  """
  @spec download(Post.t(), Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def download(%Post{audio_url: nil}, _slides, _opts), do: {:ok, none()}

  def download(%Post{} = post, slides, opts) do
    report = Keyword.get(opts, :on_progress) || fn _progress -> :ok end
    budget = Keyword.get(opts, :budget)
    final? = Keyword.get(opts, :final_attempt, true)

    report.(%{percent: nil, detail: "Downloading sound"})
    part = Path.join(slides, "audio.part")
    limit = if budget, do: max(min(budget, @max_bytes), 0), else: @max_bytes

    case Fetch.to_file(post.audio_url, part, max_bytes: limit) do
      {:ok, bytes} ->
        identify(part, bytes, post, final?)

      {:error, :too_large} when limit < @max_bytes ->
        File.rm(part)
        {:error, Fetch.over_budget(budget)}

      {:error, {:write, _posix} = reason} ->
        {:error, Fetch.write_error(reason)}

      {:error, reason} ->
        File.rm(part)

        with {:skip, reasons} <-
               Fetch.failure([reason], "Could not download the slideshow sound", final?) do
          Logger.warning("Making a silent slideshow, the TikTok sound failed: #{reasons}")
          {:ok, none()}
        end
    end
  end

  defp identify(part, bytes, post, final?) do
    case Probe.run(part) do
      {:ok, %Probe{has_audio?: true} = probe} ->
        path = Path.join(Path.dirname(part), "audio" <> extension(probe.format_name))

        case File.rename(part, path) do
          :ok ->
            {:ok, %{path: path, bytes: bytes, duration: probe.duration || post.audio_duration}}

          {:error, posix} ->
            {:error, Fetch.write_error({:write, posix})}
        end

      {:ok, _probe} ->
        unusable(part, "it has no audio stream", final?)

      {:error, %Error{kind: :unsupported}} ->
        unusable(part, "it is not a media file", final?)

      {:error, error} ->
        {:error, error}
    end
  end

  defp unusable(part, reason, final?) do
    File.rm(part)

    if final? do
      Logger.warning("Making a silent slideshow, the TikTok sound is unusable: #{reason}")
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
