defmodule Angler.Media.Album.NetworkTest do
  # Live Instagram posts through Angler.Media.download/3 and prepare/3 (real
  # Instagram and its CDN; posts with videos also need ffmpeg and ffprobe).
  # Excluded by default; run with:
  #
  #   mix test test/angler/media/album/network_test.exs --include network
  #
  # Not async: talks to Instagram without the Req.Test stub of the test configuration.
  use ExUnit.Case, async: false

  alias Angler.Media
  alias Angler.Media.{Download, Output}
  alias Angler.Media.Album.Photo

  @moduletag :network
  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: :timer.minutes(5)

  @target 50_000_000

  setup do
    original = Application.get_env(:angler, Media.Instagram)
    Application.put_env(:angler, Media.Instagram, retry_delays: [1_000, 2_000])
    on_exit(fn -> Application.put_env(:angler, Media.Instagram, original) end)
  end

  # Downloads and prepares `url` like the pipeline does, retrying transient
  # failures a few times (only the last attempt may leave out refused files).
  defp deliver(url, dir, attempts \\ 3) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    opts = [
      target_bytes: @target,
      max_source_bytes: 1_024_000_000,
      max_duration: 1_800,
      final_attempt: attempts == 1
    ]

    with {:ok, download} <- Media.download(url, dir, opts),
         {:ok, output} <- Media.prepare(download, dir, target_bytes: @target) do
      {download, output}
    else
      {:error, %Media.Error{kind: :transient}} when attempts > 1 ->
        deliver(url, dir, attempts - 1)

      {:error, error} ->
        flunk("#{url}: #{inspect(error)}")
    end
  end

  defp assert_photo(item, dir, n) do
    assert %{type: :photo, video_codec: nil, transcoded: false} = item
    assert item.path == Path.join([dir, "album", n, "photo.jpg"])
    assert {:ok, %{format: :jpeg, width: width, height: height}} = Photo.read(item.path)
    assert {width, height} == {item.width, item.height}
    assert item.size == File.stat!(item.path).size
  end

  test "a carousel of three photos", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "photos")
    {download, output} = deliver("https://www.instagram.com/p/DdwalmrkTSK/", dir)

    assert %Download{kind: :album, extractor: "Instagram", items: [_, _, _]} = download
    assert %Output{kind: :album, items: [first, second, third]} = output

    for {item, n} <- [{first, "01"}, {second, "02"}, {third, "03"}],
        do: assert_photo(item, dir, n)

    assert {output.width, output.height} == {first.width, first.height}
    assert output.thumbnail_path in [nil, Path.join(dir, "thumbnail.jpg")]
  end

  test "a carousel of twelve photos", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "twelve")
    {_download, output} = deliver("https://www.instagram.com/p/DdulMV-D4cS/", dir)

    assert %Output{kind: :album, items: items} = output
    assert length(items) == 12
    assert List.last(items).path == Path.join([dir, "album", "12", "photo.jpg"])
  end

  @tag :external
  test "a carousel of a photo and a video", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "mixed")
    {_download, output} = deliver("https://www.instagram.com/p/DduKfFmDxsG/", dir)

    assert %Output{kind: :album, items: [photo, video]} = output
    assert_photo(photo, dir, "01")
    assert %{type: :video, video_codec: "h264"} = video
    assert video.path == Path.join(dir, "album/02/video.mp4")
    assert video.thumbnail_path == Path.join(dir, "album/02/thumbnail.jpg")
    assert output.thumbnail_path == Path.join(dir, "thumbnail.jpg")
  end
end
