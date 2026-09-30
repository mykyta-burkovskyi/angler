defmodule Angler.Telegram.MediaBody do
  @moduledoc """
  Request bodies for `sendPhoto` and `sendMediaGroup` (see
  `Angler.Telegram.send_photo/3` and `Angler.Telegram.send_media_group/3`), built
  like `Angler.Telegram.VideoBody`'s:

    * multipart when local files are uploaded to Telegram. An album's `media`
      array refers to them as `attach://file<i>` and to video thumbnails as
      `attach://thumb<i>` (`i` is the item's 0-based position). A part is never
      named `thumb` or `thumbnail`: the Bot API server would use such a part as
      the thumbnail of every video that doesn't have its own.
    * JSON with `file://` URIs when a local Bot API server in `--local` mode reads
      the files from its own disk
    * JSON when every file is sent by `file_id`

  A missing file fails with reason `:enoent` before any request is made. Photos
  never get a thumbnail, and videos only get one when they are uploaded (Telegram
  can't reuse thumbnails); a missing thumbnail is skipped.
  """
  alias Angler.Telegram.{Config, Error, Multipart}

  @type source :: {:path, Path.t()} | {:file_id, String.t()}

  @typedoc """
  An album item. `:width`, `:height`, `:duration` and `:thumbnail` (a JPEG path)
  are only used for videos; `:caption` only for the first item.
  """
  @type item :: %{
          required(:type) => :photo | :video,
          required(:media) => source(),
          optional(:caption) => String.t() | nil,
          optional(:width) => number() | nil,
          optional(:height) => number() | nil,
          optional(:duration) => number() | nil,
          optional(:thumbnail) => Path.t() | nil
        }

  @min_items 2
  @max_items 10

  @doc """
  The Req body options (`json:` or `form_multipart:`) for sending `photo` with the
  other `fields` (a keyword list without nils).
  """
  @spec photo(source(), keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def photo({:file_id, file_id}, fields), do: {:ok, [json: Map.new([{:photo, file_id} | fields])]}

  def photo({:path, path}, fields) do
    cond do
      not File.regular?(path) ->
        {:error, not_found("sendPhoto", :photo, path)}

      Config.local_mode?() ->
        {:ok, [json: Map.new(fields ++ [photo: Multipart.file_uri(path)])]}

      true ->
        photo = Multipart.file_part(path, "photo" <> extension(path))
        {:ok, [form_multipart: Multipart.text_fields(fields) ++ [photo: photo]]}
    end
  end

  @doc """
  The Req body options for sending 2 to 10 `items` as an album with the other
  `fields` (a keyword list without nils). `caption` (when not nil) replaces the
  first item's `:caption`; the captions of the other items are dropped, so that
  Telegram shows it as the album's caption.

  Any other number of items, or an item that isn't a photo or video with a
  `t:source/0`, fails with a 400 error.
  """
  @spec media_group([item()], keyword(), String.t() | nil) ::
          {:ok, keyword()} | {:error, Error.t()}
  def media_group(items, fields, caption \\ nil) when is_list(items) do
    with :ok <- check_count(items),
         :ok <- check_items(items) do
      upload? = not Config.local_mode?() and Enum.any?(items, &match?({:path, _}, &1.media))

      {media, parts} =
        items
        |> Enum.with_index()
        |> Enum.map(&input_media(&1, upload?))
        |> Enum.unzip()

      media = put_caption(media, caption || Map.get(hd(items), :caption))

      if upload? do
        text_fields = Multipart.text_fields(fields ++ [media: media])
        {:ok, [form_multipart: text_fields ++ List.flatten(parts)]}
      else
        {:ok, [json: Map.new([{:media, media} | fields])]}
      end
    end
  end

  ## Validation

  defp check_count(items) when length(items) in @min_items..@max_items, do: :ok

  defp check_count(items) do
    bad_request("sendMediaGroup takes #{@min_items} to #{@max_items} items, got #{length(items)}")
  end

  defp check_items(items) do
    items
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {item, index} ->
      case item do
        %{type: type, media: {:path, path}} when type in [:photo, :video] and is_binary(path) ->
          if not File.regular?(path), do: {:error, not_found("sendMediaGroup", type, path)}

        %{type: type, media: {:file_id, id}} when type in [:photo, :video] and is_binary(id) ->
          nil

        _item ->
          bad_request("media item #{index} is not a photo or video with a path or file_id")
      end
    end)
  end

  defp bad_request(description) do
    {:error,
     %Error{method: "sendMediaGroup", code: 400, description: "Bad Request: " <> description}}
  end

  defp not_found(method, type, path),
    do: %Error{method: method, description: "#{type} file not found: #{path}", reason: :enoent}

  ## InputMedia

  # Returns the InputMedia map of an item and its multipart parts (for uploads).
  defp input_media({%{type: :photo} = item, index}, upload?) do
    {media, parts} = file(item, index, upload?)
    {%{type: "photo", media: media}, parts}
  end

  defp input_media({%{type: :video} = item, index}, upload?) do
    {media, parts} = file(item, index, upload?)
    {thumbnail, thumbnail_parts} = thumbnail(item, index, upload?)

    fields =
      compact(
        type: "video",
        media: media,
        thumbnail: thumbnail,
        width: to_integer(Map.get(item, :width)),
        height: to_integer(Map.get(item, :height)),
        duration: to_integer(Map.get(item, :duration)),
        supports_streaming: true
      )

    {Map.new(fields), parts ++ thumbnail_parts}
  end

  defp file(%{media: {:file_id, file_id}}, _index, _upload?), do: {file_id, []}

  defp file(%{type: type, media: {:path, path}}, index, true) do
    part = :"file#{index}"
    {"attach://#{part}", [{part, Multipart.file_part(path, upload_filename(type, index, path))}]}
  end

  defp file(%{media: {:path, path}}, _index, false), do: {Multipart.file_uri(path), []}

  defp upload_filename(:photo, index, path), do: "photo#{index}" <> extension(path)
  defp upload_filename(:video, index, _path), do: "video#{index}.mp4"

  # Only uploaded videos get a thumbnail: Telegram can't reuse thumbnails.
  defp thumbnail(%{media: {:path, _path}} = item, index, upload?) do
    case Map.get(item, :thumbnail) do
      path when is_binary(path) ->
        if File.regular?(path), do: thumbnail_file(path, index, upload?), else: {nil, []}

      _none ->
        {nil, []}
    end
  end

  defp thumbnail(_item, _index, _upload?), do: {nil, []}

  defp thumbnail_file(path, index, true) do
    part = :"thumb#{index}"
    {"attach://#{part}", [{part, Multipart.file_part(path, "thumbnail#{index}.jpg")}]}
  end

  defp thumbnail_file(path, _index, false), do: {Multipart.file_uri(path), []}

  defp put_caption([first | rest], caption) when is_binary(caption),
    do: [Map.put(first, :caption, caption) | rest]

  defp put_caption(media, _caption), do: media

  ## Helpers

  defp extension(path), do: path |> Path.extname() |> String.downcase()

  defp compact(fields), do: Enum.reject(fields, fn {_key, value} -> is_nil(value) end)

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: round(value)
  defp to_integer(_value), do: nil
end
