defmodule Angler.FakeMedia do
  @moduledoc """
  An `Angler.Media` implementation for pipeline tests. What it does depends on the
  first segment of the URL path, e.g. `https://fake.test/ok/1`:

    * `ok` - "downloads" and "prepares" a tiny video, writing real files into the
      entry directory (the final ones at `Angler.Storage.output_paths/1`)
    * `slideshow` - like `ok`, as a TikTok slideshow (`%Download{kind: :slideshow}`)
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

  @doc "The bytes of the video produced by `prepare/3`: CRLF and NUL must survive uploads."
  def video_bytes, do: <<"ftypisom", 0, 1, 2, "\r\n\r\n", 255, 254, "fake video">>

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
        File.write!(thumbnail, <<0xFF, 0xD8, 0xFF, 0xD9>>)
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

      _other ->
        {:error, Error.new(:internal, "ffmpeg exited with status 187", "Conversion failed!")}
    end
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
