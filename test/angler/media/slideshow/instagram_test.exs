defmodule Angler.Media.Slideshow.InstagramTest do
  # Instagram photo posts with music downloaded as slideshows
  # (Angler.Media.Slideshow.download_instagram/4), and as albums when the music
  # can't be used. The post and its music are built here; the CDN is the
  # Req.Test stub of Angler.Media.Instagram.
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures, only: [bytes: 2, bytes: 3, stub_instagram: 1]
  import Angler.InstagramMusicFixtures, only: [song_url: 0]
  import ExUnit.CaptureLog

  alias Angler.Media
  alias Angler.Media.{Download, Error, Output, Slideshow}
  alias Angler.Media.Instagram.{Music, Post}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @cdn "https://scontent.cdninstagram.com/v/t51.82787-15"

  defp photo(n) do
    %{
      type: :photo,
      urls: ["#{@cdn}/photo-#{n}.jpg?oh=00_sig", "#{@cdn}/photo-#{n}_1080.jpg?oh=00_sig"],
      width: 1080,
      height: 1350,
      duration: nil
    }
  end

  defp post do
    %Post{
      code: "DdlJg0lFG8-",
      caption: "Solace",
      username: "someone",
      webpage_url: "https://www.instagram.com/p/DdlJg0lFG8-/",
      items: Enum.map(1..3, &photo/1)
    }
  end

  defp music(opts \\ []) do
    struct!(
      %Music{url: song_url(), duration: 140.586, start: 1.5, clip_duration: 90.0},
      opts
    )
  end

  # Serves the song through `song` and each photo as its name ("photo-1") or
  # through `photo` (called with the conn and the name).
  defp stub_cdn(song, photo \\ &bytes/2) do
    stub_instagram(fn conn ->
      case conn.request_path |> Path.basename() |> Path.rootname() do
        "song" -> song.(conn)
        name -> photo.(conn, name)
      end
    end)
  end

  defp refuse(status), do: &Plug.Conn.send_resp(&1, status, "")

  defp download(dir, opts \\ [], music \\ music()) do
    test = self()
    opts = Keyword.put_new(opts, :on_progress, &send(test, {:progress, &1}))
    Slideshow.download_instagram(post(), music, dir, opts)
  end

  # The requests the stub got, in order: {"host/path", conn}.
  defp requests do
    receive do
      {:instagram_request, "GET", path, conn} -> [{path, conn} | requests()]
    after
      0 -> []
    end
  end

  defp progress_messages do
    receive do
      {:progress, progress} -> [progress | progress_messages()]
    after
      0 -> []
    end
  end

  defp album_dirs(dir), do: dir |> Path.join("album") |> File.ls!() |> Enum.sort()

  test "retries a song the CDN refuses while more attempts follow", %{tmp_dir: dir} do
    stub_cdn(refuse(403))

    assert {:error,
            %Error{kind: :transient, message: "Could not download the slideshow sound (HTTP 403)"}} =
             download(dir, final_attempt: false)

    # The photos first, then the song; nothing carries cookies.
    requests = requests()
    assert length(requests) == 4
    assert {"scontent-iev1-1.xx.fbcdn.net/o1/v/t2/f2/m69/song.mp4", _conn} = List.last(requests)
    for {_path, conn} <- requests, do: assert(Plug.Conn.get_req_header(conn, "cookie") == [])

    assert %{percent: 100.0, detail: "Downloading 3/3"} in progress_messages()
    assert album_dirs(dir) == ["01", "02", "03", "sound"]
    assert dir |> Path.join("album/sound") |> File.ls!() == []
  end

  test "sends the photos as an album when the CDN refuses the song on the final attempt",
       %{tmp_dir: dir} do
    stub_cdn(refuse(403))

    log =
      capture_log(fn ->
        assert {:ok, %Download{kind: :album, items: [_, _, _]} = download} = download(dir)

        assert %Download{
                 path: path,
                 size: 21,
                 title: "Solace",
                 extractor: "Instagram",
                 audio_path: nil,
                 images: []
               } = download

        assert path == Path.join(dir, "album")
      end)

    assert log =~
             "Instagram post DdlJg0lFG8-: its music could not be used, sending its photos as an album"

    refute log =~ "oh=00_sig"
    assert album_dirs(dir) == ["01", "02", "03"]
  end

  test "network trouble with the song is retried, or gives the album on the final attempt",
       %{tmp_dir: dir} do
    stub_cdn(refuse(502))

    assert {:error,
            %Error{kind: :transient, message: "Could not download the slideshow sound (HTTP 502)"}} =
             download(Path.join(dir, "retried"), final_attempt: false)

    log =
      capture_log(fn ->
        assert {:ok, %Download{kind: :album, items: [_, _, _]}} =
                 download(Path.join(dir, "final"), final_attempt: true)
      end)

    assert log =~
             "Instagram post DdlJg0lFG8-: Could not download the slideshow sound (HTTP 502), " <>
               "sending its photos as an album"

    assert album_dirs(Path.join(dir, "final")) == ["01", "02", "03"]
  end

  test "never downloads a song off Instagram's CDN", %{tmp_dir: dir} do
    stub_cdn(fn _conn -> flunk("the song is not on the CDN") end)
    music = music(url: "https://evil.test/private/song.mp4?oh=00_sig")

    log =
      capture_log(fn ->
        assert {:ok, %Download{kind: :album, items: [_, _, _]}} = download(dir, [], music)
      end)

    assert log =~ "Not downloading Instagram media from evil.test"
    refute log =~ "/private/song.mp4"
    refute log =~ "oh=00_sig"
    assert length(requests()) == 3
  end

  test "a song over the source limit gives the album", %{tmp_dir: dir} do
    stub_cdn(&bytes(&1, "a song of more than ten bytes", "audio/mp4"))

    for final? <- [false, true] do
      entry = Path.join(dir, "#{final?}")

      log =
        capture_log(fn ->
          # The photos are 21 bytes, which leaves 10 bytes for the song.
          assert {:ok, %Download{kind: :album, size: 21}} =
                   download(entry, max_source_bytes: 31, final_attempt: final?)
        end)

      assert log =~ "its music does not fit the size limit, sending its photos as an album"
      assert album_dirs(entry) == ["01", "02", "03"]
    end
  end

  test "photos fail as an album's do, before the song is asked for", %{tmp_dir: dir} do
    stub_cdn(fn _conn -> flunk("the song was requested") end, fn conn, _name ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert {:error, %Error{kind: :unavailable, message: "Could not download the Instagram post"}} =
             download(dir)

    assert {:error, %Error{kind: :transient}} =
             download(Path.join(dir, "retried"), final_attempt: false)

    refute Enum.any?(requests(), fn {path, _conn} -> path =~ "song.mp4" end)

    stub_cdn(&bytes(&1, "song"))

    assert {:error, %Error{kind: :too_large, message: "This Instagram post is larger than " <> _}} =
             download(Path.join(dir, "large"), max_source_bytes: 10)
  end

  describe "with ffmpeg" do
    @describetag :external
    @describetag timeout: :timer.minutes(3)

    defp ffmpeg!(args) do
      {output, status} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args, stderr_to_stdout: true)

      assert status == 0, output
    end

    defp ffprobe!(path, entries, stream) do
      {output, 0} =
        System.cmd("ffprobe", [
          "-v",
          "error",
          "-select_streams",
          stream,
          "-show_entries",
          entries,
          "-of",
          "default=nw=1:nk=1",
          path
        ])

      output |> String.trim() |> String.to_float()
    end

    defp song!(path) do
      ffmpeg!(~w(-f lavfi -i sine=frequency=440:sample_rate=44100:duration=10 -c:a aac) ++ [path])
      File.read!(path)
    end

    # Three 1080x1350 JPEGs and a 10 s AAC song (or `song`), served by the stub.
    defp serve_media!(dir, song \\ nil) do
      files = Path.join(dir, "cdn")
      File.mkdir_p!(files)

      photos =
        Map.new(1..3, fn n ->
          path = Path.join(files, "photo-#{n}.jpg")
          ffmpeg!(~w(-f lavfi -i testsrc2=s=1080x1350 -frames:v 1) ++ [path])
          {"photo-#{n}", File.read!(path)}
        end)

      song = song || song!(Path.join(files, "song.m4a"))
      stub_cdn(&bytes(&1, song, "audio/mp4"), &bytes(&1, Map.fetch!(photos, &2)))
      %{photo_bytes: photos |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum(), song: song}
    end

    test "plays the post's clip of the song, looped over the photos", %{tmp_dir: dir} do
      %{photo_bytes: photo_bytes, song: song} = serve_media!(dir)
      entry = Path.join(dir, "entry")
      File.mkdir_p!(entry)
      album = Path.join(entry, "album")

      assert {:ok, %Download{kind: :slideshow} = download} =
               download(entry, [], music(duration: 10.0, start: 2.0, clip_duration: 3.0))

      assert %Download{path: ^album, extractor: "Instagram", title: "Solace", items: []} =
               download

      assert download.images == Enum.map(1..3, &Path.join(album, "0#{&1}/source.jpg"))
      assert download.audio_path == Path.join(album, "sound/clip.flac")
      assert_in_delta download.duration, 3.0, 0.01
      assert download.size == photo_bytes + byte_size(song)
      assert File.ls!(Path.join(album, "sound")) == ["clip.flac"]

      progress = progress_messages()
      assert %{percent: 100.0, detail: "Downloading 3/3"} in progress
      assert %{percent: nil, detail: "Downloading sound"} in progress
      assert %{percent: nil, detail: "Preparing sound"} in progress

      # 3 photos of 3 s each, the 3 s clip plays three times.
      assert {:ok, %Output{duration: 9} = output} =
               Media.prepare(download, entry, target_bytes: 50_000_000)

      assert_in_delta ffprobe!(output.path, "stream=duration", "a:0"), 9.0, 0.05
      assert_in_delta ffprobe!(output.path, "stream=duration", "v:0"), 9.0, 0.05
      refute File.exists?(album)
    end

    test "keeps a clip that is the whole song", %{tmp_dir: dir} do
      serve_media!(dir)

      assert {:ok, %Download{kind: :slideshow, audio_path: path, duration: duration}} =
               download(dir, [], music(duration: 10.0, start: 0.0, clip_duration: nil))

      assert path == Path.join(dir, "album/sound/audio.m4a")
      assert_in_delta duration, 10.0, 0.05
    end

    test "a song that is not media is retried, or gives the album on the final attempt",
         %{tmp_dir: dir} do
      serve_media!(dir, "<html>Not found</html>")

      assert {:error,
              %Error{
                kind: :transient,
                message: "Could not use the slideshow sound (it is not a media file)"
              }} = download(Path.join(dir, "retried"), final_attempt: false)

      final = Path.join(dir, "final")

      assert {:ok, %Download{kind: :album, items: [_, _, _]}} =
               download(final, final_attempt: true)

      assert album_dirs(final) == ["01", "02", "03"]
    end
  end
end
