defmodule Angler.Media.Album.Cover do
  @moduledoc """
  The cover thumbnail of an album (the dashboard shows it for the entry): a JPEG
  of at most 320x320 and under 200 kB, like a video's thumbnail.

  It shows the first item it can be made from: a photo scaled down with ffmpeg
  (bounded, through `Angler.Media.Slideshow.Tools`), or a copy of a video's
  thumbnail. At most the first photo and the first video are tried. A missing
  cover never fails the album.
  """
  require Logger

  alias Angler.Media.Slideshow.{Commands, Tools}

  @timeout :timer.minutes(1)
  @max_bytes 200_000

  @doc """
  Writes the cover for the prepared album `items` (`t:Angler.Media.Output.item/0`,
  in display order) to `output`. Returns `output`, or nil when no cover could be made.
  """
  @spec make([Angler.Media.Output.item()], Path.t()) :: Path.t() | nil
  def make(items, output) do
    photo = Enum.find(items, &(&1.type == :photo))
    video = Enum.find(items, &(&1.type == :video and is_binary(&1.thumbnail_path)))

    items
    |> Enum.filter(&(&1 in [photo, video]))
    |> Enum.find_value(&from(&1, output))
    |> case do
      nil ->
        Logger.warning("Could not create a cover thumbnail for the album")
        File.rm(output)
        nil

      path ->
        path
    end
  end

  defp from(%{type: :video, thumbnail_path: thumbnail}, output) do
    case File.copy(thumbnail, output) do
      {:ok, _bytes} -> accepted(output)
      {:error, _reason} -> nil
    end
  end

  # A lower JPEG quality when the first try is too large.
  defp from(%{type: :photo, path: photo}, output) do
    Enum.find_value([4, 10], fn quality ->
      case Tools.ffmpeg(Commands.thumbnail_args(photo, output, quality), timeout: @timeout) do
        :ok -> accepted(output)
        {_failed_or_error, _error} -> nil
      end
    end)
  end

  defp accepted(output) do
    case File.stat(output) do
      {:ok, %File.Stat{size: size}} when size > 0 and size < @max_bytes -> output
      _other -> nil
    end
  end
end
