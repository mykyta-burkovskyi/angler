defmodule Angler.Media.Slideshow.SoundTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Angler.Media.Error
  alias Angler.Media.Slideshow.Sound

  @moduletag :tmp_dir
  @moduletag :capture_log

  @url "https://scontent-iev1-1.xx.fbcdn.net/o1/v/t2/f2/m69/song.mp4?efg=x&oh=00_sig"

  defp source(opts \\ []) do
    %{
      url: Keyword.get(opts, :url, @url),
      duration: Keyword.get(opts, :duration, 140.586),
      window: Keyword.get(opts, :window, {1.5, 90.0})
    }
  end

  # A `:fetch` that reports its call, writes `body` to the path and returns `result`.
  defp fetch(result, body \\ "partial song") do
    test = self()

    fn url, path, opts ->
      send(test, {:fetch, url, path, opts})
      File.write!(path, body)
      result
    end
  end

  defp download(source, dir, opts) do
    test = self()
    Sound.download(source, dir, Keyword.put_new(opts, :on_progress, &send(test, {:progress, &1})))
  end

  defp progress_messages do
    receive do
      {:progress, progress} -> [progress | progress_messages()]
    after
      0 -> []
    end
  end

  test "a source without a URL is silent and fetches nothing", %{tmp_dir: dir} do
    assert {:ok, %{path: nil, bytes: 0, duration: nil}} =
             download(source(url: nil), dir, fetch: fetch({:ok, 1}))

    refute_received {:fetch, _url, _path, _opts}
    assert progress_messages() == []
  end

  test "fetches the song into audio.part within the size limit", %{tmp_dir: dir} do
    refused = fetch({:error, {:http, 403}})
    part = Path.join(dir, "audio.part")

    assert {:ok, %{path: nil}} = download(source(), dir, fetch: refused)
    assert_received {:fetch, @url, ^part, [max_bytes: 50_000_000]}
    assert progress_messages() == [%{percent: nil, detail: "Downloading sound"}]

    assert {:ok, %{path: nil}} = download(source(), dir, fetch: refused, budget: 1_000_000)
    assert_received {:fetch, @url, ^part, [max_bytes: 1_000_000]}

    assert {:ok, %{path: nil}} = download(source(), dir, fetch: refused, budget: -5)
    assert_received {:fetch, @url, ^part, [max_bytes: 0]}
  end

  test "retries a refused song later while more attempts follow", %{tmp_dir: dir} do
    assert {:error,
            %Error{kind: :transient, message: "Could not download the slideshow sound (HTTP 403)"}} =
             download(source(), dir, fetch: fetch({:error, {:http, 403}}), final_attempt: false)

    assert File.ls!(dir) == []

    assert {:error,
            %Error{
              kind: :transient,
              message: "Could not download the slideshow sound (evil.test is not an allowed host)"
            }} =
             download(source(), dir,
               fetch: fetch({:error, {:host_not_allowed, "evil.test"}}),
               final_attempt: false
             )

    assert File.ls!(dir) == []
  end

  test "leaves out a song refused on the final attempt", %{tmp_dir: dir} do
    log =
      capture_log(fn ->
        assert {:ok, %{path: nil, bytes: 0, duration: nil}} =
                 download(source(), dir, fetch: fetch({:error, {:http, 403}}))
      end)

    assert log =~ "Leaving out the slideshow sound: HTTP 403"
    refute log =~ "oh=00_sig"
    assert File.ls!(dir) == []

    assert {:ok, %{path: nil}} =
             download(source(), dir, fetch: fetch({:error, {:host_not_allowed, "evil.test"}}))

    assert {:ok, %{path: nil}} = download(source(), dir, fetch: fetch({:error, :empty}))
    assert File.ls!(dir) == []
  end

  test "network trouble fails with :transient, even on the final attempt", %{tmp_dir: dir} do
    for {reason, described} <- [
          {{:http, 502}, "HTTP 502"},
          {{:http, 408}, "HTTP 408"},
          {{:network, "socket closed"}, "socket closed"},
          {:timeout, "took too long"}
        ] do
      assert {:error, %Error{kind: :transient, message: message}} =
               download(source(), dir, fetch: fetch({:error, reason}), final_attempt: true)

      assert message == "Could not download the slideshow sound (#{described})"
      assert File.ls!(dir) == []
    end
  end

  test "a song over the source limit is too large, one over 50 MB is left out",
       %{tmp_dir: dir} do
    too_large = fetch({:error, :too_large})

    assert {:error, %Error{kind: :too_large, message: "This slideshow is larger than 1 MB"}} =
             download(source(), dir, fetch: too_large, budget: 1_000_000)

    assert File.ls!(dir) == []

    for final? <- [true, false] do
      assert {:ok, %{path: nil}} =
               download(source(), dir, fetch: too_large, final_attempt: final?)

      assert File.ls!(dir) == []
    end
  end

  test "a failed write is an internal error", %{tmp_dir: dir} do
    assert {:error, %Error{kind: :internal, message: "could not write the file: " <> _}} =
             download(source(), dir, fetch: fetch({:error, {:write, :enospc}}))
  end

  describe "with ffmpeg" do
    @describetag :external

    # 10 s of silence, then a 440 Hz tone from exactly 5 s.
    @tone_at_5 "aevalsrc=if(gte(t\\,5)\\,sin(2*PI*440*t)\\,0):s=44100:d=10"
    @tone "sine=frequency=440:sample_rate=44100:duration=10"

    defp ffmpeg!(args) do
      {output, status} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args, stderr_to_stdout: true)

      assert status == 0, output
    end

    defp song!(dir, name, args \\ ~w(-c:a aac), source \\ @tone_at_5) do
      path = Path.join(dir, name)
      ffmpeg!(["-f", "lavfi", "-i", source] ++ args ++ [path])
      path
    end

    # A `:fetch` that copies the file at `path`, as a CDN would serve it.
    defp serve(path) do
      fn _url, part, _opts ->
        File.cp!(path, part)
        {:ok, File.stat!(part).size}
      end
    end

    for {name, codec} <- [{"song.m4a", "aac"}, {"song.mp3", "libmp3lame"}] do
      test "cuts the post's clip out of #{name}", %{tmp_dir: dir} do
        song = song!(dir, unquote(name), ["-c:a", unquote(codec)])
        sound = Path.join(dir, "sound")
        File.mkdir_p!(sound)

        assert {:ok, %{path: path, bytes: bytes, duration: duration}} =
                 download(source(duration: 10.0, window: {2.0, 3.0}), sound, fetch: serve(song))

        assert path == Path.join(sound, "clip.flac")
        assert bytes == File.stat!(song).size
        assert_in_delta duration, 3.0, 0.001
        # the downloaded song is gone
        assert File.ls!(sound) == ["clip.flac"]

        assert progress_messages() == [
                 %{percent: nil, detail: "Downloading sound"},
                 %{percent: nil, detail: "Preparing sound"}
               ]
      end
    end

    test "keeps a clip that is the whole song, and a sound without a window",
         %{tmp_dir: dir} do
      song = song!(dir, "song.m4a")

      for {window, n} <- Enum.with_index([{0.0, nil}, {0.0, 30.0}, nil]) do
        sound = Path.join(dir, "sound-#{n}")
        File.mkdir_p!(sound)

        assert {:ok, %{path: path, duration: duration}} =
                 download(source(duration: 10.0, window: window), sound, fetch: serve(song))

        assert path == Path.join(sound, "audio.m4a")
        assert File.read!(path) == File.read!(song)
        assert_in_delta duration, 10.0, 0.05
        assert File.ls!(sound) == ["audio.m4a"]
        refute %{percent: nil, detail: "Preparing sound"} in progress_messages()
      end
    end

    test "a song that can not be cut is unusable", %{tmp_dir: dir} do
      # The index says 10 s, but the file breaks off after about 3 s: the clip is empty.
      song = song!(dir, "whole.m4a", ~w(-c:a aac -movflags +faststart), @tone)
      truncated = Path.join(dir, "song.m4a")
      bytes = File.read!(song)
      File.write!(truncated, binary_part(bytes, 0, div(byte_size(bytes) * 3, 10)))
      sound = Path.join(dir, "sound")
      File.mkdir_p!(sound)
      source = source(duration: 10.0, window: {5.0, 3.0})

      assert {:error,
              %Error{
                kind: :transient,
                message: "Could not use the slideshow sound (it could not be cut)"
              }} = download(source, sound, fetch: serve(truncated), final_attempt: false)

      assert File.ls!(sound) == []

      log =
        capture_log(fn ->
          assert {:ok, %{path: nil, bytes: 0, duration: nil}} =
                   download(source, sound, fetch: serve(truncated), final_attempt: true)
        end)

      assert log =~ "Could not cut the slideshow sound: the cut sound is shorter than 1 s"
      assert log =~ "Leaving out the slideshow sound, it is unusable: it could not be cut"
      assert File.ls!(sound) == []
    end

    test "a song that is not audio is unusable", %{tmp_dir: dir} do
      page = Path.join(dir, "page.html")
      File.write!(page, "<html>blocked</html>")
      video = Path.join(dir, "video.mp4")
      ffmpeg!(~w(-f lavfi -i testsrc2=s=64x64:d=2 -c:v mpeg4) ++ [video])
      sound = Path.join(dir, "sound")
      File.mkdir_p!(sound)

      for {file, reason} <- [{page, "it is not a media file"}, {video, "it has no audio stream"}] do
        message = "Could not use the slideshow sound (#{reason})"

        assert {:error, %Error{kind: :transient, message: ^message}} =
                 download(source(), sound, fetch: serve(file), final_attempt: false)

        assert File.ls!(sound) == []

        assert {:ok, %{path: nil}} =
                 download(source(), sound, fetch: serve(file), final_attempt: true)

        assert File.ls!(sound) == []
      end
    end
  end
end
