defmodule Angler.Telegram.VideoBody do
  @moduledoc """
  Request bodies for `sendVideo` (see `Angler.Telegram.send_video/3`): JSON for a
  `file_id`, multipart for a local file, or JSON with `file://` URIs when a local
  Bot API server in `--local` mode reads the files from its own disk.
  """
  alias Angler.Telegram.{Config, Error}

  @chunk_size 65_536

  @doc """
  The Req body options (`json:` or `form_multipart:`) for sending `video` with the
  other `fields` (a keyword list without nils) and an optional JPEG `thumbnail`
  path, which is only sent with files and skipped when it doesn't exist.
  """
  @spec build({:path, Path.t()} | {:file_id, String.t()}, keyword(), Path.t() | nil) ::
          {:ok, keyword()} | {:error, Error.t()}
  def build({:file_id, file_id}, fields, _thumbnail),
    do: {:ok, [json: Map.new([{:video, file_id} | fields])]}

  def build({:path, path}, fields, thumbnail) do
    thumbnail = if is_binary(thumbnail) and File.regular?(thumbnail), do: thumbnail

    cond do
      not File.regular?(path) ->
        {:error,
         %Error{
           method: "sendVideo",
           description: "video file not found: #{path}",
           reason: :enoent
         }}

      Config.local_mode?() ->
        files =
          [video: file_uri(path)] ++ if(thumbnail, do: [thumbnail: file_uri(thumbnail)], else: [])

        {:ok, [json: Map.new(fields ++ files)]}

      true ->
        {:ok, [form_multipart: multipart(fields, path, thumbnail)]}
    end
  end

  # A local Bot API server in --local mode reads `file://` URIs from its own disk,
  # which shares the media volume at the same absolute path.
  defp file_uri(path), do: "file://" <> URI.encode(Path.expand(path))

  # Chunked streams (never the default :line mode, which rewrites CRLF) let Req
  # compute content-length from the file sizes without reading them into memory.
  defp multipart(fields, path, thumbnail) do
    text_fields = Enum.map(fields, fn {name, value} -> {name, multipart_value(value)} end)
    video = {File.stream!(path, @chunk_size), filename: "video.mp4", content_type: "video/mp4"}

    thumbnail_parts =
      if thumbnail do
        [
          thumbnail: "attach://thumb",
          thumb:
            {File.stream!(thumbnail, @chunk_size),
             filename: "thumbnail.jpg", content_type: "image/jpeg"}
        ]
      else
        []
      end

    text_fields ++ [video: video] ++ thumbnail_parts
  end

  defp multipart_value(value) when is_binary(value), do: value
  defp multipart_value(value) when is_integer(value), do: Integer.to_string(value)
  defp multipart_value(value) when is_boolean(value), do: Atom.to_string(value)
  defp multipart_value(value) when is_map(value), do: Jason.encode!(value)
end
