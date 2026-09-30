defmodule Angler.Media.Album.PrepareTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Angler.Media.{Album, Download, Error, Output, Probe}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @mb 1_000_000

  # Only the headers matter: photos are sent as they are.
  defp jpeg(width, height) do
    <<0xFF, 0xD8, 0xFF, 0xE0, 16::16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xC2, 11::16, 8,
      height::16, width::16, 1, 1, 0x11, 0, 0xFF, 0xDA, 8::16, 1, 1, 0, 0, 63, 0, "data", 0xFF,
      0xD9>>
  end

  defp png(width, height) do
    <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", width::32, height::32, 8, 6, 0, 0, 0, 0::32>>
  end

  defp webp(width, height) do
    chunk = <<"VP8X", 10::little-32, 0, 0::24, width - 1::little-24, height - 1::little-24>>
    <<"RIFF", byte_size(chunk) + 4::little-32, "WEBP", chunk::binary>>
  end

  # Writes the items (`{type, contents}` or `{type, contents, extra fields}`) the
  # way `Angler.Media.Album.download/3` does and returns the download.
  defp album(dir, items, opts \\ []) do
    items =
      for {item, n} <- Enum.with_index(items, 1) do
        {type, contents, extra} =
          case item do
            {type, contents} -> {type, contents, %{}}
            {type, contents, extra} -> {type, contents, extra}
          end

        item_dir = Path.join([dir, "album", String.pad_leading("#{n}", 2, "0")])
        File.mkdir_p!(item_dir)
        path = Path.join(item_dir, if(type == :photo, do: "source.jpg", else: "source.mp4"))
        File.write!(path, contents)

        Map.merge(
          %{
            type: type,
            path: path,
            size: byte_size(contents),
            width: nil,
            height: nil,
            duration: nil
          },
          extra
        )
      end

    %Download{
      kind: :album,
      path: Path.join(dir, "album"),
      size: items |> Enum.map(& &1.size) |> Enum.sum(),
      items: items,
      max_duration: Keyword.get(opts, :max_duration),
      title: "Post text",
      extractor: "Instagram"
    }
  end

  defp prepare(download, dir, opts \\ []) do
    test = self()

    opts =
      opts
      |> Keyword.put_new(:target_bytes, 50 * @mb)
      |> Keyword.put_new(:on_progress, &send(test, {:progress, &1}))

    Album.prepare(download, dir, opts)
  end

  defp progress_messages do
    receive do
      {:progress, progress} -> [progress | progress_messages()]
    after
      0 -> []
    end
  end

  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  test "sends photos as they are, named after their format", %{tmp_dir: dir} do
    download =
      album(dir, [{:photo, jpeg(1080, 1440)}, {:photo, png(640, 480)}, {:photo, webp(800, 600)}])

    assert {:ok, %Output{} = output} = prepare(download, dir)

    album = Path.join(dir, "album")
    cover = Path.join(dir, "thumbnail.jpg")

    assert %Output{
             kind: :album,
             path: ^album,
             width: 1080,
             height: 1440,
             duration: nil,
             video_codec: nil,
             transcoded: false
           } = output

    assert output.items == [
             %{
               type: :photo,
               path: Path.join(album, "01/photo.jpg"),
               size: byte_size(jpeg(1080, 1440)),
               width: 1080,
               height: 1440,
               duration: nil,
               thumbnail_path: nil,
               video_codec: nil,
               transcoded: false
             },
             %{
               type: :photo,
               path: Path.join(album, "02/photo.png"),
               size: byte_size(png(640, 480)),
               width: 640,
               height: 480,
               duration: nil,
               thumbnail_path: nil,
               video_codec: nil,
               transcoded: false
             },
             %{
               type: :photo,
               path: Path.join(album, "03/photo.webp"),
               size: byte_size(webp(800, 600)),
               width: 800,
               height: 600,
               duration: nil,
               thumbnail_path: nil,
               video_codec: nil,
               transcoded: false
             }
           ]

    assert output.size == Enum.sum(Enum.map(output.items, & &1.size))
    assert File.read!(Path.join(album, "02/photo.png")) == png(640, 480)

    # ffmpeg can't read these header-only photos: no cover, which is fine.
    assert output.thumbnail_path in [nil, cover]

    assert files(dir) -- ["thumbnail.jpg"] ==
             ["album/01/photo.jpg", "album/02/photo.png", "album/03/photo.webp"]

    progress = progress_messages()
    assert %{percent: 0.0, detail: "Preparing 1/3"} in progress
    assert %{percent: 2 / 3 * 100, detail: "Preparing 3/3"} in progress
  end

  test "leaves out photos Telegram would refuse and files that are not photos", %{tmp_dir: dir} do
    large = jpeg(1080, 1440) <> :binary.copy(<<0>>, 10 * @mb)

    download =
      album(dir, [
        {:photo, "<!DOCTYPE html><html>Too many requests</html>"},
        {:photo, png(100, 2001)},
        {:photo, jpeg(6000, 4001)},
        {:photo, large},
        {:photo, jpeg(1080, 1350)}
      ])

    log =
      capture_log(fn ->
        assert {:ok, %Output{items: [only], width: 1080, height: 1350}} = prepare(download, dir)
        assert only.path == Path.join(dir, "album/05/photo.jpg")
      end)

    assert log =~ "Leaving out item 1 of an Instagram post: not a JPEG, PNG or WebP image"
    assert log =~ "Leaving out item 2 of an Instagram post: 100x2001 is too narrow"
    assert log =~ "Leaving out item 3 of an Instagram post: 6000x4001 pixels is too large"
    assert log =~ "Leaving out item 4 of an Instagram post: larger than 10 MB"
    assert dir |> Path.join("album") |> File.ls!() == ["05"]
  end

  test "leaves out photos larger than the upload limit", %{tmp_dir: dir} do
    download =
      album(dir, [{:photo, jpeg(10, 10) <> :binary.copy("x", 2_000)}, {:photo, png(5, 5)}])

    assert {:ok, %Output{items: [%{path: path}]}} = prepare(download, dir, target_bytes: 1_000)
    assert Path.basename(path) == "photo.png"
  end

  test "fails when nothing can be sent", %{tmp_dir: dir} do
    download = album(dir, [{:photo, "not a photo"}, {:photo, png(1, 21)}])

    assert {:error,
            %Error{kind: :unsupported, message: "Nothing in this Instagram post can be sent"}} =
             prepare(download, dir)

    assert files(dir) == []
  end

  test "refuses videos longer than the download's limit", %{tmp_dir: dir} do
    # ffprobe can't measure this file, so the duration Instagram reported counts.
    download =
      album(dir, [{:photo, png(5, 5)}, {:video, "not a video", %{duration: 12.5}}],
        max_duration: 10
      )

    assert {:error, %Error{kind: :too_large, message: "Video is longer than 10 seconds"}} =
             prepare(download, dir)
  end

  describe "with ffmpeg" do
    @describetag :external

    defp ffmpeg!(path, args) do
      {output, status} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args ++ [path],
          stderr_to_stdout: true
        )

      assert status == 0, output
      File.read!(path)
    end

    defp photo!(dir, size),
      do: ffmpeg!(Path.join(dir, "in.jpg"), ~w(-f lavfi -i testsrc2=size=#{size} -frames:v 1))

    defp video!(dir, seconds) do
      ffmpeg!(
        Path.join(dir, "in.mp4"),
        ~w(-f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=frequency=440) ++
          ["-t", "#{seconds}"] ++
          ~w(-c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -movflags +faststart)
      )
    end

    test "prepares photos and videos in their directories, with a cover", %{tmp_dir: dir} do
      work = Path.join(dir, "work")
      File.mkdir_p!(work)
      entry = Path.join(dir, "entry")

      download =
        album(entry, [{:photo, photo!(work, "1080x1350")}, {:video, video!(work, 2)}],
          max_duration: 60
        )

      assert {:ok, %Output{kind: :album, items: [photo, video]} = output} =
               prepare(download, entry)

      assert %{type: :photo, width: 1080, height: 1350, thumbnail_path: nil} = photo

      assert %{
               type: :video,
               width: 640,
               height: 360,
               duration: 2,
               video_codec: "h264",
               transcoded: false
             } = video

      assert video.path == Path.join(entry, "album/02/video.mp4")
      assert video.thumbnail_path == Path.join(entry, "album/02/thumbnail.jpg")
      assert output.size == photo.size + video.size
      assert output.thumbnail_path == Path.join(entry, "thumbnail.jpg")

      assert {:ok, %Probe{width: width, height: height}} = Probe.run(output.thumbnail_path)
      assert width <= 320 and height <= 320
      assert File.stat!(output.thumbnail_path).size < 200_000

      assert files(entry) == [
               "album/01/photo.jpg",
               "album/02/thumbnail.jpg",
               "album/02/video.mp4",
               "thumbnail.jpg"
             ]
    end

    test "fails when a video can't be prepared", %{tmp_dir: dir} do
      download = album(dir, [{:photo, png(5, 5)}, {:video, "<html>not a video</html>"}])

      assert {:error,
              %Error{kind: :unsupported, message: "Downloaded file is not a playable video"}} =
               prepare(download, dir)
    end

    test "fails a video it can't measure within the reported duration", %{tmp_dir: dir} do
      # Instagram's 10.9 seconds are within the limit: the file is prepared, and fails.
      download = album(dir, [{:video, "not a video", %{duration: 10.9}}], max_duration: 10)

      assert {:error,
              %Error{kind: :unsupported, message: "Downloaded file is not a playable video"}} =
               prepare(download, dir)
    end

    test "refuses a video longer than the limit it measures", %{tmp_dir: dir} do
      work = Path.join(dir, "work")
      File.mkdir_p!(work)
      entry = Path.join(dir, "entry")

      # Instagram's duration is optional; the file's own counts.
      download = album(entry, [{:video, video!(work, 4), %{duration: nil}}], max_duration: 1)

      assert {:error, %Error{kind: :too_large, message: "Video is longer than 1 second"}} =
               prepare(download, entry)
    end
  end
end
