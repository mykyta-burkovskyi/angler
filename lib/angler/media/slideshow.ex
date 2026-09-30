defmodule Angler.Media.Slideshow do
  @moduledoc """
  Photo posts with a sound as videos: TikTok photo posts (`download/3`, an image
  carousel with a sound) and Instagram photo posts with music
  (`download_instagram/4`, see `Angler.Media.Slideshow.Instagram`). Both give a
  `%Angler.Media.Download{kind: :slideshow}`, which `prepare/3` assembles into an
  MP4 (`Angler.Media.Slideshow.Render`).

  `download/3` fetches the images, in display order, and the sound
  (`Angler.Media.Slideshow.Sound`, played as it is) of a TikTok post found by
  `Angler.Media.TikTok` into `<dir>/slides/` (`01.jpg`, `02.jpg`, ...,
  `audio.mp3`/`audio.m4a`).

  Image and sound URLs expire after a day or two, so both steps run within the
  same attempt. At most 35 images are used. Images larger than 30 MB are skipped.
  Network trouble fails the download with `:transient`, so the pipeline tries
  again later (loading the post again, with freshly signed URLs). So does a CDN
  refusing an image or the sound, or a sound ffprobe can't read, unless this is
  the final attempt: then the image is skipped, or the slideshow is silent (an
  Instagram post goes out as an album instead). A degraded video is re-sent for
  later requests of the same link, so it is only made when no retry follows.
  """
  require Logger

  alias Angler.Media
  alias Angler.Media.{Download, Error, Fetch, Instagram}
  alias Angler.Media.Slideshow.{Render, Sound}
  alias Angler.Media.TikTok.Post

  @max_images 35
  @max_image_bytes 30_000_000
  @concurrency 4

  @doc """
  Downloads the images and sound of `post` into `<dir>/slides`.

  Options:
    * `:max_source_bytes` - images and sound together; `:too_large` beyond it
    * `:max_duration` - seconds; the video is assembled at most this long (and
      never longer than 90 s)
    * `:final_attempt` - false when the pipeline tries again after a transient
      failure (default true, see the module documentation)
    * `:on_progress` - `"Downloading images 3/12"`, `"Downloading sound"`

  The other options of `c:Angler.Media.download/3` do not apply.
  """
  @spec download(Post.t(), Path.t(), keyword()) :: {:ok, Download.t()} | {:error, Error.t()}
  def download(%Post{} = post, dir, opts) do
    slides = Path.join(Path.expand(dir), "slides")
    report = Keyword.get(opts, :on_progress) || fn _progress -> :ok end
    budget = Keyword.get(opts, :max_source_bytes)
    final? = Keyword.get(opts, :final_attempt, true)

    with :ok <- make_dir(slides),
         {:ok, images, image_bytes} <- download_images(post, slides, budget, final?, report),
         {:ok, audio} <-
           Sound.download(
             %{url: post.audio_url, duration: post.audio_duration, window: nil},
             slides,
             budget: budget && budget - image_bytes,
             final_attempt: final?,
             on_progress: report
           ) do
      {:ok,
       %Download{
         kind: :slideshow,
         path: slides,
         size: image_bytes + audio.bytes,
         images: images,
         audio_path: audio.path,
         duration: audio.duration,
         max_duration: Keyword.get(opts, :max_duration),
         title: post.title,
         extractor: "TikTok",
         webpage_url: post.webpage_url
       }}
    end
  end

  @doc """
  Downloads the photos of an Instagram photo post and the post's clip of its
  song, see `Angler.Media.Slideshow.Instagram`.
  """
  @spec download_instagram(Instagram.Post.t(), Instagram.Music.t(), Path.t(), keyword()) ::
          {:ok, Download.t()} | {:error, Error.t()}
  defdelegate download_instagram(post, music, dir, opts),
    to: Angler.Media.Slideshow.Instagram,
    as: :download

  @doc "Assembles a downloaded slideshow into the final video, see `Angler.Media.Slideshow.Render`."
  @spec prepare(Download.t(), Path.t(), keyword()) ::
          {:ok, Media.Output.t()} | {:error, Error.t()}
  defdelegate prepare(download, dir, opts), to: Render, as: :run

  defp make_dir(slides) do
    case File.mkdir_p(slides) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(:internal, "Could not create #{slides}: #{:file.format_error(reason)}")}
    end
  end

  ## Images

  defp download_images(%Post{images: []}, _slides, _budget, _final?, _report),
    do: {:error, Error.new(:unsupported, "This TikTok slideshow has no images")}

  defp download_images(post, slides, budget, final?, report) do
    images = Enum.take(post.images, @max_images)
    total = length(images)

    images
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {image, index} -> {index, fetch_image(image, index, slides, final?)} end,
      max_concurrency: @concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({[], 0, 0}, fn {:ok, {index, result}}, {paths, bytes, done} ->
      report.(%{
        percent: (done + 1) / total * 100,
        detail: "Downloading images #{done + 1}/#{total}"
      })

      case result do
        {:ok, path, size} when is_integer(budget) and bytes + size > budget ->
          File.rm(path)
          {:halt, {:error, Fetch.over_budget(budget)}}

        {:ok, path, size} ->
          {:cont, {[path | paths], bytes + size, done + 1}}

        {:skip, reason} ->
          Logger.warning("Skipping TikTok slideshow image #{index}: #{reason}")
          {:cont, {paths, bytes, done + 1}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} ->
        {:error, error}

      {[], _bytes, _done} ->
        {:error, Error.new(:unavailable, "Could not download the slideshow images")}

      {paths, bytes, _done} ->
        {:ok, Enum.reverse(paths), bytes}
    end
  end

  # The URLs hold the same image on different CDN hosts: try them in order.
  defp fetch_image(image, index, slides, final?) do
    path = Path.join(slides, String.pad_leading(Integer.to_string(index), 2, "0") <> ".jpg")

    image.urls
    |> Enum.reduce_while([], fn url, failures ->
      case Fetch.to_file(url, path, max_bytes: @max_image_bytes) do
        {:ok, size} -> {:halt, {:ok, path, size}}
        {:error, {:write, _posix} = reason} -> {:halt, {:error, Fetch.write_error(reason)}}
        {:error, reason} -> {:cont, [reason | failures]}
      end
    end)
    |> case do
      failures when is_list(failures) ->
        File.rm(path)
        Fetch.failure(failures, "Could not download slideshow image #{index}", final?)

      result ->
        result
    end
  end
end
