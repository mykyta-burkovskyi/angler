defmodule Angler.Media.ProbeTest do
  use ExUnit.Case, async: true

  alias Angler.Media.{Error, Probe}

  @fixtures Path.expand("../../fixtures/media", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  describe "parse/1" do
    test "applies the display matrix rotation of portrait phone videos" do
      probe = Probe.parse(fixture("probe_portrait_rotated.json"))

      assert %Probe{
               has_video?: true,
               video_codec: "h264",
               video_profile: "High",
               pix_fmt: "yuv420p",
               width: 1920,
               height: 1080,
               rotation: -90,
               display_width: 1080,
               display_height: 1920,
               hdr?: false,
               has_audio?: true,
               audio_codec: "aac",
               audio_channels: 2,
               format_name: "mov,mp4,m4a,3gp,3g2,mj2"
             } = probe

      assert_in_delta probe.fps, 29.97, 0.01
      assert_in_delta probe.duration, 1.0, 0.1
      assert is_integer(probe.size) and probe.size > 0
      assert is_integer(probe.video_bit_rate)
    end

    test "falls back to the container for durations and bit rates missing on streams" do
      probe = Probe.parse(fixture("probe_hevc_opus_mkv.json"))

      assert %Probe{
               format_name: "matroska,webm",
               duration: 2.008,
               size: 149_519,
               bit_rate: 595_693,
               video_codec: "hevc",
               video_bit_rate: nil,
               audio_codec: "opus",
               audio_bit_rate: nil,
               fps: 25.0,
               rotation: 0,
               display_width: 640,
               display_height: 360
             } = probe
    end

    test "handles videos without audio" do
      assert %Probe{has_video?: true, has_audio?: false, audio_codec: nil, fps: 60.0} =
               Probe.parse(fixture("probe_no_audio.json"))
    end

    test "skips cover art streams" do
      assert %Probe{video_codec: "h264", width: 1280, height: 720} =
               Probe.parse(fixture("probe_attached_pic.json"))
    end

    test "uses stream durations when the container has none" do
      json = %{
        "format" => %{"format_name" => "h264"},
        "streams" => [%{"codec_type" => "video", "codec_name" => "h264", "duration" => "4.5"}]
      }

      assert %Probe{duration: 4.5} = Probe.parse(json)
    end

    test "detects HDR transfer functions" do
      for {transfer, hdr?} <- [{"smpte2084", true}, {"arib-std-b67", true}, {"bt709", false}] do
        json = %{"streams" => [%{"codec_type" => "video", "color_transfer" => transfer}]}
        assert %Probe{hdr?: ^hdr?} = Probe.parse(json)
      end
    end

    test "swaps dimensions only for quarter turns" do
      for {rotation, dims} <- [
            {90, {720, 1280}},
            {270, {720, 1280}},
            {-270, {720, 1280}},
            {180, {1280, 720}}
          ] do
        json = %{
          "streams" => [
            %{
              "codec_type" => "video",
              "width" => 1280,
              "height" => 720,
              "side_data_list" => [
                %{"side_data_type" => "Display Matrix", "rotation" => rotation}
              ]
            }
          ]
        }

        probe = Probe.parse(json)
        assert {probe.display_width, probe.display_height} == dims
      end
    end

    test "ignores unusable frame rates" do
      for rate <- ["0/0", "0/1", "N/A", nil] do
        json = %{"streams" => [%{"codec_type" => "video", "avg_frame_rate" => rate}]}
        assert %Probe{fps: nil} = Probe.parse(json)
      end
    end

    test "reports files without streams as having no video" do
      assert %Probe{has_video?: false, has_audio?: false, duration: nil} = Probe.parse(%{})
    end
  end

  describe "faststart?/1" do
    @moduletag :tmp_dir

    defp box(type, payload \\ <<0::64>>),
      do: <<byte_size(payload) + 8::32, type::binary, payload::binary>>

    defp large_box(type, payload),
      do: <<1::32, type::binary, byte_size(payload) + 16::64, payload::binary>>

    defp write(dir, name, contents) do
      path = Path.join(dir, name)
      File.write!(path, contents)
      path
    end

    test "is true when moov comes before mdat", %{tmp_dir: dir} do
      assert Probe.faststart?(
               write(dir, "fast.mp4", box("ftyp") <> box("moov") <> box("free") <> box("mdat"))
             )
    end

    test "is false when mdat comes first", %{tmp_dir: dir} do
      refute Probe.faststart?(write(dir, "slow.mp4", box("ftyp") <> box("mdat") <> box("moov")))
    end

    test "follows 64-bit box sizes", %{tmp_dir: dir} do
      assert Probe.faststart?(
               write(dir, "a.mp4", box("ftyp") <> large_box("free", <<0::1024>>) <> box("moov"))
             )

      refute Probe.faststart?(
               write(dir, "b.mp4", box("ftyp") <> large_box("mdat", <<0::1024>>) <> box("moov"))
             )
    end

    test "is false for boxes running to the end of the file", %{tmp_dir: dir} do
      refute Probe.faststart?(write(dir, "eof.mp4", box("ftyp") <> <<0::32, "free", 0::64>>))
    end

    test "is false for truncated, malformed or missing files", %{tmp_dir: dir} do
      refute Probe.faststart?(write(dir, "empty.mp4", ""))
      refute Probe.faststart?(write(dir, "short.mp4", <<0, 0, 0>>))
      refute Probe.faststart?(write(dir, "tiny-box.mp4", <<4::32, "ftyp">> <> box("moov")))
      refute Probe.faststart?(write(dir, "no-moov.mp4", box("ftyp") <> box("free")))
      refute Probe.faststart?(Path.join(dir, "missing.mp4"))
    end
  end

  describe "run/1" do
    @describetag :external
    @describetag :tmp_dir

    defp ffmpeg!(args) do
      {output, status} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args, stderr_to_stdout: true)

      assert status == 0, output
    end

    test "probes a real file and checks fast start", %{tmp_dir: dir} do
      input =
        ~w(-f lavfi -i testsrc2=size=320x240:rate=25 -f lavfi -i sine -t 1 -c:v libx264 -c:a aac)

      fast = Path.join(dir, "fast.mp4")
      slow = Path.join(dir, "slow.mp4")
      ffmpeg!(input ++ ["-movflags", "+faststart", fast])
      ffmpeg!(input ++ [slow])

      assert {:ok, %Probe{path: ^fast, faststart?: true, video_codec: "h264", width: 320} = probe} =
               Probe.run(fast)

      assert probe.size == File.stat!(fast).size
      assert {:ok, %Probe{faststart?: false}} = Probe.run(slow)
    end

    test "reports files that are not media as unsupported", %{tmp_dir: dir} do
      path = Path.join(dir, "garbage.mp4")
      File.write!(path, "<!DOCTYPE html><html><body>Too many requests</body></html>")

      assert {:error, %Error{kind: :unsupported, output: output}} = Probe.run(path)
      assert output =~ "Invalid data"
    end

    test "reports other failures as internal", %{tmp_dir: dir} do
      assert {:error, %Error{kind: :internal}} = Probe.run(Path.join(dir, "missing.mp4"))
    end
  end
end
