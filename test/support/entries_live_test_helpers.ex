defmodule AnglerWeb.EntriesLiveTestHelpers do
  @moduledoc """
  Fixtures and queries shared by the tests of the entries list
  (`AnglerWeb.EntriesLive` and `AnglerWeb.EntriesLive.Rows`), and album entries
  with their files on disk for the entry page and `AnglerWeb.MediaController`.
  """

  import Phoenix.LiveViewTest, only: [render: 1]

  alias Angler.Entries
  alias Angler.Entries.MediaItem
  alias Angler.Storage

  @doc """
  A queued TikTok entry, updated with `attrs` (all but `:url`, which is set on
  enqueue).
  """
  def entry_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{
          url: Map.get(attrs, :url, "https://www.tiktok.com/@user/video/#{n}"),
          source_host: "tiktok.com",
          chat_id: -1_001_234,
          chat_type: "supergroup",
          chat_title: "Video club",
          message_id: n,
          from_id: 42,
          from_name: "Ann"
        }
      ])

    case Map.delete(attrs, :url) do
      attrs when attrs == %{} -> entry
      attrs -> Entries.update!(entry, attrs)
    end
  end

  @doc """
  The files `album_fixture/1` writes, by their path relative to the entry
  directory (the layout of `Angler.Storage.Album`), with their bytes.
  """
  def album_files do
    %{
      "thumbnail.jpg" => <<0xFF, 0xD8, 0xFF, "cover">>,
      "album/01/photo.jpg" => <<0xFF, 0xD8, 0xFF, 0xE0, "\r\n", 0, "photo", 0xFF, 0xD9>>,
      "album/02/video.mp4" => for(i <- 0..999, into: <<>>, do: <<rem(i, 256)>>),
      "album/02/thumbnail.jpg" => <<0xFF, 0xD8, 0xFF, "video thumbnail">>
    }
  end

  @doc """
  A delivered Instagram album of a photo and a video (both sent), with its files
  (`album_files/0`) in its directory under `Angler.Storage.root/0`, which is
  removed when the test exits. `attrs` are set last (e.g. other `:media_items`).
  """
  def album_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    entry = entry_fixture(%{url: "https://www.instagram.com/p/C#{n}/"})
    {:ok, dir, entry} = Storage.prepare_dir(entry)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)

    for {path, bytes} <- album_files() do
      path = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    entry
    |> Storage.record_usage()
    |> Entries.mark_done(Map.merge(album_attrs(), attrs))
  end

  defp album_attrs do
    files = album_files()

    %{
      source_host: "instagram.com",
      title: "Sunset at the lake\n\nMore photos soon #summer",
      extractor: "Instagram",
      media_kind: :album,
      output_bytes:
        byte_size(files["album/01/photo.jpg"]) + byte_size(files["album/02/video.mp4"]),
      reply_message_id: 501,
      media_items: [
        MediaItem.new(%{
          type: :photo,
          path: "album/01/photo.jpg",
          bytes: byte_size(files["album/01/photo.jpg"]),
          width: 1080,
          height: 1350,
          file_id: "AgACAgIAAxkBAAIBphoto",
          file_unique_id: "AQADphoto"
        }),
        MediaItem.new(%{
          type: :video,
          path: "album/02/video.mp4",
          thumbnail: "album/02/thumbnail.jpg",
          bytes: byte_size(files["album/02/video.mp4"]),
          width: 720,
          height: 1280,
          duration: 12,
          file_id: "BAACAgIAAxkBAAIBvideo",
          file_unique_id: "AgADvideo"
        })
      ]
    }
  end

  @doc "The DOM ids of the rows the view lists, in order."
  def row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#entries > li")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
  end

  @doc "The DOM id of an entry's row."
  def dom_id(entry), do: "entry-#{entry.id}"
end
