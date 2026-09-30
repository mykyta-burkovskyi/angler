defmodule Angler.Media.Instagram.Post do
  @moduledoc """
  An Instagram post as read by `Angler.Media.Instagram`.

    * `:code` - the post's shortcode (`/p/<code>/`)
    * `:items` - the photos and videos in display order (at most 20), each
      `%{type: :photo | :video, urls: [url, ...], width: w, height: h, duration: s}`:
      the same file in one or more versions, best first; dimensions and a video's
      duration (seconds) may be nil
    * `:caption` - the post text, or nil
    * `:username`, `:full_name` - of the author, if known
    * `:webpage_url` - the post's canonical URL

  Built from Instagram's own post data (`from_media/1`: the GraphQL answer or the
  post page) or from yt-dlp's metadata of the post (`from_ytdlp/1`). A post's
  music is not part of it: logged out, Instagram leaves it out, and
  `Angler.Media.Instagram.Music` reads it from the logged-in media info.
  """

  alias Angler.Media.Error
  alias Angler.Media.Instagram.Url

  defstruct [:code, :caption, :username, :full_name, :webpage_url, items: []]

  @type item :: %{
          type: :photo | :video,
          urls: [String.t(), ...],
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          duration: float() | nil
        }

  @type t :: %__MODULE__{
          code: String.t() | nil,
          items: [item()],
          caption: String.t() | nil,
          username: String.t() | nil,
          full_name: String.t() | nil,
          webpage_url: String.t() | nil
        }

  @max_items 20
  @photo_urls 2
  @video_urls 3
  @no_items_message "This Instagram post has no photos or videos"
  @duration_re ~r/mediaPresentationDuration="PT(?:(\d+)H)?(?:(\d+)M)?([\d.]+)S"/

  @doc """
  Builds the post from Instagram's post data (`xig_polaris_media.if_not_gated_logged_out`
  of the GraphQL answer or the post page): the items of `carousel_media`, or the
  post itself.

  Photos (`media_type` 1) keep the first two `image_versions2.candidates` (the
  original, then a smaller version; ordered by size when the candidates carry
  dimensions, which they don't when logged out), starting with the smaller one
  when the original exceeds Telegram's photo limits (width + height over 10000,
  or a side ratio over 20). Videos (`media_type` 2) keep their distinct
  `video_versions`; the duration comes from `video_duration` or the DASH
  manifest. Items without URLs are left out; `:unsupported` when none is left.
  """
  @spec from_media(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_media(media) when is_map(media) do
    code = string(media["code"])

    items =
      case media["carousel_media"] do
        [_ | _] = carousel -> carousel
        _single -> [media]
      end

    build(Enum.map(items, &media_item/1), %__MODULE__{
      code: code,
      caption: string(dig(media, ["caption", "text"])),
      username: string(dig(media, ["user", "username"])),
      full_name: string(dig(media, ["user", "full_name"])),
      webpage_url: code && Url.canonical(code)
    })
  end

  defp media_item(%{"media_type" => 1} = item) do
    width = dimension(item["original_width"])
    height = dimension(item["original_height"])

    item
    |> dig(["image_versions2", "candidates"])
    |> by_area()
    |> urls()
    |> within_photo_limits(width, height)
    |> Enum.take(@photo_urls)
    |> item(:photo, width, height, nil)
  end

  defp media_item(%{"media_type" => 2} = item) do
    item["video_versions"]
    |> by_area()
    |> urls()
    |> Enum.take(@video_urls)
    |> item(
      :video,
      dimension(item["original_width"]),
      dimension(item["original_height"]),
      positive(item["video_duration"]) || manifest_duration(item["video_dash_manifest"])
    )
  end

  defp media_item(_other), do: nil

  # The original is too big for sendPhoto: start with the next (smaller) version.
  defp within_photo_limits([_original | [_ | _] = smaller] = urls, width, height)
       when is_integer(width) and is_integer(height) do
    if width + height > 10_000 or max(width, height) / min(width, height) > 20,
      do: smaller,
      else: urls
  end

  defp within_photo_limits(urls, _width, _height), do: urls

  defp manifest_duration(manifest) when is_binary(manifest) do
    case Regex.run(@duration_re, manifest, capture: :all_but_first) do
      [hours, minutes, seconds] ->
        with {seconds, ""} <- Float.parse(seconds) do
          seconds = number(hours) * 3600 + number(minutes) * 60 + seconds
          if seconds > 0, do: seconds / 1
        else
          _invalid -> nil
        end

      nil ->
        nil
    end
  end

  defp manifest_duration(_manifest), do: nil

  defp number(""), do: 0
  defp number(digits), do: String.to_integer(digits)

  @doc """
  Builds the post from the entries yt-dlp printed for it (one per item, carousel
  entries with `playlist_index`), see `Angler.Media.Ytdlp.metadata/3`.

  An entry without downloadable formats is a photo: its `thumbnail`, then its
  `thumbnails` from the largest (yt-dlp lists them smallest first). A video keeps
  its progressive formats (not `dash-*`, over HTTPS), largest first, or else the
  formats with both video and audio. The post text is `description`, the author
  `channel` (user name) and `uploader` (full name). `:unsupported` without items.
  """
  @spec from_ytdlp([map()]) :: {:ok, t()} | {:error, Error.t()}
  def from_ytdlp(entries) when is_list(entries) do
    entries =
      entries
      |> Enum.filter(&is_map/1)
      |> Enum.sort_by(&if(is_integer(&1["playlist_index"]), do: &1["playlist_index"], else: 0))

    first = List.first(entries, %{})
    code = string(first["playlist_id"]) || string(first["id"])

    build(Enum.map(entries, &ytdlp_item/1), %__MODULE__{
      code: code,
      caption: string(first["description"]),
      username: string(first["channel"]),
      full_name: string(first["uploader"]),
      webpage_url: code && Url.canonical(code)
    })
  end

  defp ytdlp_item(entry) do
    width = dimension(entry["width"])
    height = dimension(entry["height"])

    case entry["formats"] |> maps() |> Enum.filter(&http_url?(&1["url"])) do
      [] ->
        [%{"url" => entry["thumbnail"]} | thumbnails(entry["thumbnails"])]
        |> urls()
        |> Enum.take(@photo_urls)
        |> item(:photo, width, height, nil)

      formats ->
        progressive =
          Enum.filter(formats, fn format ->
            format["protocol"] == "https" and
              not String.starts_with?(to_string(format["format_id"]), "dash")
          end)

        formats =
          if progressive != [], do: progressive, else: Enum.filter(formats, &audio_and_video?/1)

        formats
        |> by_area()
        |> urls()
        |> Enum.take(@video_urls)
        |> item(:video, width, height, positive(entry["duration"]))
    end
  end

  # Largest first; yt-dlp sorts thumbnails from the worst to the best.
  defp thumbnails(thumbnails) do
    thumbnails
    |> maps()
    |> Enum.reverse()
    |> Enum.sort_by(&{number_or(&1["preference"], -1), area(&1) || 0}, :desc)
  end

  defp audio_and_video?(format) do
    Enum.all?([format["vcodec"], format["acodec"]], &(is_binary(&1) and &1 != "none"))
  end

  defp build(items, post) do
    case items |> Enum.reject(&is_nil/1) |> Enum.take(@max_items) do
      [] -> {:error, Error.new(:unsupported, @no_items_message)}
      items -> {:ok, %{post | items: items}}
    end
  end

  defp item([], _type, _width, _height, _duration), do: nil

  defp item(urls, type, width, height, duration),
    do: %{type: type, urls: urls, width: width, height: height, duration: duration}

  @doc """
  Whether the post is read item by item rather than by yt-dlp: it has a photo or
  several items (an album, or a slideshow for a photo post with music).
  """
  @spec album?(t()) :: boolean()
  def album?(%__MODULE__{items: items}),
    do: length(items) > 1 or Enum.any?(items, &(&1.type == :photo))

  @doc """
  Whether every item is a photo: a single photo or a carousel of photos only
  (such a post becomes a slideshow when it has music, see `Angler.Media.Instagram`).
  """
  @spec photos?(t()) :: boolean()
  def photos?(%__MODULE__{items: [_ | _] = items}), do: Enum.all?(items, &(&1.type == :photo))
  def photos?(%__MODULE__{}), do: false

  @doc ~S'The post text, else "Post by @<username>", else "Instagram post".'
  @spec title(t()) :: String.t()
  def title(%__MODULE__{caption: caption}) when is_binary(caption), do: caption
  def title(%__MODULE__{username: username}) when is_binary(username), do: "Post by @#{username}"
  def title(%__MODULE__{}), do: "Instagram post"

  ## Helpers

  # Largest first when every entry has dimensions; otherwise in the given order.
  defp by_area(list) do
    list = maps(list)

    if Enum.all?(list, &area/1),
      do: Enum.sort_by(list, &area/1, :desc),
      else: list
  end

  defp area(map) do
    with width when is_integer(width) <- dimension(map["width"]),
         height when is_integer(height) <- dimension(map["height"]),
         do: width * height
  end

  defp urls(list), do: list |> Enum.map(& &1["url"]) |> Enum.filter(&http_url?/1) |> Enum.uniq()

  defp http_url?("https://" <> _rest), do: true
  defp http_url?("http://" <> _rest), do: true
  defp http_url?(_other), do: false

  defp maps(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp maps(_other), do: []

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)
  defp dig(_value, _keys), do: nil

  defp string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string(_value), do: nil

  defp positive(value) when is_number(value) and value > 0, do: value / 1
  defp positive(_value), do: nil

  defp number_or(value, _default) when is_number(value), do: value
  defp number_or(_value, default), do: default

  defp dimension(value) when is_integer(value) and value > 0, do: value
  defp dimension(_value), do: nil
end
