defmodule Angler.FakeMedia do
  @moduledoc """
  An `Angler.Media` implementation for pipeline tests. What it does depends on the
  first segment of the URL path, e.g. `https://fake.test/ok/1`:

    * `ok` - "downloads" and "prepares" a tiny video, writing real files into the
      entry directory (the final ones at `Angler.Storage.output_paths/1`)
    * `slideshow` - like `ok`, as a TikTok slideshow (`%Download{kind: :slideshow}`)
    * `album` - an album (`%Download{kind: :album}` titled "Fake album") of a photo
      and a video, laid out like `Angler.Storage.Album`: the download writes
      `album/01/source.jpg` and `album/02/source.mp4`; preparing replaces them with
      `album/01/photo.jpg` (`photo_bytes/0`), `album/02/video.mp4` (`video_bytes/0`)
      and `album/02/thumbnail.jpg`, writes the cover thumbnail (`thumbnail.jpg`,
      see `Angler.Storage.output_paths/1`) and returns an `%Output{kind: :album}`
      with an item per file (the video's duration is whole seconds, an integer,
      as `Angler.Media.Prepare` returns it)
    * `album-long-text` - like `album`, titled with a 1500-character text (longer
      than a caption may be)
    * `album-12` - like `album`, with 12 photos (`album/01/photo.jpg` ...
      `album/12/photo.jpg`), more than one media group can hold
    * `unsupported`, `unavailable`, `too-large`, `transient`, `timeout`, `internal` -
      the download fails with that error kind
    * `prepare-fails` - the download works, preparing fails with `:internal`
    * `raise` - the download raises

  Every call is reported to the process registered under this module's name (if
  any) as `{:fake_media, :download, url, dir, opts}` or
  `{:fake_media, :prepare, download, dir, opts}`.
  """
  @behaviour Angler.Media

  alias Angler.Media.{Download, Error, Output}
  alias Angler.Storage

  @error_kinds %{
    "unsupported" => :unsupported,
    "unavailable" => :unavailable,
    "too-large" => :too_large,
    "transient" => :transient,
    "timeout" => :timeout,
    "internal" => :internal
  }

  @albums %{
    "album" => {"Fake album", [:photo, :video]},
    "album-long-text" => {String.duplicate("Fake album text. ", 88) <> "End.", [:photo, :video]},
    "album-12" => {"Fake album", List.duplicate(:photo, 12)}
  }

  @jpeg <<0xFF, 0xD8, 0xFF, 0xD9>>

  @doc "The bytes of the video produced by `prepare/3`: CRLF and NUL must survive uploads."
  def video_bytes, do: <<"ftypisom", 0, 1, 2, "\r\n\r\n", 255, 254, "fake video">>

  @doc "The bytes of every album photo produced by `prepare/3` (with CRLF and NUL too)."
  def photo_bytes, do: <<0xFF, 0xD8, 0xFF, 0xE0, "\r\n", 0, "fake photo", 0xFF, 0xD9>>

  @impl true
  def download(url, dir, opts) do
    notify({:fake_media, :download, url, dir, opts})

    case behaviour(url) do
      :ok ->
        progress(opts, %{percent: 50.0, detail: "1.0 MB of 2.0 MB"})
        path = Path.join(dir, "source.webm")
        File.write!(path, "source of " <> url)

        {:ok,
         %Download{
           path: path,
           size: File.stat!(path).size,
           title: "Fake video",
           extractor: "Fake",
           webpage_url: url,
           duration: 12.4,
           width: 720,
           height: 1280,
           video_codec: "vp9",
           audio_codec: "opus",
           kind: if(String.contains?(url, "/slideshow"), do: :slideshow, else: :video)
         }}

      {:album, segment} ->
        download_album(url, dir, segment, opts)

      :prepare_fails ->
        path = Path.join(dir, "source.webm")
        File.write!(path, "broken")
        {:ok, %Download{path: path, size: 6, webpage_url: url}}

      :raise ->
        raise "fake media crashed"

      {:error, kind} ->
        {:error, Error.new(kind, "Fake #{kind} failure")}
    end
  end

  @impl true
  def prepare(%Download{} = download, dir, opts) do
    notify({:fake_media, :prepare, download, dir, opts})

    case behaviour(download.webpage_url) do
      :ok ->
        progress(opts, %{percent: 100.0, detail: "Encoding 720p · pass 2/2"})
        %{video: video, thumbnail: thumbnail} = Storage.output_paths(dir)
        File.write!(video, video_bytes())
        File.write!(thumbnail, @jpeg)
        File.rm!(download.path)

        {:ok,
         %Output{
           path: video,
           size: byte_size(video_bytes()),
           thumbnail_path: thumbnail,
           duration: 12,
           width: 720,
           height: 1280,
           video_codec: "h264",
           transcoded: true
         }}

      {:album, _segment} ->
        prepare_album(download, dir, opts)

      _other ->
        {:error, Error.new(:internal, "ffmpeg exited with status 187", "Conversion failed!")}
    end
  end

  ## Albums

  defp download_album(url, dir, segment, opts) do
    {title, types} = Map.fetch!(@albums, segment)
    progress(opts, %{percent: 50.0, detail: "Downloading 1/#{length(types)}"})

    items =
      for {type, n} <- Enum.with_index(types, 1) do
        item_dir = Path.join([dir, "album", String.pad_leading("#{n}", 2, "0")])
        File.mkdir_p!(item_dir)
        path = Path.join(item_dir, if(type == :photo, do: "source.jpg", else: "source.mp4"))
        File.write!(path, "source #{n} of " <> url)
        Map.merge(%{type: type, path: path, size: File.stat!(path).size}, source_metadata(type))
      end

    {:ok,
     %Download{
       kind: :album,
       path: Path.join(dir, "album"),
       size: items |> Enum.map(& &1.size) |> Enum.sum(),
       items: items,
       title: title,
       extractor: "Fake",
       webpage_url: url,
       max_duration: opts[:max_duration]
     }}
  end

  defp source_metadata(:photo), do: %{width: 1080, height: 1350, duration: nil}
  defp source_metadata(:video), do: %{width: 720, height: 1280, duration: 12.4}

  defp prepare_album(%Download{items: items} = download, dir, opts) do
    progress(opts, %{percent: 100.0, detail: "Preparing #{length(items)}/#{length(items)}"})
    items = Enum.map(items, &prepare_item/1)
    %{thumbnail: cover} = Storage.output_paths(dir)
    File.write!(cover, @jpeg)
    [first | _rest] = items

    {:ok,
     %Output{
       kind: :album,
       path: download.path,
       size: items |> Enum.map(& &1.size) |> Enum.sum(),
       thumbnail_path: cover,
       width: first.width,
       height: first.height,
       transcoded: Enum.any?(items, & &1.transcoded),
       items: items
     }}
  end

  defp prepare_item(%{type: :photo, path: source} = item) do
    path = Path.join(Path.dirname(source), "photo.jpg")
    File.write!(path, photo_bytes())
    File.rm!(source)

    %{
      type: :photo,
      path: path,
      size: byte_size(photo_bytes()),
      width: item.width,
      height: item.height,
      duration: nil,
      thumbnail_path: nil,
      video_codec: nil,
      transcoded: false
    }
  end

  defp prepare_item(%{type: :video, path: source}) do
    %{video: path, thumbnail: thumbnail} = Storage.output_paths(Path.dirname(source))
    File.write!(path, video_bytes())
    File.write!(thumbnail, @jpeg)
    File.rm!(source)

    %{
      type: :video,
      path: path,
      size: byte_size(video_bytes()),
      width: 720,
      height: 1280,
      duration: 12,
      thumbnail_path: thumbnail,
      video_codec: "h264",
      transcoded: true
    }
  end

  defp behaviour(url) do
    case url
         |> URI.parse()
         |> Map.get(:path, "")
         |> to_string()
         |> String.split("/", trim: true) do
      [segment | _rest] when segment in ["ok", "slideshow"] -> :ok
      ["prepare-fails" | _rest] -> :prepare_fails
      ["raise" | _rest] -> :raise
      [segment | _rest] when is_map_key(@albums, segment) -> {:album, segment}
      [segment | _rest] when is_map_key(@error_kinds, segment) -> {:error, @error_kinds[segment]}
      _other -> {:error, :unsupported}
    end
  end

  defp progress(opts, progress) do
    if on_progress = opts[:on_progress], do: on_progress.(progress)
  end

  defp notify(message) do
    if pid = Process.whereis(__MODULE__), do: send(pid, message)
  end
end
