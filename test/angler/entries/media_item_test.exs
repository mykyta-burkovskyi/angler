defmodule Angler.Entries.MediaItemTest do
  use Angler.DataCase, async: true

  alias Angler.Entries
  alias Angler.Entries.{Entry, MediaItem}

  describe "new/1" do
    test "keeps every field" do
      attrs = %{
        type: :video,
        path: "album/02/video.mp4",
        thumbnail: "album/02/thumbnail.jpg",
        bytes: 1_234,
        width: 720,
        height: 1280,
        duration: 12.5,
        file_id: "FILE",
        file_unique_id: "UNIQUE"
      }

      assert MediaItem.new(attrs) == struct!(MediaItem, attrs)
    end

    test "normalizes values Ecto would refuse to store" do
      assert MediaItem.new(%{type: :video, duration: 12, width: 720.0, height: 1279.6}) ==
               %MediaItem{type: :video, duration: 12.0, width: 720, height: 1280}
    end

    test "accepts string keys and type names" do
      assert MediaItem.new(%{"type" => "photo", "path" => "album/01/photo.jpg", "bytes" => 10}) ==
               %MediaItem{type: :photo, path: "album/01/photo.jpg", bytes: 10}

      assert MediaItem.new(%{"type" => "video"}).type == :video
    end

    test "drops unknown keys, such as the other fields of an album output item" do
      output_item = %{
        type: :photo,
        path: "album/01/photo.jpg",
        size: 10,
        thumbnail_path: "/elsewhere/thumbnail.jpg",
        video_codec: nil,
        transcoded: false
      }

      assert MediaItem.new(output_item) == %MediaItem{type: :photo, path: "album/01/photo.jpg"}
    end

    test "turns missing values and values of the wrong type into nil" do
      assert MediaItem.new(%{}) == %MediaItem{}
      assert MediaItem.new(%{type: nil, path: nil, duration: nil, file_id: nil}) == %MediaItem{}

      assert MediaItem.new(%{
               type: :audio,
               path: :photo,
               thumbnail: 1,
               bytes: "10",
               width: nil,
               duration: "12.5",
               file_id: 42
             }) == %MediaItem{}

      assert MediaItem.new(%{"type" => "Photo"}).type == nil
      assert MediaItem.new(%{"type" => "slideshow"}).type == nil
    end

    test "rebuilds an item" do
      item = MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", bytes: 10})
      assert MediaItem.new(item) == item
      assert MediaItem.new(%{item | file_id: "FILE"}) == %{item | file_id: "FILE"}
    end
  end

  describe "delivered?/1" do
    test "holds once the item has a Telegram file id" do
      item = MediaItem.new(%{type: :photo, path: "album/01/photo.jpg"})

      refute MediaItem.delivered?(item)
      assert MediaItem.delivered?(%{item | file_id: "FILE", file_unique_id: "UNIQUE"})
    end
  end

  describe "entries.media_items" do
    test "is empty for new entries" do
      entry = queued_entry()

      assert entry.media_items == []
      assert Entries.get(entry.id).media_items == []
    end

    test "stores the items through update!/2 and mark_done/2" do
      entry = claimed_entry()

      items = [
        MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", bytes: 10, width: 1080}),
        MediaItem.new(%{
          type: :video,
          path: "album/02/video.mp4",
          thumbnail: "album/02/thumbnail.jpg",
          bytes: 20,
          duration: 12
        })
      ]

      entry = Entries.update!(entry, %{media_kind: :album, media_items: items})
      assert %Entry{media_kind: :album, media_items: ^items} = entry
      assert %Entry{media_kind: :album, media_items: ^items} = Entries.get(entry.id)

      delivered =
        Enum.map(items, &%{&1 | file_id: "FILE-" <> &1.path, file_unique_id: "U-" <> &1.path})

      assert %Entry{status: :done, media_items: ^delivered} =
               Entries.mark_done(entry, %{media_items: delivered})

      assert %Entry{status: :done, media_items: stored} = Entries.get(entry.id)
      assert stored == delivered
      assert Enum.all?(stored, &MediaItem.delivered?/1)

      # One JSON object per item, with the values as Telegram and the dashboard need them.
      assert %{rows: [[[photo, video]]]} =
               Repo.query!("SELECT media_items FROM entries WHERE id = $1", [
                 Ecto.UUID.dump!(entry.id)
               ])

      assert %{"type" => "photo", "path" => "album/01/photo.jpg", "file_id" => "FILE-" <> _} =
               photo

      assert %{"type" => "video", "duration" => 12.0, "thumbnail" => "album/02/thumbnail.jpg"} =
               video
    end

    test "replaces the whole list" do
      entry = claimed_entry()
      photo = MediaItem.new(%{type: :photo, path: "album/01/photo.jpg"})
      video = MediaItem.new(%{type: :video, path: "album/02/video.mp4"})

      entry = Entries.update!(entry, %{media_items: [photo, video]})
      entry = Entries.update!(entry, %{media_items: [video]})
      assert Entries.get(entry.id).media_items == [video]

      entry = Entries.update!(entry, %{media_items: []})
      assert Entries.get(entry.id).media_items == []
    end

    test "is loaded by the queue's bulk updates" do
      entry = claimed_entry()
      items = [MediaItem.new(%{type: :photo, path: "album/01/photo.jpg", file_id: "FILE"})]

      entry
      |> Entries.update!(%{media_kind: :album, media_items: items})
      |> Entries.schedule_retry(:transient, "later", 0)

      assert [%Entry{media_items: ^items}] = Entries.claim(1)
    end
  end

  defp queued_entry do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{
          url: "https://www.instagram.com/p/#{n}/",
          chat_id: 1,
          chat_type: "private",
          message_id: n
        }
      ])

    entry
  end

  defp claimed_entry do
    queued_entry()
    [entry] = Entries.claim(1)
    entry
  end
end
