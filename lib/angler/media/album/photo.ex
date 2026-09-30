defmodule Angler.Media.Album.Photo do
  @moduledoc """
  Recognizes album photos without external tools: the format from the magic bytes
  (JPEG, PNG or WebP) and the pixel dimensions from the header, then Telegram's
  photo limits (`check/2`).

  The parsers never raise and give up (`:error`) on anything unexpected. They
  only read the first 512 KB of a file: JPEG headers (EXIF, ICC profiles, the
  Ultra HDR metadata Instagram adds) are far smaller, and the scan for the frame
  header (`SOFn`, baseline and progressive alike) always moves forward and stops
  after a bounded number of segments. The EXIF orientation is not applied:
  Telegram's limits don't depend on it, and Instagram photos carry none.
  """
  alias Angler.Media

  @read_bytes 512 * 1024
  @max_segments 512
  @max_bytes 10_000_000
  @max_sides 10_000
  @max_ratio 20

  @type format :: :jpeg | :png | :webp
  @type info :: %{format: format(), width: pos_integer(), height: pos_integer()}

  @doc "Reads the format and dimensions of the image file at `path`."
  @spec read(Path.t()) :: {:ok, info()} | :error
  def read(path) do
    case File.open(path, [:read, :binary, :raw], &:file.read(&1, @read_bytes)) do
      {:ok, {:ok, head}} -> identify(head)
      _other -> :error
    end
  end

  @doc """
  The format and dimensions of an image from the start of its file (`head`, the
  first bytes, at least up to the frame header).
  """
  @spec identify(binary()) :: {:ok, info()} | :error
  def identify(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest, @max_segments)

  def identify(
        <<0x89, "PNG\r\n", 0x1A, "\n", _length::32, "IHDR", width::32, height::32, _::binary>>
      ),
      do: info(:png, width, height)

  def identify(<<"RIFF", _size::little-32, "WEBP", chunk::binary>>), do: webp(chunk)
  def identify(_head), do: :error

  @doc """
  Whether Telegram accepts the photo (`info` from `read/1`, `bytes` its file
  size): at most 10 MB (or `max_bytes`, when smaller), width plus height at most
  10,000 pixels (so at most 25 megapixels) and an aspect ratio of at most 20.
  Returns the reason otherwise.
  """
  @spec check(info(), non_neg_integer(), pos_integer()) :: :ok | {:error, String.t()}
  def check(%{width: width, height: height}, bytes, max_bytes \\ @max_bytes) do
    max_bytes = min(max_bytes, @max_bytes)

    cond do
      bytes > max_bytes ->
        {:error, "larger than #{Media.format_mb(max_bytes)}"}

      width + height > @max_sides ->
        {:error, "#{width}x#{height} pixels is too large"}

      max(width, height) > @max_ratio * min(width, height) ->
        {:error, "#{width}x#{height} is too narrow"}

      true ->
        :ok
    end
  end

  @doc ~S'The file extension for a photo format: `"jpg"`, `"png"` or `"webp"`.'
  @spec extension(format()) :: String.t()
  def extension(:jpeg), do: "jpg"
  def extension(:png), do: "png"
  def extension(:webp), do: "webp"

  ## JPEG: markers (0xFF, then the marker byte, then a 16-bit length that counts
  ## itself) until a frame header (SOF0-SOF15 but DHT, JPG and DAC).

  defp jpeg(_data, 0), do: :error

  # Fill bytes before a marker.
  defp jpeg(<<0xFF, 0xFF, rest::binary>>, left), do: jpeg(<<0xFF, rest::binary>>, left - 1)

  # Markers without a length (TEM, RSTn, a repeated SOI).
  defp jpeg(<<0xFF, marker, rest::binary>>, left)
       when marker in [0x01, 0xD8] or marker in 0xD0..0xD7,
       do: jpeg(rest, left - 1)

  defp jpeg(<<0xFF, marker, length::16, _precision, height::16, width::16, _::binary>>, _left)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] and length >= 8,
       do: info(:jpeg, width, height)

  # Image data (SOS) or the end (EOI) before a frame header.
  defp jpeg(<<0xFF, marker, _::binary>>, _left) when marker in [0xD9, 0xDA], do: :error

  # Any other segment is skipped; its length counts itself, so it is at least 2.
  defp jpeg(<<0xFF, _marker, length::16, rest::binary>>, left)
       when length >= 2 and byte_size(rest) >= length - 2 do
    skip = length - 2
    jpeg(binary_part(rest, skip, byte_size(rest) - skip), left - 1)
  end

  defp jpeg(_data, _left), do: :error

  ## WebP: the first chunk is VP8 (lossy), VP8L (lossless) or VP8X (extended,
  ## with the canvas size).

  defp webp(
         <<"VP8 ", _size::little-32, _tag::24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16,
           _::binary>>
       ),
       do: info(:webp, Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF))

  defp webp(<<"VP8L", _size::little-32, 0x2F, bits::little-32, _::binary>>) do
    info(:webp, Bitwise.band(bits, 0x3FFF) + 1, Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1)
  end

  defp webp(
         <<"VP8X", _size::little-32, _flags, _reserved::24, w::little-24, h::little-24,
           _::binary>>
       ),
       do: info(:webp, w + 1, h + 1)

  defp webp(_chunk), do: :error

  defp info(format, width, height) when width > 0 and height > 0,
    do: {:ok, %{format: format, width: width, height: height}}

  defp info(_format, _width, _height), do: :error
end
