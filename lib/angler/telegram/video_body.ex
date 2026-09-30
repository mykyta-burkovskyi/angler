defmodule Angler.Telegram.VideoBody do
  @moduledoc """
  Request bodies for `sendVideo` (see `Angler.Telegram.send_video/3`): JSON for a
  `file_id`, multipart for a local file, or JSON with `file://` URIs when a local
  Bot API server in `--local` mode reads the files from its own disk (see
  `Angler.Telegram.Multipart`).
  """
  alias Angler.Telegram.{Config, Error, Multipart}

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
          [video: Multipart.file_uri(path)] ++
            if(thumbnail, do: [thumbnail: Multipart.file_uri(thumbnail)], else: [])

        {:ok, [json: Map.new(fields ++ files)]}

      true ->
        {:ok, [form_multipart: multipart(fields, path, thumbnail)]}
    end
  end

  defp multipart(fields, path, thumbnail) do
    thumbnail_parts =
      if thumbnail do
        [
          thumbnail: "attach://thumb",
          thumb: Multipart.file_part(thumbnail, "thumbnail.jpg")
        ]
      else
        []
      end

    Multipart.text_fields(fields) ++
      [video: Multipart.file_part(path, "video.mp4")] ++ thumbnail_parts
  end
end
