defmodule Angler.Media.Route do
  @moduledoc """
  Decides how `Angler.Media.download/3` gets a link, and gets it:

    1. Instagram post links are read first (`Angler.Media.Instagram.route/3`): a
       post with a video among several items is an album (`Angler.Media.Album`); a
       photo post is a slideshow when its music can be read
       (`Angler.Media.Slideshow.Instagram`), else an album; a single video goes to
       yt-dlp with the post text as its title
    2. TikTok links are resolved (`Angler.Media.TikTok.route/1`): photo posts are
       slideshows (`Angler.Media.Slideshow`), videos go to yt-dlp with their
       canonical URL
    3. everything else goes to yt-dlp as it is (`Angler.Media.Ytdlp`)

  yt-dlp refuses videos longer than `:max_duration` only when the site reports the
  duration (logged-out Instagram, direct links and HLS playlists often do not), and
  what it reports can be wrong (for HLS it adds up the durations the playlist
  claims). So when there is a limit, a file yt-dlp downloaded is measured with
  ffprobe, checked, and its measured duration returned.
  """
  alias Angler.Media.{Album, Download, Error, Instagram, Probe, Slideshow, TikTok, Ytdlp}
  alias Angler.Media.Ytdlp.Outcome

  @duration_tolerance 1

  @doc "Downloads `url` into `dir`, see `c:Angler.Media.download/3`."
  @spec download(String.t(), Path.t(), keyword()) :: {:ok, Download.t()} | {:error, Error.t()}
  def download(url, dir, opts) do
    case Instagram.route(url, dir, opts) do
      :not_instagram ->
        tiktok(url, dir, opts)

      {:album, post} ->
        Album.download(post, dir, opts)

      {:slideshow, post, music} ->
        Slideshow.download_instagram(post, music, dir, opts)

      {:ytdlp, url, meta} ->
        with {:ok, download} <- ytdlp(url, dir, opts), do: {:ok, retitle(download, meta)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Measures a downloaded video with ffprobe and returns it with the measured
  duration, or `:too_large` when it is longer than `max_duration` seconds (plus
  one second of tolerance). A file ffprobe can't read keeps the duration the site
  reported; `Angler.Media.prepare/3` reports it. Nothing is checked without a limit.
  """
  @spec check_duration(Download.t(), number() | nil) :: {:ok, Download.t()} | {:error, Error.t()}
  def check_duration(download, max_duration) when not is_number(max_duration),
    do: {:ok, download}

  def check_duration(download, max_duration) do
    download =
      case Probe.run(download.path) do
        {:ok, %Probe{duration: duration}} when is_number(duration) ->
          %{download | duration: duration}

        # The reported duration is kept; prepare/3 reports files ffprobe cannot read.
        _other ->
          download
      end

    if is_number(download.duration) and download.duration > max_duration + @duration_tolerance,
      do: {:error, Error.new(:too_large, Outcome.too_long_message(max_duration))},
      else: {:ok, download}
  end

  defp tiktok(url, dir, opts) do
    case TikTok.route(url) do
      {:ytdlp, url} -> ytdlp(url, dir, opts)
      {:slideshow, post} -> Slideshow.download(post, dir, opts)
      {:error, error} -> {:error, error}
    end
  end

  defp ytdlp(url, dir, opts) do
    with {:ok, download} <- Ytdlp.download(url, dir, opts) do
      check_duration(download, Keyword.get(opts, :max_duration))
    end
  end

  # The post text of an Instagram video replaces yt-dlp's "Video by <user>".
  defp retitle(download, %{title: title}) when is_binary(title) do
    if String.trim(title) == "", do: download, else: %{download | title: title}
  end

  defp retitle(download, _meta), do: download
end
