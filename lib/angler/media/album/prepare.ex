defmodule Angler.Media.Album.Prepare do
  @moduledoc """
  Makes a downloaded album (`Angler.Media.Album.download/3`) Telegram-ready, one
  item after the other, each in its own directory (see `Angler.Storage.Album`):

    * photos are sent as they are. The format (JPEG, PNG or WebP) and dimensions
      come from the file header (`Angler.Media.Album.Photo`) and the photo is
      renamed to `photo.<jpg|png|webp>`. A photo in another format, or one
      Telegram would refuse (`Angler.Media.Album.Photo.check/3`), is left out
      with a warning: there is no conversion.
    * videos are prepared like any download (`Angler.Media.Prepare`: `video.mp4`
      and `thumbnail.jpg`). A video longer than the download's `:max_duration`
      fails the album with `:too_large`, and so does any other failure of a video.
    * the cover thumbnail (`Angler.Storage.output_paths/1`) shows the first photo
      or video it can be made from (`Angler.Media.Album.Cover`); a missing cover
      never fails the album.

  The source files are gone afterwards (renamed, or removed with the items left out).
  """
  require Logger

  alias Angler.Media
  alias Angler.Media.{Download, Error, Output, Route}
  alias Angler.Media.Album.{Cover, Photo}

  @doc """
  Prepares the items of `download` (`kind: :album`) and returns an
  `%Angler.Media.Output{kind: :album}`.

  Options: `:target_bytes` (required, the upload limit for each file) and
  `:on_progress` (`"Preparing 2/5"`, while a video is being encoded followed by
  what `Angler.Media.Prepare` reports, e.g. `"Preparing 2/5 · Remuxing"`).
  """
  @spec run(Download.t(), Path.t(), keyword()) :: {:ok, Output.t()} | {:error, Error.t()}
  def run(%Download{kind: :album, items: items} = download, dir, opts) do
    job = %{
      target: Keyword.fetch!(opts, :target_bytes),
      max_duration: download.max_duration,
      report: Keyword.get(opts, :on_progress) || fn _progress -> :ok end,
      total: length(items)
    }

    items
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {item, index}, prepared ->
      job.report.(%{
        percent: (index - 1) / job.total * 100,
        detail: "Preparing #{index}/#{job.total}"
      })

      case prepare_item(item, index, job) do
        {:ok, item} ->
          {:cont, [item | prepared]}

        {:skip, reason} ->
          Logger.warning("Leaving out item #{index} of an Instagram post: #{reason}")
          {:cont, prepared}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} ->
        {:error, error}

      [] ->
        {:error, Error.new(:unsupported, "Nothing in this Instagram post can be sent")}

      prepared ->
        {:ok, output(download, Enum.reverse(prepared), dir)}
    end
  end

  defp output(download, [first | _rest] = items, dir) do
    %Output{
      kind: :album,
      path: download.path,
      size: items |> Enum.map(& &1.size) |> Enum.sum(),
      thumbnail_path: Cover.make(items, Angler.Storage.output_paths(dir).thumbnail),
      width: first.width,
      height: first.height,
      duration: nil,
      video_codec: nil,
      transcoded: Enum.any?(items, & &1.transcoded),
      items: items
    }
  end

  ## Photos

  defp prepare_item(%{type: :photo, path: source}, _index, job) do
    with {:ok, size} <- file_size(source),
         {:ok, info} <- identify(source),
         :ok <- Photo.check(info, size, job.target) do
      path = Path.join(Path.dirname(source), "photo." <> Photo.extension(info.format))

      case File.rename(source, path) do
        :ok ->
          {:ok,
           %{
             type: :photo,
             path: path,
             size: size,
             width: info.width,
             height: info.height,
             duration: nil,
             thumbnail_path: nil,
             video_codec: nil,
             transcoded: false
           }}

        {:error, reason} ->
          {:error,
           Error.new(:internal, "Could not rename #{source}: #{:file.format_error(reason)}")}
      end
    else
      {:error, reason} ->
        File.rm(source)
        File.rmdir(Path.dirname(source))
        {:skip, reason}
    end
  end

  ## Videos

  # Measured first, like `Angler.Media.download/3` does for yt-dlp: the duration
  # Instagram reports is optional.
  defp prepare_item(%{type: :video, path: source} = item, index, job) do
    report = fn progress ->
      details = Enum.reject(["Preparing #{index}/#{job.total}", progress[:detail]], &is_nil/1)
      job.report.(Map.put(progress, :detail, Enum.join(details, " · ")))
    end

    video = %Download{path: source, size: item.size, duration: item.duration}

    with {:ok, video} <- Route.check_duration(video, job.max_duration),
         {:ok, output} <-
           Media.Prepare.run(video, Path.dirname(source),
             target_bytes: job.target,
             on_progress: report
           ) do
      {:ok,
       %{
         type: :video,
         path: output.path,
         size: output.size,
         width: output.width,
         height: output.height,
         duration: output.duration,
         thumbnail_path: output.thumbnail_path,
         video_codec: output.video_codec,
         transcoded: output.transcoded
       }}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, "could not read the file: #{:file.format_error(reason)}"}
    end
  end

  defp identify(path) do
    with :error <- Photo.read(path), do: {:error, "not a JPEG, PNG or WebP image"}
  end
end
