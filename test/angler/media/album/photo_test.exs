defmodule Angler.Media.Album.PhotoTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Album.Photo

  # The first 380 bytes (up to the image data) of a progressive 1080x1440 JPEG
  # from Instagram's CDN: JFIF, Photoshop IRB, two DQT, SOF2, two DHT, SOS.
  @instagram_head Base.decode64!("""
                  /9j/4AAQSkZJRgABAQAAAQABAAD/7QB8UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAGAcAigAWkZCTUQyMzAwMDk2\
                  YzAxMDAwMDg0NzcwMDAwYTRiNTAwMDAyYWU4MDAwMGRiZjIwMTAwMjA3NDAyMDA2ZWUzMDIwMDcwODUwMzAwYjMw\
                  YzA0MDA2MmJjMDQwMAD/2wBDAAQEBAQEBAYEBAYJBgYGCQwJCQkJDA8MDAwMDA8SDw8PDw8PEhISEhISEhIVFRUV\
                  FRUZGRkZGRwcHBwcHBwcHBz/2wBDAQQFBQcHBwwHBwwdFBAUHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0d\
                  HR0dHR0dHR0dHR0dHR0dHR0dHR3/wgARCAWgBDgDASIAAhEBAxEB/8QAHQAAAAcBAQEAAAAAAAAAAAAAAQIDBAUG\
                  BwAICf/EABwBAAEFAQEBAAAAAAAAAAAAAAABAgMEBQYHCP/aAAwDAQACEAMQAAAAxaI=\
                  """)

  @soi <<0xFF, 0xD8>>
  @app0 <<0xFF, 0xE0, 16::16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>
  @dht <<0xFF, 0xC4, 5::16, 0, 1, 2>>
  @sos <<0xFF, 0xDA, 8::16, 1, 1, 0, 0, 63, 0>>

  defp sof(marker, width, height),
    do: <<0xFF, marker, 11::16, 8, height::16, width::16, 1, 1, 0x11, 0>>

  defp jpeg(segments), do: IO.iodata_to_binary([@soi, segments, @sos, "data", 0xFF, 0xD9])

  defp png(width, height) do
    <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", width::32, height::32, 8, 2, 0, 0, 0, 0::32>>
  end

  defp webp(chunk), do: <<"RIFF", byte_size(chunk) + 4::little-32, "WEBP", chunk::binary>>

  describe "identify/1" do
    test "reads the frame header of the Instagram CDN's progressive JPEGs" do
      assert Photo.identify(@instagram_head) == {:ok, %{format: :jpeg, width: 1080, height: 1440}}
    end

    test "reads baseline, progressive and other frame headers after other segments" do
      for marker <- [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCF] do
        assert Photo.identify(jpeg([@app0, @dht, sof(marker, 640, 480)])) ==
                 {:ok, %{format: :jpeg, width: 640, height: 480}}
      end
    end

    test "skips fill bytes and markers without a length" do
      data = jpeg([@app0, <<0xFF, 0xFF, 0xFF>>, <<0xFF, 0xD0>>, sof(0xC0, 20, 10)])
      assert Photo.identify(data) == {:ok, %{format: :jpeg, width: 20, height: 10}}
    end

    test "does not take DHT, JPG or DAC segments for a frame header" do
      for marker <- [0xC4, 0xC8, 0xCC] do
        fake_sof = <<0xFF, marker, 11::16, 8, 100::16, 200::16, 1, 1, 0x11, 0>>
        assert Photo.identify(jpeg([fake_sof])) == :error
        assert {:ok, %{width: 5}} = Photo.identify(jpeg([fake_sof, sof(0xC0, 5, 5)]))
      end
    end

    test "gives up on broken JPEGs" do
      # Image data or the end before a frame header.
      assert Photo.identify(jpeg([@app0])) == :error
      assert Photo.identify(@soi <> <<0xFF, 0xD9>>) == :error
      # Truncated inside a segment, or inside the frame header.
      assert Photo.identify(@soi <> binary_part(@app0, 0, 10)) == :error
      assert Photo.identify(@soi <> binary_part(sof(0xC2, 10, 10), 0, 8)) == :error
      # Segment lengths that would not move forward.
      assert Photo.identify(@soi <> <<0xFF, 0xE1, 0::16>> <> sof(0xC0, 5, 5)) == :error
      assert Photo.identify(@soi <> <<0xFF, 0xE1, 1::16>> <> sof(0xC0, 5, 5)) == :error
      # Something else where a marker should be.
      assert Photo.identify(@soi <> "garbage" <> sof(0xC0, 5, 5)) == :error
      # No pixels.
      assert Photo.identify(jpeg([sof(0xC0, 0, 480)])) == :error
      assert Photo.identify(jpeg([sof(0xC0, 640, 0)])) == :error
    end

    test "stops after a bounded number of segments" do
      empty_segments = List.duplicate(<<0xFF, 0xFE, 2::16>>, 600)
      assert Photo.identify(jpeg([empty_segments, sof(0xC0, 5, 5)])) == :error

      few = List.duplicate(<<0xFF, 0xFE, 2::16>>, 100)
      assert {:ok, %{width: 5}} = Photo.identify(jpeg([few, sof(0xC0, 5, 5)]))
    end

    test "reads PNG headers" do
      assert Photo.identify(png(1080, 1350)) == {:ok, %{format: :png, width: 1080, height: 1350}}
      assert Photo.identify(png(0, 1350)) == :error
      assert Photo.identify(binary_part(png(1080, 1350), 0, 20)) == :error
    end

    test "reads lossy, lossless and extended WebP headers" do
      vp8 = <<"VP8 ", 10::little-32, 0::24, 0x9D, 0x01, 0x2A>>

      assert Photo.identify(webp(vp8 <> <<1080::little-16, 1350::little-16>>)) ==
               {:ok, %{format: :webp, width: 1080, height: 1350}}

      # The top two bits are the upscaling factor.
      assert Photo.identify(webp(vp8 <> <<0x4000 + 300::little-16, 0xC000 + 200::little-16>>)) ==
               {:ok, %{format: :webp, width: 300, height: 200}}

      vp8l_bits = 1079 + Bitwise.bsl(1349, 14)

      assert Photo.identify(webp(<<"VP8L", 5::little-32, 0x2F, vp8l_bits::little-32>>)) ==
               {:ok, %{format: :webp, width: 1080, height: 1350}}

      assert Photo.identify(
               webp(<<"VP8X", 10::little-32, 0x10, 0::24, 3999::little-24, 2999::little-24>>)
             ) == {:ok, %{format: :webp, width: 4000, height: 3000}}

      assert Photo.identify(webp(<<"VP8 ", 10::little-32, 0, 0, 0, 1, 2, 3>>)) == :error
      assert Photo.identify(webp(<<"VP8L", 5::little-32, 0x00, 0::32>>)) == :error
      assert Photo.identify(webp("ALPH")) == :error
    end

    test "rejects other formats and never raises" do
      for data <- ["", "GIF89a...", "<!DOCTYPE html><html>", <<0xFF>>, <<0xFF, 0xD8>>, "RIFF"] do
        assert Photo.identify(data) == :error
      end

      :rand.seed(:exsss, {1, 2, 3})

      for _n <- 1..2_000 do
        noise = :rand.bytes(:rand.uniform(64))
        prefix = Enum.random([@soi, @soi <> <<0xFF>>, <<0x89, "PNG\r\n", 0x1A, "\n">>, "RIFF"])
        data = prefix <> noise

        assert match?({:ok, %{width: w, height: h}} when w > 0 and h > 0, Photo.identify(data)) or
                 Photo.identify(data) == :error
      end
    end
  end

  describe "read/1" do
    @describetag :tmp_dir

    test "reads the start of a file", %{tmp_dir: dir} do
      path = Path.join(dir, "photo")
      File.write!(path, [@instagram_head, :binary.copy(<<0>>, 1_000_000)])
      assert Photo.read(path) == {:ok, %{format: :jpeg, width: 1080, height: 1440}}

      assert Photo.read(Path.join(dir, "missing")) == :error
    end

    test "gives up when the frame header lies beyond the first 512 KB", %{tmp_dir: dir} do
      comment = <<0xFF, 0xFE, 65_535::16, :binary.copy("x", 65_533)::binary>>
      path = Path.join(dir, "photo")

      File.write!(path, jpeg([List.duplicate(comment, 7), sof(0xC0, 5, 5)]))
      assert {:ok, %{width: 5}} = Photo.read(path)

      File.write!(path, jpeg([List.duplicate(comment, 9), sof(0xC0, 5, 5)]))
      assert Photo.read(path) == :error
    end
  end

  test "check/3 applies Telegram's photo limits" do
    photo = %{format: :jpeg, width: 3277, height: 4096}

    assert Photo.check(photo, 1_970_000) == :ok
    assert Photo.check(photo, 10_000_000) == :ok
    assert Photo.check(photo, 10_000_001) == {:error, "larger than 10 MB"}
    assert Photo.check(photo, 2_000_000, 1_500_000) == {:error, "larger than 1.5 MB"}
    assert Photo.check(photo, 2_000_000, 50_000_000) == :ok

    assert Photo.check(%{photo | width: 5000, height: 5000}, 1) == :ok

    assert Photo.check(%{photo | width: 5001, height: 5000}, 1) ==
             {:error, "5001x5000 pixels is too large"}

    assert Photo.check(%{photo | width: 2000, height: 100}, 1) == :ok

    assert Photo.check(%{photo | width: 100, height: 2001}, 1) ==
             {:error, "100x2001 is too narrow"}
  end

  test "extension/1" do
    assert Enum.map([:jpeg, :png, :webp], &Photo.extension/1) == ["jpg", "png", "webp"]
  end
end
