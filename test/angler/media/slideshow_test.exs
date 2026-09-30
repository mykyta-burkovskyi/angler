defmodule Angler.Media.SlideshowTest do
  use ExUnit.Case, async: true

  import Angler.TikTokFixtures

  alias Angler.Media.{Download, Error, Slideshow}
  alias Angler.Media.Slideshow.Sound
  alias Angler.Media.TikTok.Post

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp post(count, opts \\ []) do
    "7553302113757990166" |> slideshow_item(count, opts) |> Post.from_item("7553302113757990166")
  end

  # Serves image n as "image n" and the sound through `audio` (default: 404).
  defp stub_cdn(opts \\ []) do
    audio = Keyword.get(opts, :audio, &Plug.Conn.send_resp(&1, 404, ""))
    image = Keyword.get(opts, :image, fn conn, n -> bytes(conn, "image #{n}") end)

    stub_tiktok(fn conn ->
      case {conn.host, conn.path_info} do
        {"sf16.tiktokcdn.test", _path} -> audio.(conn)
        {_cdn, [_post, file]} -> image.(conn, file |> Path.rootname() |> String.to_integer())
      end
    end)
  end

  defp progress_messages do
    receive do
      {:progress, progress} -> [progress | progress_messages()]
    after
      0 -> []
    end
  end

  defp download(post, dir, opts \\ []) do
    test = self()

    Slideshow.download(
      post,
      dir,
      Keyword.put_new(opts, :on_progress, &send(test, {:progress, &1}))
    )
  end

  test "downloads the images in display order", %{tmp_dir: dir} do
    stub_cdn()
    post = post(12, audio_url: "")

    assert {:ok, %Download{} = download} = download(post, dir, max_source_bytes: 1_000_000)

    slides = Path.join(dir, "slides")
    names = for n <- 1..12, do: String.pad_leading("#{n}", 2, "0") <> ".jpg"

    assert %Download{
             kind: :slideshow,
             path: ^slides,
             audio_path: nil,
             duration: nil,
             title: "Photos from the match",
             extractor: "TikTok",
             webpage_url: "https://www.tiktok.com/@hullcity/photo/7553302113757990166"
           } = download

    assert download.images == Enum.map(names, &Path.join(slides, &1))
    assert File.read!(Path.join(slides, "03.jpg")) == "image 3"
    assert File.read!(Path.join(slides, "12.jpg")) == "image 12"
    assert download.size == Enum.sum(for n <- 1..12, do: byte_size("image #{n}"))
    assert slides |> File.ls!() |> Enum.sort() == names

    progress = progress_messages()
    assert %{percent: 25.0, detail: "Downloading images 3/12"} in progress
    assert List.last(progress) == %{percent: 100.0, detail: "Downloading images 12/12"}

    # Only the first CDN host was needed; no sound was requested.
    for _n <- 1..12, do: assert_received({:tiktok_request, "GET", "p16.tiktokcdn.test/" <> _, _})
    refute_received {:tiktok_request, _method, _path, _conn}
  end

  test "uses at most 35 images", %{tmp_dir: dir} do
    stub_cdn()
    assert {:ok, %Download{images: images}} = download(post(40, audio_url: ""), dir)
    assert length(images) == 35
    assert List.last(images) |> Path.basename() == "35.jpg"
  end

  test "falls back to the second CDN host", %{tmp_dir: dir} do
    stub_cdn(
      image: fn conn, n ->
        if conn.host == "p16.tiktokcdn.test" and n == 2,
          do: Plug.Conn.send_resp(conn, 403, "expired"),
          else: bytes(conn, "#{conn.host} #{n}")
      end
    )

    assert {:ok, %Download{images: [_, second, _]}} = download(post(3, audio_url: ""), dir)
    assert File.read!(second) == "p19.tiktokcdn.test 2"
  end

  test "skips images every host refuses on the final attempt", %{tmp_dir: dir} do
    stub_cdn(
      image: fn conn, n ->
        if n == 2, do: Plug.Conn.send_resp(conn, 404, ""), else: bytes(conn, "image #{n}")
      end
    )

    assert {:ok, %Download{images: images}} = download(post(3, audio_url: ""), dir)
    assert Enum.map(images, &Path.basename/1) == ["01.jpg", "03.jpg"]
    refute File.exists?(Path.join([dir, "slides", "02.jpg"]))

    assert {:ok, %Download{images: [_, _]}} =
             download(post(3, audio_url: ""), Path.join(dir, "final"), final_attempt: true)
  end

  test "retries refused images later while more attempts follow", %{tmp_dir: dir} do
    stub_cdn(
      image: fn conn, n ->
        cond do
          n != 2 -> bytes(conn, "image #{n}")
          conn.host == "p16.tiktokcdn.test" -> Plug.Conn.send_resp(conn, 403, "")
          true -> bytes(conn, "")
        end
      end
    )

    assert {:error,
            %Error{
              kind: :transient,
              message: "Could not download slideshow image 2 (HTTP 403, empty response)"
            }} = download(post(3, audio_url: ""), dir, final_attempt: false)
  end

  test "fails when no image could be downloaded", %{tmp_dir: dir} do
    stub_cdn(image: fn conn, _n -> Plug.Conn.send_resp(conn, 410, "") end)

    assert {:error,
            %Error{kind: :unavailable, message: "Could not download the slideshow images"}} =
             download(post(2, audio_url: ""), dir)

    assert {:error, %Error{kind: :unsupported, message: "This TikTok slideshow has no images"}} =
             download(%Post{id: "1", images: []}, dir)
  end

  test "network trouble is a transient error", %{tmp_dir: dir} do
    stub_cdn(
      image: fn conn, n ->
        cond do
          n != 2 -> bytes(conn, "image #{n}")
          conn.host == "p16.tiktokcdn.test" -> Req.Test.transport_error(conn, :econnreset)
          true -> Plug.Conn.send_resp(conn, 503, "")
        end
      end
    )

    assert {:error, %Error{kind: :transient, message: message}} =
             download(post(3, audio_url: ""), dir)

    assert message =~ "Could not download slideshow image 2"
    assert message =~ "HTTP 503"
  end

  test "refuses slideshows larger than the source limit", %{tmp_dir: dir} do
    stub_cdn(image: fn conn, _n -> bytes(conn, :binary.copy("x", 400_000)) end)

    assert {:error, %Error{kind: :too_large, message: "This slideshow is larger than 1 MB"}} =
             download(post(5, audio_url: ""), dir, max_source_bytes: 1_000_000)
  end

  test "skips a single image larger than 30 MB", %{tmp_dir: dir} do
    big = :binary.copy(<<0>>, 30_000_001)

    stub_cdn(image: fn conn, n -> bytes(conn, if(n == 1, do: big, else: "image #{n}")) end)

    assert {:ok, %Download{images: [only]}} = download(post(2, audio_url: ""), dir)
    assert Path.basename(only) == "02.jpg"
  end

  test "makes a silent slideshow when the CDN refuses the sound on the final attempt",
       %{tmp_dir: dir} do
    stub_cdn(audio: &Plug.Conn.send_resp(&1, 403, "Forbidden"))

    assert {:ok, %Download{audio_path: nil, duration: nil, images: [_, _]}} =
             download(post(2), dir, final_attempt: true)

    assert_received {:tiktok_request, "GET", "sf16.tiktokcdn.test/" <> _, _conn}
    assert %{percent: nil, detail: "Downloading sound"} in progress_messages()
    refute File.exists?(Path.join([dir, "slides", "audio.part"]))
  end

  test "retries a refused sound later while more attempts follow", %{tmp_dir: dir} do
    # A silent video would be re-sent for every later request of the link.
    stub_cdn(audio: &Plug.Conn.send_resp(&1, 403, "Forbidden"))

    assert {:error,
            %Error{kind: :transient, message: "Could not download the slideshow sound (HTTP 403)"}} =
             download(post(2), dir, final_attempt: false)

    refute File.exists?(Path.join([dir, "slides", "audio.part"]))

    stub_cdn(audio: &bytes(&1, ""))

    assert {:error,
            %Error{
              kind: :transient,
              message: "Could not download the slideshow sound (empty response)"
            }} = download(post(2), Path.join(dir, "empty"), final_attempt: false)
  end

  test "keeps the maximum duration for assembling the video", %{tmp_dir: dir} do
    stub_cdn()

    assert {:ok, %Download{max_duration: 60}} =
             download(post(2, audio_url: ""), dir, max_duration: 60)

    assert {:ok, %Download{max_duration: nil}} =
             download(post(2, audio_url: ""), Path.join(dir, "default"))
  end

  test "retries later when the sound fails for network reasons", %{tmp_dir: dir} do
    stub_cdn(audio: &Plug.Conn.send_resp(&1, 502, ""))

    assert {:error,
            %Error{kind: :transient, message: "Could not download the slideshow sound (HTTP 502)"}} =
             download(post(2), dir)
  end

  test "Sound.extension/1 names the sound after ffprobe's format" do
    assert Sound.extension("mp3") == ".mp3"
    assert Sound.extension("mov,mp4,m4a,3gp,3g2,mj2") == ".m4a"
    assert Sound.extension("ogg") == ""
    assert Sound.extension(nil) == ""
  end

  describe "with ffprobe" do
    @describetag :external

    defp sound!(dir, name, args) do
      path = Path.join(dir, name)
      input = ~w(-hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=4)
      {output, status} = System.cmd("ffmpeg", input ++ args ++ [path], stderr_to_stdout: true)

      assert status == 0, output
      File.read!(path)
    end

    test "names the sound after its container, not the content type", %{tmp_dir: dir} do
      mp3 = sound!(dir, "in.mp3", ~w(-c:a libmp3lame -b:a 64k))
      stub_cdn(audio: &bytes(&1, mp3, "video/mp4"))

      assert {:ok, %Download{audio_path: path, duration: duration, size: size}} =
               download(post(2), Path.join(dir, "a"))

      assert Path.basename(path) == "audio.mp3"
      assert File.read!(path) == mp3
      assert_in_delta duration, 4.0, 0.1
      assert size == byte_size(mp3) + byte_size("image 1") + byte_size("image 2")

      m4a = sound!(dir, "in.m4a", ~w(-c:a aac -b:a 64k))
      stub_cdn(audio: &bytes(&1, m4a, "audio/mpeg"))

      assert {:ok, %Download{audio_path: path}} = download(post(2), Path.join(dir, "b"))
      assert Path.basename(path) == "audio.m4a"
    end

    test "leaves out a sound that is not media on the final attempt", %{tmp_dir: dir} do
      stub_cdn(audio: &bytes(&1, "<html>blocked</html>", "text/html"))

      assert {:ok, %Download{audio_path: nil, duration: nil}} = download(post(2), dir)
      assert dir |> Path.join("slides") |> File.ls!() |> Enum.sort() == ["01.jpg", "02.jpg"]

      retried = Path.join(dir, "retried")

      assert {:error,
              %Error{
                kind: :transient,
                message: "Could not use the slideshow sound (it is not a media file)"
              }} = download(post(2), retried, final_attempt: false)

      assert retried |> Path.join("slides") |> File.ls!() |> Enum.sort() == ["01.jpg", "02.jpg"]
    end
  end
end
