defmodule Angler.Storage.AlbumTest do
  # Works in the configured storage root (the application env is not changed).
  use ExUnit.Case, async: true

  alias Angler.Entries.{Entry, MediaItem}
  alias Angler.Storage

  setup do
    id = Ecto.UUID.generate()
    dir = Path.join(Storage.root(), id)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  describe "media_items/1, media_item_path/2 and media_item_thumbnail_path/2" do
    test "resolve the stored paths of files on disk", %{dir: dir} do
      write_files(dir, [
        "album/01/photo.jpg",
        "album/02/video.mp4",
        "album/02/thumbnail.jpg",
        "album/03/photo.png",
        "album/04/photo.webp"
      ])

      entry =
        album_entry(dir, [
          photo("album/01/photo.jpg"),
          video("album/02/video.mp4", "album/02/thumbnail.jpg"),
          photo("album/03/photo.png"),
          photo("album/04/photo.webp")
        ])

      assert [
               %{index: 0, item: %MediaItem{type: :photo}, path: photo, thumbnail_path: nil},
               %{index: 1, item: %MediaItem{type: :video}, path: video, thumbnail_path: thumb},
               %{index: 2, path: png},
               %{index: 3, path: webp}
             ] = Storage.media_items(entry)

      assert photo == Path.join(dir, "album/01/photo.jpg")
      assert video == Path.join(dir, "album/02/video.mp4")
      assert thumb == Path.join(dir, "album/02/thumbnail.jpg")
      assert png == Path.join(dir, "album/03/photo.png")
      assert webp == Path.join(dir, "album/04/photo.webp")

      assert Storage.media_item_path(entry, 0) == photo
      assert Storage.media_item_path(entry, 1) == video
      assert Storage.media_item_thumbnail_path(entry, 1) == thumb
      assert Storage.media_item_thumbnail_path(entry, 0) == nil
    end

    test "resolve the index of an existing item only", %{dir: dir} do
      write_files(dir, ["album/01/photo.jpg"])
      entry = album_entry(dir, [photo("album/01/photo.jpg")])

      assert Storage.media_item_path(entry, 0)

      for index <- [1, 99, -1, "0", 0.0, nil] do
        assert Storage.media_item_path(entry, index) == nil
        assert Storage.media_item_thumbnail_path(entry, index) == nil
      end

      assert Storage.media_item_path(%{entry | media_items: []}, 0) == nil
    end

    test "ignore files that are not on disk", %{dir: dir} do
      # A directory where the photo should be, and a missing video and thumbnail.
      File.mkdir_p!(Path.join(dir, "album/01/photo.jpg"))

      entry =
        album_entry(dir, [
          photo("album/01/photo.jpg"),
          video("album/02/video.mp4", "album/02/thumbnail.jpg")
        ])

      assert [%{index: 0, path: nil}, %{index: 1, path: nil, thumbnail_path: nil}] =
               Storage.media_items(entry)

      assert Storage.media_item_path(entry, 1) == nil
      assert Storage.media_item_thumbnail_path(entry, 1) == nil

      # Without a directory, even files on disk are unknown.
      write_files(dir, ["album/02/video.mp4"])
      assert Storage.media_item_path(entry, 1)
      assert [%{path: nil}, %{path: nil}] = Storage.media_items(%{entry | storage_path: nil})
    end

    test "ignore stored paths leading outside the entry's directory", %{dir: dir} do
      other = Path.join(Storage.root(), Ecto.UUID.generate())
      on_exit(fn -> File.rm_rf!(other) end)
      write_files(other, ["album/01/photo.jpg"])
      write_files(dir, ["album/01/photo.jpg"])
      other_id = Path.basename(other)

      for path <- [
            "../#{other_id}/album/01/photo.jpg",
            "album/../../#{other_id}/album/01/photo.jpg",
            "album/01/../01/photo.jpg",
            "./album/01/photo.jpg",
            "album//01/photo.jpg",
            Path.join(other, "album/01/photo.jpg"),
            "/album/01/photo.jpg"
          ] do
        assert_ignored(dir, photo(path))
      end
    end

    # The test's own directory, outside the storage root.
    @tag :tmp_dir
    test "ignore entries whose directory is outside the storage root", %{tmp_dir: tmp_dir} do
      outside = Path.join(tmp_dir, "outside")
      refute Storage.managed_path?(outside)
      write_files(outside, ["album/01/photo.jpg", "thumbnail.jpg"])

      assert_ignored(outside, photo("album/01/photo.jpg"))
      assert Storage.album_files(album_entry(outside, [photo("album/01/photo.jpg")])) == []

      root_relative = Path.join(Storage.root(), "../outside-#{System.unique_integer()}")
      on_exit(fn -> File.rm_rf!(root_relative) end)
      write_files(root_relative, ["album/01/photo.jpg"])
      assert_ignored(root_relative, photo("album/01/photo.jpg"))
    end

    test "ignore file names other than the album's", %{dir: dir} do
      names = [
        "album/1/photo.jpg",
        "album/001/photo.jpg",
        "album/ab/photo.jpg",
        "album/01/photo.gif",
        "album/01/photo.jpeg",
        "album/01/PHOTO.JPG",
        "album/01/source.jpg",
        "album/01/photo.jpg.part",
        "album/01/thumbnail.png",
        "album/01/video.webm",
        "albums/01/photo.jpg",
        "photo.jpg",
        "video.mp4"
      ]

      write_files(dir, names)

      for name <- names, do: assert_ignored(dir, photo(name))

      # A trailing newline is not the end of the name (\z, not $).
      write_files(dir, ["album/01/photo.jpg"])
      assert_ignored(dir, photo("album/01/photo.jpg\n"))
    end

    test "ignore symlinks, to files or to directories", %{dir: dir} do
      write_files(dir, ["album/01/photo.jpg", "album/02/video.mp4", "elsewhere/photo.jpg"])
      File.mkdir_p!(Path.join(dir, "album/03"))

      File.ln_s!(Path.join(dir, "album/01/photo.jpg"), Path.join(dir, "album/03/photo.jpg"))
      File.ln_s!(Path.join(dir, "elsewhere"), Path.join(dir, "album/04"))
      File.ln_s!(Path.join(dir, "album/02/video.mp4"), Path.join(dir, "album/02/thumbnail.jpg"))

      assert Storage.media_item_path(album_entry(dir, [photo("album/01/photo.jpg")]), 0)

      assert_ignored(dir, photo("album/03/photo.jpg"))
      assert_ignored(dir, photo("album/04/photo.jpg"))

      entry = album_entry(dir, [video("album/02/video.mp4", "album/02/thumbnail.jpg")])
      assert Storage.media_item_path(entry, 0)
      assert Storage.media_item_thumbnail_path(entry, 0) == nil
    end

    test "ignore a symlinked album directory", %{dir: dir} do
      other = Path.join(Storage.root(), Ecto.UUID.generate())
      on_exit(fn -> File.rm_rf!(other) end)
      write_files(other, ["album/01/photo.jpg"])
      File.ln_s!(Path.join(other, "album"), Path.join(dir, "album"))

      assert_ignored(dir, photo("album/01/photo.jpg"))
    end
  end

  describe "album_files/1" do
    test "lists the item files, their thumbnails and the cover that are on disk", %{dir: dir} do
      write_files(dir, [
        "thumbnail.jpg",
        "album/01/photo.jpg",
        "album/02/video.mp4",
        "album/02/thumbnail.jpg",
        "album/03/source.jpg",
        "album/04/video.mp4"
      ])

      entry =
        album_entry(dir, [
          photo("album/01/photo.jpg"),
          video("album/02/video.mp4", "album/02/thumbnail.jpg"),
          photo("album/03/photo.jpg"),
          video("album/04/video.mp4", "album/04/thumbnail.jpg")
        ])

      assert Storage.album_files(entry) ==
               Enum.map(
                 [
                   "album/01/photo.jpg",
                   "album/02/video.mp4",
                   "album/02/thumbnail.jpg",
                   "album/04/video.mp4",
                   "thumbnail.jpg"
                 ],
                 &Path.join(dir, &1)
               )
    end

    test "leaves out a missing or symlinked cover", %{dir: dir} do
      write_files(dir, ["album/01/photo.jpg"])
      entry = album_entry(dir, [photo("album/01/photo.jpg")])
      photo = Path.join(dir, "album/01/photo.jpg")

      assert Storage.album_files(entry) == [photo]

      File.ln_s!(photo, Path.join(dir, "thumbnail.jpg"))
      assert Storage.album_files(entry) == [photo]
    end

    test "is empty without items or a directory", %{dir: dir} do
      write_files(dir, ["album/01/photo.jpg"])

      assert Storage.album_files(album_entry(dir, [])) == []
      assert Storage.album_files(album_entry(nil, [photo("album/01/photo.jpg")])) == []
    end
  end

  defp assert_ignored(dir, item) do
    entry = album_entry(dir, [item])

    assert [%{index: 0, path: nil, thumbnail_path: nil}] = Storage.media_items(entry),
           "#{inspect(item.path)} was not ignored"

    assert Storage.media_item_path(entry, 0) == nil
    assert Storage.album_files(entry) == []
  end

  defp album_entry(dir, items) do
    %Entry{id: Ecto.UUID.generate(), media_kind: :album, storage_path: dir, media_items: items}
  end

  defp photo(path), do: MediaItem.new(%{type: :photo, path: path, bytes: 5})

  defp video(path, thumbnail),
    do: MediaItem.new(%{type: :video, path: path, thumbnail: thumbnail, bytes: 5})

  defp write_files(dir, names) do
    for name <- names do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "bytes of " <> name)
    end
  end
end
