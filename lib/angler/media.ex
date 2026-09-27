defmodule Angler.Media do
  @moduledoc """
  Turns a link into a Telegram-ready video file using yt-dlp, ffprobe and ffmpeg.

  The pipeline calls the implementation configured as
  `config :angler, Angler.Pipeline, media: module` (defaults to this module), so tests
  can swap in a fake that implements this behaviour.

  Configuration (`config :angler, Angler.Media`):

    * `:data_dir` - persistent data directory; yt-dlp and deno cache under `cache/`,
      the self-updating yt-dlp copy lives in `bin/`
    * `:ytdlp_path`, `:ffmpeg_path`, `:ffprobe_path` - executables (paths or names in `PATH`)
    * `:cookies_file` - optional Netscape cookies file passed to yt-dlp
    * `:ytdlp_update_channel` - `nil`, `"stable"` or `"nightly"`, see `Angler.Media.Updater`
    * `:allow_private_networks` - let downloads reach loopback and private network
      addresses (default `false`), see `Angler.Media.EgressProxy`

  Every external program runs through `Angler.Media.Command`, which kills it when it
  takes too long or when the calling process dies.

  This module is the behaviour and its entry point; the work is done by
  `Angler.Media.Ytdlp` and `Angler.Media.Slideshow` (downloads),
  `Angler.Media.Prepare` (making videos Telegram-ready) and `Angler.Media.Tools`
  (tool versions). It also holds helpers shared by the `Angler.Media.*` modules.
  """
  alias Angler.Media.{Download, Error, Output, Prepare, Probe, Tools, Updater, Ytdlp}
  alias Angler.Media.{Slideshow, TikTok}
  alias Angler.Media.Ytdlp.Outcome

  @typedoc """
  Called with progress updates, e.g. `%{percent: 42.5, detail: "3.1MiB/s, ETA 00:12"}`.
  Implementations call it at most about once per second.
  """
  @type progress_fun :: (%{percent: float() | nil, detail: String.t() | nil} -> any())

  @doc """
  Downloads the video behind `url` into directory `dir` (which exists and is empty).

  Options:
    * `:max_source_bytes` - refuse sources larger than this (`kind: :too_large`),
      before downloading when the size is known, otherwise once it is exceeded
    * `:max_duration` - refuse videos longer than this many seconds (`kind: :too_large`),
      before downloading when the site reports the duration, and once more after
      downloading by measuring the file
    * `:target_bytes` - the upload limit; prefer formats that already fit it
    * `:final_attempt` - false when a `:transient` failure will be retried (default
      true); slideshows then fail rather than leave out files the CDN refused
    * `:on_progress` - `t:progress_fun/0`
  """
  @callback download(url :: String.t(), dir :: Path.t(), opts :: keyword()) ::
              {:ok, Download.t()} | {:error, Error.t()}

  @doc """
  Produces an MP4 that Telegram plays inline and that is at most `:target_bytes`
  large, re-encoding with ffmpeg only when needed, plus a thumbnail. Writes into `dir`,
  using the file names from `Angler.Storage.output_paths/1` for the final video and
  thumbnail (the source file may be moved there when it already fits).

  Options:
    * `:target_bytes` (required)
    * `:on_progress` - `t:progress_fun/0`
  """
  @callback prepare(Download.t(), dir :: Path.t(), opts :: keyword()) ::
              {:ok, Output.t()} | {:error, Error.t()}

  @behaviour __MODULE__

  @duration_tolerance 1

  @doc """
  Downloads with yt-dlp, see `c:download/3` and `Angler.Media.Ytdlp.download/3`.
  TikTok links are resolved first (`Angler.Media.TikTok.route/1`): photo posts are
  downloaded as slideshows (`Angler.Media.Slideshow.download/3`), other TikTok
  videos go to yt-dlp with their canonical URL.

  yt-dlp refuses videos longer than `:max_duration` only when the site reports the
  duration (logged-out Instagram, direct links and HLS playlists often do not), and
  what it reports can be wrong (for HLS it adds up the durations the playlist
  claims). So when there is a limit, the downloaded file is measured with ffprobe,
  checked, and its measured duration returned.

  Also accepts `:timeout` (milliseconds, default 30 minutes).
  """
  @impl true
  def download(url, dir, opts) do
    case TikTok.route(url) do
      {:ytdlp, url} ->
        with {:ok, download} <- Ytdlp.download(url, dir, opts) do
          check_duration(download, Keyword.get(opts, :max_duration))
        end

      {:slideshow, post} ->
        Slideshow.download(post, dir, opts)

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_duration(download, max_duration) when not is_number(max_duration),
    do: {:ok, download}

  defp check_duration(download, max_duration) do
    download =
      case Probe.run(download.path) do
        {:ok, %Probe{duration: duration}} when is_number(duration) ->
          %{download | duration: duration}

        # yt-dlp's duration is kept; prepare/3 reports files ffprobe cannot read.
        _other ->
          download
      end

    if is_number(download.duration) and download.duration > max_duration + @duration_tolerance,
      do: {:error, Error.new(:too_large, Outcome.too_long_message(max_duration))},
      else: {:ok, download}
  end

  @doc """
  Probes the download, picks the cheapest way to make it Telegram-ready
  (`Angler.Media.Plan`), runs ffmpeg when needed, and creates the thumbnail
  (`Angler.Media.Prepare`).

  When the container does not tell the duration (e.g. WebM written live), the one
  yt-dlp reported is used.

  On success the source file and the encoder's pass logs are removed; on failure
  intermediates stay in `dir` (the storage subsystem cleans the directory).
  Slideshows are assembled by `Angler.Media.Slideshow.prepare/3`.
  """
  @impl true
  def prepare(%Download{kind: :slideshow} = download, dir, opts),
    do: Slideshow.prepare(download, dir, opts)

  def prepare(%Download{} = download, dir, opts), do: Prepare.run(download, dir, opts)

  @doc """
  Versions of the external tools for the dashboard, e.g.
  `%{"yt-dlp" => "2026.09.20", "ffmpeg" => "7.1.2", "deno" => "2.5.0"}` (nil when missing).

  Results are cached for 10 minutes. Never raises.
  """
  @spec tool_versions() :: %{String.t() => String.t() | nil}
  defdelegate tool_versions, to: Tools, as: :versions

  @doc "Drops the cached `tool_versions/0` result, e.g. after yt-dlp updated itself."
  @spec forget_tool_versions() :: :ok
  defdelegate forget_tool_versions, to: Tools, as: :forget_versions

  @doc """
  Extracts the version from the first line a tool prints for its version flag:
  `"2026.08.19"` (yt-dlp), `"ffmpeg version 9.0.2-static ..."`, `"deno 2.9.7 (stable, ...)"`.
  """
  @spec parse_version(String.t(), String.t()) :: String.t() | nil
  defdelegate parse_version(tool, line), to: Tools

  @doc """
  Updates the managed yt-dlp copy now (dashboard button). Returns the new version,
  or `{:error, reason}` (e.g. `"auto-update is disabled (set YTDLP_UPDATE_CHANNEL)"`).
  See `Angler.Media.Updater`.
  """
  @spec update_ytdlp() :: {:ok, String.t()} | {:error, String.t()}
  def update_ytdlp, do: Updater.update_now()

  ## Helpers shared by the Angler.Media.* modules

  @doc "Reads a key of `config :angler, Angler.Media`."
  @spec config(atom(), term()) :: term()
  def config(key, default \\ nil) do
    :angler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
    |> Kernel.||(default)
  end

  @doc "Writable cache directory for yt-dlp and deno (also their `HOME`)."
  @spec cache_dir() :: Path.t()
  def cache_dir, do: Path.join(config(:data_dir), "cache")

  @doc """
  Environment for yt-dlp: the container user has no home directory, so `HOME` and
  `XDG_CACHE_HOME` point to the writable cache directory.
  """
  @spec tool_env() :: [{String.t(), String.t()}]
  def tool_env, do: [{"HOME", cache_dir()}, {"XDG_CACHE_HOME", cache_dir()}]

  @doc """
  Wraps a `t:progress_fun/0` so it runs at most once per `interval_ms` in the process
  that calls it (tools report progress from their runner process).
  """
  @spec throttle(progress_fun(), non_neg_integer()) :: progress_fun()
  def throttle(fun, interval_ms \\ 1_000) do
    key = {__MODULE__, :throttle, make_ref()}

    fn progress ->
      now = System.monotonic_time(:millisecond)
      last = Process.get(key)

      if is_nil(last) or now - last >= interval_ms do
        Process.put(key, now)
        fun.(progress)
      end
    end
  end

  @doc """
  Formats a time limit in milliseconds for messages: whole minutes as minutes
  (`"30 minutes"`), anything else in seconds (`"90 seconds"`).
  """
  @spec format_duration(non_neg_integer()) :: String.t()
  def format_duration(60_000), do: "1 minute"
  def format_duration(ms) when ms > 0 and rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)} minutes"
  def format_duration(1_000), do: "1 second"
  def format_duration(ms), do: "#{div(ms, 1_000)} seconds"

  @doc ~S'Formats bytes as decimal megabytes for messages, e.g. `"50 MB"`, `"0.4 MB"`.'
  @spec format_mb(non_neg_integer()) :: String.t()
  def format_mb(bytes) when rem(bytes, 1_000_000) == 0, do: "#{div(bytes, 1_000_000)} MB"
  def format_mb(bytes), do: "#{:erlang.float_to_binary(bytes / 1_000_000, decimals: 1)} MB"
end
