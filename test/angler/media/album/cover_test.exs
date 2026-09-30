defmodule Angler.Media.Album.CoverTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Album.Cover
  alias Angler.Media.Probe

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp photo(path), do: %{type: :photo, path: path, thumbnail_path: nil}
  defp video(thumbnail), do: %{type: :video, path: "video.mp4", thumbnail_path: thumbnail}

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  test "copies the thumbnail of a video", %{tmp_dir: dir} do
    thumbnail = write!(dir, "video-thumbnail.jpg", "a thumbnail")
    cover = Path.join(dir, "thumbnail.jpg")

    assert Cover.make([video(thumbnail)], cover) == cover
    assert File.read!(cover) == "a thumbnail"
  end

  test "falls back to a video when the first photo can't be read", %{tmp_dir: dir} do
    # Works with and without ffmpeg installed: it can't read this "photo" either way.
    unreadable = write!(dir, "photo.jpg", "not a photo")
    thumbnail = write!(dir, "video-thumbnail.jpg", "a thumbnail")
    cover = Path.join(dir, "thumbnail.jpg")

    assert Cover.make([photo(unreadable), video(nil), video(thumbnail)], cover) == cover
    assert File.read!(cover) == "a thumbnail"
  end

  test "makes no cover when nothing works", %{tmp_dir: dir} do
    cover = Path.join(dir, "thumbnail.jpg")
    unreadable = write!(dir, "photo.jpg", "not a photo")

    assert Cover.make([photo(unreadable), video(nil)], cover) == nil
    refute File.exists?(cover)

    # Telegram refuses thumbnails of 200 kB or more.
    large = write!(dir, "large.jpg", :binary.copy("x", 200_000))
    assert Cover.make([video(large)], cover) == nil
    refute File.exists?(cover)

    assert Cover.make([video(Path.join(dir, "missing.jpg"))], cover) == nil
    assert Cover.make([], cover) == nil
  end

  @tag :external
  test "scales the first photo down", %{tmp_dir: dir} do
    source = Path.join(dir, "photo.jpg")

    {output, status} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1080x1440 -frames:v 1) ++
          [source],
        stderr_to_stdout: true
      )

    assert status == 0, output
    cover = Path.join(dir, "thumbnail.jpg")
    other = write!(dir, "video-thumbnail.jpg", "a thumbnail")

    assert Cover.make([photo(source), video(other)], cover) == cover
    assert {:ok, %Probe{width: 240, height: 320}} = Probe.run(cover)
  end
end
