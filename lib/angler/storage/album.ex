defmodule Angler.Storage.Album do
  @moduledoc """
  The files of an album entry (`media_kind: :album`) in its directory:

      <entry dir>/thumbnail.jpg             cover (`Angler.Storage.output_paths/1`)
      <entry dir>/album/01/photo.jpg        a photo (`.jpg`, `.png` or `.webp`)
      <entry dir>/album/02/video.mp4        a video
      <entry dir>/album/02/thumbnail.jpg    and its thumbnail

  Each `Angler.Entries.MediaItem` records its paths relative to the entry
  directory. Stored paths are never trusted: a path is only used when it has one
  of the names above, lies inside the entry's own directory (and
  `Angler.Storage.root/0`) and is a regular file on disk, reached without
  following symlinks. So a bad row can't make the dashboard serve, or the
  pipeline upload or keep, any other file.

  Used through `Angler.Storage`.
  """
  alias Angler.Entries.{Entry, MediaItem}
  alias Angler.Storage

  @item_path ~r"\Aalbum/\d{2}/(photo\.(jpg|png|webp)|video\.mp4|thumbnail\.jpg)\z"

  @typedoc "An album item and its files, see `Angler.Storage.media_items/1`."
  @type item :: %{
          index: non_neg_integer(),
          item: MediaItem.t(),
          path: Path.t() | nil,
          thumbnail_path: Path.t() | nil
        }

  @doc "See `Angler.Storage.media_items/1`."
  @spec media_items(Entry.t()) :: [item()]
  def media_items(%Entry{} = entry) do
    dir = entry_dir(entry)

    entry
    |> items()
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      %{
        index: index,
        item: item,
        path: resolve(dir, item.path),
        thumbnail_path: resolve(dir, item.thumbnail)
      }
    end)
  end

  @doc "See `Angler.Storage.media_item_path/2`."
  @spec media_item_path(Entry.t(), integer()) :: Path.t() | nil
  def media_item_path(%Entry{} = entry, index) do
    with %MediaItem{path: path} <- item_at(entry, index), do: resolve(entry_dir(entry), path)
  end

  @doc "See `Angler.Storage.media_item_thumbnail_path/2`."
  @spec media_item_thumbnail_path(Entry.t(), integer()) :: Path.t() | nil
  def media_item_thumbnail_path(%Entry{} = entry, index) do
    with %MediaItem{thumbnail: thumbnail} <- item_at(entry, index),
         do: resolve(entry_dir(entry), thumbnail)
  end

  @doc "See `Angler.Storage.album_files/1`."
  @spec album_files(Entry.t()) :: [Path.t()]
  def album_files(%Entry{} = entry) do
    dir = entry_dir(entry)
    item_files = Enum.flat_map(media_items(entry), &[&1.path, &1.thumbnail_path])

    Enum.reject(item_files ++ [cover(dir)], &is_nil/1)
  end

  defp items(%Entry{media_items: items}) when is_list(items), do: items
  defp items(%Entry{}), do: []

  defp item_at(entry, index) when is_integer(index) and index >= 0,
    do: Enum.at(items(entry), index)

  defp item_at(_entry, _index), do: nil

  defp entry_dir(%Entry{storage_path: dir}) when is_binary(dir), do: Path.expand(dir)
  defp entry_dir(%Entry{}), do: nil

  defp cover(nil), do: nil

  defp cover(dir) do
    path = Storage.output_paths(dir).thumbnail
    if Storage.managed_path?(path) and real_file?(dir, "thumbnail.jpg"), do: path
  end

  # The absolute path of a stored relative path, if it passes every check.
  defp resolve(dir, relative) when is_binary(dir) and is_binary(relative) do
    with true <- Regex.match?(@item_path, relative),
         {:ok, safe} <- Path.safe_relative(relative, dir),
         path = Path.expand(safe, dir),
         true <- String.starts_with?(path, dir <> "/"),
         true <- Storage.managed_path?(path),
         true <- real_file?(dir, safe) do
      path
    else
      _invalid -> nil
    end
  end

  defp resolve(_dir, _relative), do: nil

  # Whether `relative` is a regular file under `dir` whose directories and itself
  # are not symlinks.
  defp real_file?(dir, relative) do
    {directories, [file]} =
      relative
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.split(-1)

    Enum.all?(directories, &(type(dir, &1) == :directory)) and type(dir, file) == :regular
  end

  defp type(dir, relative) do
    case File.lstat(Path.join(dir, relative)) do
      {:ok, %File.Stat{type: type}} -> type
      {:error, _reason} -> nil
    end
  end
end
