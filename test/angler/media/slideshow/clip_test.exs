defmodule Angler.Media.Slideshow.ClipTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Error
  alias Angler.Media.Slideshow.Clip

  describe "window/2" do
    for {duration, window, expected} <- [
          # the recorded post: 90 s of "Solace" from 1.5 s, the song measured by ffprobe
          {140.70, {1.5, 90.0}, %{start: 1.5, stop: 91.5, fade: 1.0}},
          # the whole song
          {60.0, {0.0, nil}, :whole},
          {60.0, {0.0, 90.0}, :whole},
          {60.0, {0.04, 59.97}, :whole},
          # a clip that ends the song needs no fade
          {60.0, {30.0, 90.0}, %{start: 30.0, stop: 60.0, fade: nil}},
          # a start outside this file (another edit of the song) plays from 0
          {60.0, {59.5, 10.0}, %{start: 0.0, stop: 10.0, fade: 1.0}},
          {60.0, {-5.0, 10.0}, %{start: 0.0, stop: 10.0, fade: 1.0}},
          # a clip under 1 s means the rest of the song
          {60.0, {5.0, 0.5}, %{start: 5.0, stop: 60.0, fade: nil}},
          # at most 120 s
          {300.0, {0.0, nil}, %{start: 0.0, stop: 120.0, fade: 1.0}},
          {300.0, {10.0, 200.0}, %{start: 10.0, stop: 130.0, fade: 1.0}},
          # an unknown duration never gives the whole song
          {nil, {1.5, 90.0}, %{start: 1.5, stop: 91.5, fade: 1.0}},
          {nil, {0.0, nil}, %{start: 0.0, stop: 120.0, fade: 1.0}},
          # short clips fade over a quarter of their length
          {3.0, {0.5, 2.0}, %{start: 0.5, stop: 2.5, fade: 0.5}},
          # numbers of other types, or none
          {60, {2, 10}, %{start: 2.0, stop: 12.0, fade: 1.0}},
          {60.0, {nil, "10"}, :whole}
        ] do
      test "#{inspect(duration)}, #{inspect(window)} -> #{inspect(expected)}" do
        assert Clip.window(unquote(duration), unquote(Macro.escape(window))) ==
                 unquote(Macro.escape(expected))
      end
    end

    test "every cut is at least 1 s long and within the song" do
      for duration <- [nil, 1.0, 3.0, 60.0, 140.7, 300.0],
          start <- [-1.0, 0.0, 0.03, 1.5, 58.9, 59.0, 59.5, 139.0, 200.0],
          clip <- [nil, 0.5, 1.0, 10.0, 90.0, 500.0] do
        case Clip.window(duration, {start, clip}) do
          :whole ->
            assert duration

          %{start: from, stop: to, fade: fade} ->
            assert from >= 0.0 and to - from >= 1.0 - 1.0e-9 and to - from <= 120.0
            if duration, do: assert(to <= duration)
            assert fade == nil or (fade > 0 and fade <= 1.0 and fade <= (to - from) / 4)
        end
      end
    end
  end

  describe "with ffmpeg" do
    @describetag :external
    @describetag :tmp_dir

    # 10 s of silence, then a 440 Hz tone from exactly 5 s.
    @tone_at_5 "aevalsrc=if(gte(t\\,5)\\,sin(2*PI*440*t)\\,0):s=44100:d=10"

    defp ffmpeg!(args) do
      {output, status} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args, stderr_to_stdout: true)

      assert status == 0, output
    end

    defp song!(dir, name, codec) do
      path = Path.join(dir, name)
      ffmpeg!(["-f", "lavfi", "-i", @tone_at_5, "-c:a", codec, path])
      path
    end

    # volumedetect's mean and max volume (dB) of `path` between `from` and `to` seconds.
    defp volume(path, from, to) do
      filter = "atrim=start=#{from}:end=#{to},volumedetect"

      {output, 0} =
        System.cmd(
          "ffmpeg",
          ["-hide_banner", "-nostdin", "-i", path, "-af", filter, "-f", "null", "-"],
          stderr_to_stdout: true
        )

      [mean] = Regex.run(~r/mean_volume: (-?[\d.]+) dB/, output, capture: :all_but_first)
      [max] = Regex.run(~r/max_volume: (-?[\d.]+) dB/, output, capture: :all_but_first)
      %{mean: String.to_float(mean), max: String.to_float(max)}
    end

    for {name, codec} <- [{"song.m4a", "aac"}, {"song.mp3", "libmp3lame"}] do
      test "cuts #{name} sample exactly", %{tmp_dir: dir} do
        song = song!(dir, unquote(name), unquote(codec))
        out = Path.join(dir, "clip.flac")

        # starts right on the tone
        assert {:ok, seconds} = Clip.cut(song, %{start: 5.0, stop: 9.0, fade: nil}, out)
        assert_in_delta seconds, 4.0, 0.001
        assert volume(out, 0, 0.05).mean > -30

        # ends 0.1 s into the tone: the first 90 ms are silent
        assert {:ok, seconds} = Clip.cut(song, %{start: 4.9, stop: 5.9, fade: nil}, out)
        assert_in_delta seconds, 1.0, 0.001
        assert volume(out, 0, 0.09).max < -60
        assert volume(out, 0.5, 0.9).mean > -30
      end

      test "fades out the end of a clip of #{name}", %{tmp_dir: dir} do
        song = song!(dir, unquote(name), unquote(codec))
        out = Path.join(dir, "clip.flac")

        assert {:ok, seconds} = Clip.cut(song, %{start: 5.0, stop: 9.0, fade: 1.0}, out)
        assert_in_delta seconds, 4.0, 0.001
        assert volume(out, 3.9, 4.0).mean <= volume(out, 1.0, 2.0).mean - 15
      end
    end

    # The FLAC block sizes (samples per frame) of `path`.
    defp blocks(path) do
      {output, 0} =
        System.cmd("ffprobe", ~w(-v error -show_entries frame=nb_samples -of csv=p=0) ++ [path])

      output |> String.split() |> Enum.map(&String.to_integer/1)
    end

    # Starts after which the first frame out of atrim is only a few samples long
    # (with ffmpeg 9.0.2 and these songs): the FLAC encoder took that as its block
    # size and refused it ("invalid block size"); a slightly longer one gave tiny
    # blocks and a much larger file.
    for {name, codec, starts} <- [
          {"song.m4a", "aac", [1.068, 1.091, 1.184, 1.277, 1.3]},
          {"song.mp3", "libmp3lame", [1.072, 1.098, 1.124, 1.281]}
        ] do
      test "cuts #{name} at any start, in blocks of 4096 samples", %{tmp_dir: dir} do
        song = song!(dir, unquote(name), unquote(codec))
        out = Path.join(dir, "clip.flac")

        for start <- unquote(starts) ++ [1.1] do
          assert {:ok, seconds} =
                   Clip.cut(song, %{start: start, stop: start + 2.0, fade: 0.5}, out)

          assert_in_delta seconds, 2.0, 0.001
          # 2 s at 44.1 kHz: 21 blocks of 4096 samples, then the rest
          assert [4096 | _] = blocks = blocks(out)
          assert length(blocks) == 22
          assert blocks |> Enum.drop(-1) |> Enum.all?(&(&1 == 4096))
        end
      end
    end

    test "fails on a clip under 1 s and on files that are not audio", %{tmp_dir: dir} do
      song = song!(dir, "song.m4a", "aac")
      out = Path.join(dir, "clip.flac")

      assert {:failed, %Error{message: "the cut sound is shorter than 1 s"}} =
               Clip.cut(song, %{start: 5.0, stop: 5.5, fade: nil}, out)

      # a window past the end of the file gives an empty clip
      assert {:failed, %Error{message: "the cut sound is shorter than 1 s"}} =
               Clip.cut(song, %{start: 20.0, stop: 30.0, fade: nil}, out)

      page = Path.join(dir, "page.html")
      File.write!(page, "<html>blocked</html>")

      assert {:failed, %Error{kind: :internal, message: "ffmpeg failed" <> _}} =
               Clip.cut(page, %{start: 0.0, stop: 2.0, fade: nil}, out)

      video = Path.join(dir, "video.mp4")
      ffmpeg!(~w(-f lavfi -i testsrc2=s=64x64:d=2 -c:v mpeg4) ++ [video])
      assert {:failed, %Error{}} = Clip.cut(video, %{start: 0.0, stop: 2.0, fade: nil}, out)
    end
  end
end
