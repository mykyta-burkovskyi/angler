defmodule Angler.Media.Probe.Mp4 do
  @moduledoc """
  Tells whether an MP4/MOV file is "fast start": its `moov` index box comes before
  the `mdat` media data, so players can start before the whole file arrived.
  ffprobe doesn't report this, so `Angler.Media.Probe` reads the top-level box
  headers itself (through `Angler.Media.Probe.faststart?/1`).
  """

  @max_boxes 1_000

  @doc "See `Angler.Media.Probe.faststart?/1`."
  @spec faststart?(Path.t()) :: boolean()
  def faststart?(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          scan_boxes(file, 0, @max_boxes)
        after
          File.close(file)
        end

      {:error, _reason} ->
        false
    end
  end

  defp scan_boxes(_file, _offset, 0), do: false

  defp scan_boxes(file, offset, remaining) do
    case :file.pread(file, offset, 16) do
      {:ok, <<_size::32, "moov", _rest::binary>>} ->
        true

      {:ok, <<_size::32, "mdat", _rest::binary>>} ->
        false

      {:ok, <<1::32, _type::binary-size(4), size::64, _rest::binary>>} when size >= 16 ->
        scan_boxes(file, offset + size, remaining - 1)

      {:ok, <<size::32, _type::binary-size(4), _rest::binary>>} when size >= 8 ->
        scan_boxes(file, offset + size, remaining - 1)

      _eof_or_malformed ->
        false
    end
  end
end
