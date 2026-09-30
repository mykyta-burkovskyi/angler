defmodule Angler.Media.Album do
  @moduledoc """
  The photos and videos of an Instagram post (`Angler.Media.Instagram.Post`), sent
  as they are: an album.

  `download/3` fetches every item, in display order, into its own directory
  `<dir>/album/NN/` (`source.jpg` or `source.mp4`) and returns a
  `%Angler.Media.Download{kind: :album}`; `prepare/3` checks the photos and makes
  the videos Telegram-ready (`Angler.Media.Album.Prepare`), laying the files out
  as `Angler.Storage.Album` expects them.

  Items come from Instagram's CDN only (`cdn?/1`: https on `*.cdninstagram.com` or
  `*.fbcdn.net`), without cookies and without following redirects. Each item has
  one or more versions (the original, then a smaller one), tried in order. The
  URLs are signed and expire, so a CDN refusing an item fails the download with
  `:transient` (the next attempt loads the post again), unless this is the final
  attempt: then the item is left out (see `Angler.Media.Fetch.failure/3`). So is a
  URL on another host, which is logged by its host only (signed URLs never go to
  the logs).
  """
  require Logger

  alias Angler.Media.{Download, Error, Fetch, Instagram}
  alias Angler.Media.Album.Prepare
  alias Angler.Media.Instagram.Post

  @max_items 20
  @concurrency 4
  @default_budget 1_000_000_000
  @max_photo_bytes 30_000_000
  @max_video_bytes 300_000_000
  @photo_timeout :timer.minutes(2)
  @video_timeout :timer.minutes(10)
  @cdn_domains ["cdninstagram.com", "fbcdn.net"]
  @noun "Instagram post"

  @doc """
  Downloads the items of `post` into `<dir>/album`.

  Options:
    * `:max_source_bytes` - all items together (default 1 GB); `:too_large` beyond
      it. A photo may have at most 30 MB and a video 300 MB, larger ones are left out
    * `:max_duration` - seconds; kept for `prepare/3`, which refuses longer videos
    * `:final_attempt` - false when the pipeline tries again after a transient
      failure (default true, see the module documentation)
    * `:on_progress` - `"Downloading 3/12"`

  The other options of `c:Angler.Media.download/3` do not apply.
  """
  @spec download(Post.t(), Path.t(), keyword()) :: {:ok, Download.t()} | {:error, Error.t()}
  def download(%Post{} = post, dir, opts) do
    album = Path.join(Path.expand(dir), "album")
    limit = Keyword.get(opts, :max_source_bytes) || @default_budget

    job = %{
      album: album,
      budget: Fetch.budget(limit),
      final?: Keyword.get(opts, :final_attempt, true),
      report: Keyword.get(opts, :on_progress) || fn _progress -> :ok end
    }

    with :ok <- make_dir(album),
         {:ok, items} <- download_items(Enum.take(post.items, @max_items), job) do
      {:ok,
       %Download{
         kind: :album,
         path: album,
         size: items |> Enum.map(& &1.size) |> Enum.sum(),
         items: items,
         max_duration: Keyword.get(opts, :max_duration),
         title: Post.title(post),
         extractor: "Instagram",
         webpage_url: post.webpage_url
       }}
    end
  end

  @doc """
  Makes a downloaded album Telegram-ready, see `Angler.Media.Album.Prepare`.
  Option `:target_bytes` (required, the upload limit per file) and `:on_progress`.
  """
  @spec prepare(Download.t(), Path.t(), keyword()) ::
          {:ok, Angler.Media.Output.t()} | {:error, Error.t()}
  defdelegate prepare(download, dir, opts), to: Prepare, as: :run

  @doc """
  Whether `url` may be downloaded: https (port 443) on Instagram's CDN hosts
  (`cdninstagram.com`, `fbcdn.net` and their subdomains), without user info.
  """
  @spec cdn?(term()) :: boolean()
  def cdn?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", userinfo: nil, host: host, port: port}
      when is_binary(host) and port in [nil, 443] ->
        host = String.downcase(host)
        Enum.any?(@cdn_domains, &(host == &1 or String.ends_with?(host, "." <> &1)))

      _other ->
        false
    end
  end

  def cdn?(_url), do: false

  defp make_dir(album) do
    case File.mkdir_p(album) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.new(:internal, "Could not create #{album}: #{:file.format_error(reason)}")}
    end
  end

  defp download_items([], _job),
    do: {:error, Error.new(:unsupported, "This Instagram post has no photos or videos")}

  defp download_items(items, job) do
    total = length(items)

    items
    |> Enum.with_index(1)
    |> Task.async_stream(fn {item, index} -> {index, fetch_item(item, index, job)} end,
      max_concurrency: @concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({[], 0}, fn {:ok, {index, result}}, {downloaded, done} ->
      job.report.(%{
        percent: (done + 1) / total * 100,
        detail: "Downloading #{done + 1}/#{total}"
      })

      case result do
        {:ok, item} ->
          {:cont, {[item | downloaded], done + 1}}

        {:skip, reason} ->
          Logger.warning("Skipping item #{index} of an Instagram post: #{reason}")
          {:cont, {downloaded, done + 1}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      {[], _done} -> {:error, Error.new(:unavailable, "Could not download the Instagram post")}
      {downloaded, _done} -> {:ok, Enum.reverse(downloaded)}
    end
  end

  defp fetch_item(%{urls: []}, _index, _job), do: {:skip, "no URL"}

  defp fetch_item(item, index, job) do
    item_dir = Path.join(job.album, String.pad_leading(Integer.to_string(index), 2, "0"))
    {name, max_bytes, timeout} = limits(item.type, job.budget)
    path = Path.join(item_dir, name)

    with :ok <- make_dir(item_dir) do
      item.urls
      |> Enum.reduce_while([], fn url, failures ->
        case fetch(url, path, max_bytes: max_bytes, timeout: timeout, budget: job.budget) do
          {:ok, size} -> {:halt, {:ok, downloaded(item, path, size)}}
          {:error, :over_budget} -> {:halt, {:error, Fetch.over_budget(limit(job), @noun)}}
          {:error, {:write, _posix} = reason} -> {:halt, {:error, Fetch.write_error(reason)}}
          {:error, reason} -> {:cont, [reason | failures]}
        end
      end)
      |> case do
        failures when is_list(failures) ->
          File.rm(path)
          File.rmdir(item_dir)
          message = "Could not download item #{index} of the Instagram post"
          Fetch.failure(failures, message, job.final?)

        result ->
          result
      end
    end
  end

  defp limits(:photo, _budget), do: {"source.jpg", @max_photo_bytes, @photo_timeout}

  defp limits(:video, {_counter, limit}),
    do: {"source.mp4", min(limit, @max_video_bytes), @video_timeout}

  defp limit(%{budget: {_counter, limit}}), do: limit

  # No cookies and no redirects; Req's own time limit backs up Fetch's deadline.
  defp fetch(url, path, opts) do
    if cdn?(url) do
      timeout = Keyword.fetch!(opts, :timeout)

      request = fn options ->
        options
        |> Keyword.merge(redirect: false, request_timeout: timeout + 5_000)
        |> Instagram.request()
      end

      Fetch.to_file(url, path, Keyword.put(opts, :request, request))
    else
      host = URI.parse(url).host
      Logger.warning("Not downloading Instagram media from #{host || "a URL without a host"}")
      {:error, {:host_not_allowed, host}}
    end
  end

  defp downloaded(item, path, size) do
    %{
      type: item.type,
      path: path,
      size: size,
      width: Map.get(item, :width),
      height: Map.get(item, :height),
      duration: Map.get(item, :duration)
    }
  end
end
