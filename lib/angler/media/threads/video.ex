defmodule Angler.Media.Threads.Video do
  @moduledoc """
  Downloads the video of a Threads post with a single video, which yt-dlp can't
  read (it has no Threads extractor): the post's own file, straight from Instagram's
  CDN (`Angler.Media.Instagram.Cdn`: no cookies, no redirects), into
  `<dir>/source.mp4`, the name yt-dlp downloads to. `Angler.Media.Prepare` then
  makes it Telegram-ready like any download.

  Threads lists one progressive MP4 (H.264 and AAC) per video, its duration only in
  the post's DASH manifest. A video longer than `:max_duration` is refused before
  downloading when that duration is known (`Angler.Media.Route` measures the file
  afterwards either way), and one larger than `:max_source_bytes` once it exceeds
  it. The URLs are signed and expire, so a CDN refusing the file fails with
  `:transient` (the next attempt loads the post again), unless this is the final
  attempt: then with `:unavailable` (see `Angler.Media.Fetch.failure/3`).
  """
  alias Angler.Media.{Download, Error, Fetch}
  alias Angler.Media.Instagram.{Cdn, Post}
  alias Angler.Media.Ytdlp.Outcome

  @default_limit 1_000_000_000
  @timeout :timer.minutes(10)
  @duration_tolerance 1
  @message "Could not download the Threads video"

  @doc """
  Downloads the video of `post` (a single video item) into `dir`.

  Options: `:max_source_bytes` (default 1 GB), `:max_duration` (seconds),
  `:final_attempt` (default true) and `:on_progress`.
  """
  @spec download(Post.t(), Path.t(), keyword()) :: {:ok, Download.t()} | {:error, Error.t()}
  def download(%Post{items: [%{type: :video} = item]} = post, dir, opts) do
    path = Path.join(Path.expand(dir), "source.mp4")
    limit = Keyword.get(opts, :max_source_bytes) || @default_limit

    with :ok <- check_duration(item.duration, Keyword.get(opts, :max_duration)) do
      report(opts, %{percent: nil, detail: "Downloading"})

      case fetch(item.urls, path, limit, Keyword.get(opts, :final_attempt, true)) do
        {:ok, size} ->
          {:ok,
           %Download{
             kind: :video,
             path: path,
             size: size,
             duration: item.duration,
             title: Post.title(post),
             extractor: post.site,
             webpage_url: post.webpage_url
           }}

        {:error, error} ->
          File.rm(path)
          {:error, error}
      end
    end
  end

  defp check_duration(duration, max_duration)
       when is_number(duration) and is_number(max_duration) and
              duration > max_duration + @duration_tolerance,
       do: {:error, Error.new(:too_large, Outcome.too_long_message(max_duration))}

  defp check_duration(_duration, _max_duration), do: :ok

  defp fetch(urls, path, limit, final?) do
    urls
    |> Enum.reduce_while([], fn url, failures ->
      case Cdn.fetch(url, path, max_bytes: limit, timeout: @timeout) do
        {:ok, size} -> {:halt, {:ok, size}}
        {:error, :too_large} -> {:halt, {:error, too_large(limit)}}
        {:error, {:write, _posix} = reason} -> {:halt, {:error, Fetch.write_error(reason)}}
        {:error, reason} -> {:cont, [reason | failures]}
      end
    end)
    |> case do
      failures when is_list(failures) ->
        case Fetch.failure(failures, @message, final?) do
          {:error, error} -> {:error, error}
          {:skip, described} -> {:error, Error.new(:unavailable, "#{@message} (#{described})")}
        end

      result ->
        result
    end
  end

  defp too_large(limit), do: Error.new(:too_large, Outcome.too_big_message(limit))

  defp report(opts, progress) do
    if on_progress = Keyword.get(opts, :on_progress), do: on_progress.(progress)
    :ok
  end
end
