defmodule Angler.FakeMediaTest do
  # The fake itself: pipeline tests rely on the files and structs documented in
  # `Angler.FakeMedia`.
  use ExUnit.Case, async: true

  alias Angler.FakeMedia
  alias Angler.Media.{Download, Output}
  alias Angler.Storage

  @moduletag :tmp_dir

  describe "album" do
    test "downloads a photo and a video", %{tmp_dir: dir} do
      url = "https://fake.test/album/1"

      assert {:ok, %Download{kind: :album, items: [photo, video]} = download} =
               FakeMedia.download(url, dir, max_duration: 600)

      assert %Download{
               title: "Fake album",
               extractor: "Fake",
               webpage_url: ^url,
               max_duration: 600
             } = download

      assert download.path == Path.join(dir, "album")
      assert files(dir) == ["album/01/source.jpg", "album/02/source.mp4"]

      assert %{type: :photo, width: 1080, height: 1350, duration: nil} = photo
      assert %{type: :video, width: 720, height: 1280, duration: 12.4} = video
      assert photo.path == Path.join(dir, "album/01/source.jpg")
      assert video.path == Path.join(dir, "album/02/source.mp4")
      assert photo.size == File.stat!(photo.path).size
      assert download.size == photo.size + video.size
    end

    test "prepares the album's final files", %{tmp_dir: dir} do
      {:ok, download} = FakeMedia.download("https://fake.test/album/1", dir, [])
      parent = self()
      on_progress = &send(parent, {:progress, &1})

      assert {:ok, %Output{kind: :album, items: [photo, video]} = output} =
               FakeMedia.prepare(download, dir, on_progress: on_progress)

      assert_received {:progress, %{detail: "Preparing 2/2"}}

      assert files(dir) == [
               "album/01/photo.jpg",
               "album/02/thumbnail.jpg",
               "album/02/video.mp4",
               "thumbnail.jpg"
             ]

      assert %Output{path: path, thumbnail_path: cover, duration: nil, transcoded: true} = output
      assert path == Path.join(dir, "album")
      assert cover == Storage.output_paths(dir).thumbnail
      assert {output.width, output.height} == {1080, 1350}
      assert output.size == photo.size + video.size

      assert photo == %{
               type: :photo,
               path: Path.join(dir, "album/01/photo.jpg"),
               size: byte_size(FakeMedia.photo_bytes()),
               width: 1080,
               height: 1350,
               duration: nil,
               thumbnail_path: nil,
               video_codec: nil,
               transcoded: false
             }

      assert video == %{
               type: :video,
               path: Path.join(dir, "album/02/video.mp4"),
               size: byte_size(FakeMedia.video_bytes()),
               width: 720,
               height: 1280,
               duration: 12,
               thumbnail_path: Path.join(dir, "album/02/thumbnail.jpg"),
               video_codec: "h264",
               transcoded: true
             }

      assert File.read!(photo.path) == FakeMedia.photo_bytes()
      assert File.read!(video.path) == FakeMedia.video_bytes()
    end

    test "album-long-text is titled with a text longer than a caption", %{tmp_dir: dir} do
      {:ok, download} = FakeMedia.download("https://fake.test/album-long-text/1", dir, [])

      assert %Download{kind: :album, items: [%{type: :photo}, %{type: :video}]} = download
      assert String.length(download.title) == 1500

      assert {:ok, %Output{kind: :album, items: [_photo, _video]}} =
               FakeMedia.prepare(download, dir, [])
    end

    test "album-12 has 12 photos", %{tmp_dir: dir} do
      {:ok, download} = FakeMedia.download("https://fake.test/album-12/1", dir, [])

      assert %Download{kind: :album, title: "Fake album", items: items} = download
      assert length(items) == 12
      assert Enum.all?(items, &(&1.type == :photo))

      assert {:ok, %Output{kind: :album, items: items, transcoded: false}} =
               FakeMedia.prepare(download, dir, [])

      assert Enum.map(items, & &1.path) ==
               for(n <- 1..12, do: Path.join(dir, "album/#{pad(n)}/photo.jpg"))

      assert length(files(dir)) == 13
    end
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  # Regular files under `dir`, relative and sorted.
  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end
end
