defmodule Angler.Media.Slideshow.ImagesTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Slideshow.Images

  # Shapes of real ffprobe 9.0.2 output for the probe arguments.
  defp json(streams, frames, groups \\ []),
    do: %{"streams" => streams, "frames" => frames, "stream_groups" => groups}

  describe "parse/1" do
    test "takes the frame dimensions and the alpha channel" do
      assert Images.parse(
               json(
                 [
                   %{
                     "codec_name" => "png",
                     "width" => 1080,
                     "height" => 1350,
                     "pix_fmt" => "rgba"
                   }
                 ],
                 [%{"width" => 1080, "height" => 1350, "pix_fmt" => "rgba"}]
               )
             ) == {:ok, %{width: 1080, height: 1350, label: "v:0", alpha: true}}

      # CMYK JPEGs decode as gbrap (alpha 255): compositing over black is harmless.
      assert {:ok, %{alpha: true}} =
               Images.parse(
                 json([%{"width" => 1080, "height" => 1440, "pix_fmt" => "gbrap"}], [
                   %{"width" => 1080, "height" => 1440}
                 ])
               )

      assert {:ok, %{alpha: false}} =
               Images.parse(
                 json([%{"width" => 1, "height" => 1, "pix_fmt" => "yuvj420p"}], [
                   %{"width" => 1, "height" => 1}
                 ])
               )
    end

    test "swaps the dimensions of frames rotated by EXIF orientation" do
      frame = %{
        "width" => 1440,
        "height" => 1080,
        "side_data_list" => [
          %{"side_data_type" => "3x3 displaymatrix", "rotation" => -90},
          %{"side_data_type" => "EXIF metadata", "size" => 14}
        ]
      }

      assert {:ok, %{width: 1080, height: 1440, label: "v:0"}} =
               Images.parse(json([%{"width" => 1440, "height" => 1080}], [frame]))

      upside_down = put_in(frame, ["side_data_list", Access.at(0), "rotation"], 180)

      assert {:ok, %{width: 1440, height: 1080}} =
               Images.parse(json([%{"width" => 1440, "height" => 1080}], [upside_down]))
    end

    test "reads HEIC/AVIF tile grids as a whole" do
      groups = [%{"type" => "Tile Grid", "components" => [%{"width" => 1080, "height" => 1440}]}]

      assert Images.parse(
               json(
                 [
                   %{
                     "codec_name" => "hevc",
                     "width" => 512,
                     "height" => 512,
                     "pix_fmt" => "yuvj420p"
                   }
                 ],
                 [%{"width" => 512, "height" => 512}],
                 groups
               )
             ) == {:ok, %{width: 1080, height: 1440, label: "g:0", alpha: false}}
    end

    test "skips truncated, garbage and oversized images" do
      # Truncated and garbage JPEGs: a stream with 0x0 and no frame.
      assert {:skip, "no decodable picture"} =
               Images.parse(json([%{"codec_name" => "mjpeg", "width" => 0, "height" => 0}], []))

      assert {:skip, "no picture"} = Images.parse(json([], []))
      assert {:skip, "no picture"} = Images.parse(%{})

      assert {:skip, "8000x8001 is larger than 64 megapixels"} =
               Images.parse(
                 json([%{"width" => 8000, "height" => 8001}], [
                   %{"width" => 8000, "height" => 8001}
                 ])
               )

      assert {:ok, %{width: 8000, height: 8000}} =
               Images.parse(
                 json([%{"width" => 8000, "height" => 8000}], [
                   %{"width" => 8000, "height" => 8000}
                 ])
               )
    end

    test "falls back to the stream when no frame was decoded" do
      assert {:ok, %{width: 640, height: 480}} =
               Images.parse(json([%{"width" => 640, "height" => 480}], []))
    end
  end

  describe "probe/1" do
    @describetag :external
    @describetag :tmp_dir

    defp ffmpeg!(args) do
      {output, status} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args, stderr_to_stdout: true)

      assert status == 0, output
    end

    test "probes images in order and skips unreadable ones", %{tmp_dir: dir} do
      portrait = Path.join(dir, "01.jpg")
      alpha = Path.join(dir, "02.jpg")
      truncated = Path.join(dir, "03.jpg")
      garbage = Path.join(dir, "04.jpg")
      missing = Path.join(dir, "05.jpg")

      ffmpeg!(
        ~w(-f lavfi -i testsrc2=size=722x1280 -vf scale=721:1279 -pix_fmt yuvj444p -frames:v 1) ++
          [portrait]
      )

      # PNG bytes under a .jpg name: probed by content.
      ffmpeg!(
        ~w(-f lavfi -i color=c=red@0.5:size=300x200,format=rgba -frames:v 1 -f image2 -c:v png) ++
          [alpha]
      )

      File.write!(truncated, binary_part(File.read!(portrait), 0, 600))
      File.write!(garbage, "not an image")

      assert {:ok, [first, second]} = Images.probe([portrait, alpha, truncated, garbage, missing])
      assert first == %{path: portrait, width: 721, height: 1279, label: "v:0", alpha: false}
      assert second == %{path: alpha, width: 300, height: 200, label: "v:0", alpha: true}
    end
  end
end
