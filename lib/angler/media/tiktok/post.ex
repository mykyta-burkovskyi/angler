defmodule Angler.Media.TikTok.Post do
  @moduledoc """
  A TikTok photo post (slideshow) as read from its page's `itemStruct`.

    * `:id` - the post id
    * `:images` - in display order, each `%{urls: [url], width: w, height: h}`:
      the same image on several CDN hosts (`imageURL.urlList`), with the
      dimensions TikTok reports (may be nil)
    * `:audio_url` - `music.playUrl`, or nil when TikTok has no sound for the post
    * `:audio_duration` - seconds TikTok reports for the sound
      (`music.preciseDuration.preciseDuration`, else `music.duration`), or nil
    * `:title` - the caption (`desc`), or "Slideshow by @author" when it is empty
    * `:author` - `author.uniqueId`
    * `:webpage_url` - the post's `/photo/` URL
  """

  @enforce_keys [:id]
  defstruct [:id, :audio_url, :audio_duration, :title, :author, :webpage_url, images: []]

  @type image :: %{urls: [String.t()], width: pos_integer() | nil, height: pos_integer() | nil}
  @type t :: %__MODULE__{
          id: String.t(),
          images: [image()],
          audio_url: String.t() | nil,
          audio_duration: float() | nil,
          title: String.t() | nil,
          author: String.t() | nil,
          webpage_url: String.t()
        }

  @doc "Whether `item` (an `itemStruct`) is a photo post: it has at least one image."
  @spec slideshow?(map()) :: boolean()
  def slideshow?(%{"imagePost" => %{"images" => [_ | _]}}), do: true
  def slideshow?(_item), do: false

  @doc "Builds the post from a photo post's `itemStruct`."
  @spec from_item(map(), String.t()) :: t()
  def from_item(item, id) when is_map(item) do
    author = string(dig(item, ["author", "uniqueId"]))

    %__MODULE__{
      id: id,
      images: images(dig(item, ["imagePost", "images"])),
      audio_url: string(dig(item, ["music", "playUrl"])),
      audio_duration:
        positive(dig(item, ["music", "preciseDuration", "preciseDuration"])) ||
          positive(dig(item, ["music", "duration"])),
      title: title(string(item["desc"]), author),
      author: author,
      webpage_url: "https://www.tiktok.com/@#{author}/photo/#{id}"
    }
  end

  defp images(list) when is_list(list) do
    for %{} = image <- list,
        urls = urls(dig(image, ["imageURL", "urlList"])),
        urls != [] do
      %{
        urls: urls,
        width: dimension(image["imageWidth"]),
        height: dimension(image["imageHeight"])
      }
    end
  end

  defp images(_other), do: []

  defp urls(list) when is_list(list), do: Enum.filter(list, &match?("http" <> _, &1))
  defp urls(_other), do: []

  defp title(nil, nil), do: nil
  defp title(nil, author), do: "Slideshow by @#{author}"
  defp title(desc, _author), do: desc

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

  defp dimension(value) when is_integer(value) and value > 0, do: value
  defp dimension(_value), do: nil
end
