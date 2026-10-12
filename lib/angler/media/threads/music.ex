defmodule Angler.Media.Threads.Music do
  @moduledoc """
  The music of a Threads post (`text_app_music_info` of the post, which Threads
  shows logged out), as an `Angler.Media.Instagram.Music` for the slideshow of a
  photo post (`Angler.Media.Slideshow.Instagram`). Pure.

  The song is the audio file of the DASH manifest in
  `music_consumable_video.audio_metadata.audio_asset` (its `<BaseURL>`: the whole
  song, on Instagram's CDN), its duration the manifest's. The post plays a clip of
  up to 30 seconds starting at `audio_start_time_in_ms`; Threads doesn't say how
  long it is, so the clip is 30 seconds, or the rest of the song when that is
  shorter (see `Angler.Media.Slideshow.Clip`).

  There is no usable music (`{:none, reason}`) when the post has none, when
  Threads doesn't let it play (`is_available_for_consumption` is not true), when
  the manifest has no audio file, or when the song is not on Instagram's CDN
  (`Angler.Media.Instagram.Cdn.cdn?/1`). Reasons are fixed texts; the last one
  names the song's host, never its URL.
  """

  alias Angler.Media.Instagram.{Cdn, Music, Post}

  @clip_seconds 30.0
  @base_url_re ~r{<BaseURL>\s*([^<]+?)\s*</BaseURL>}

  @doc """
  Reads the music of the Threads post `media`, see the module documentation:
  `{:ok, music}`, or `{:none, reason}` when it has no usable music.
  """
  @spec from_media(map()) :: {:ok, Music.t()} | {:none, String.t()}
  def from_media(%{"text_app_music_info" => %{} = info}) do
    video = map(info["music_consumable_video"])
    asset = video |> map_at("audio_metadata") |> map_at("audio_asset")
    manifest = asset["dash_manifest"]

    with :ok <- available(info["is_available_for_consumption"]),
         {:ok, url} <- song_url(manifest) do
      {:ok,
       %Music{
         url: url,
         duration: Post.manifest_duration(manifest),
         start: start_ms(video["audio_start_time_in_ms"]),
         clip_duration: @clip_seconds,
         title: text(asset["display_title"]),
         artist: text(asset["display_artist"]),
         kind: :licensed
       }}
    end
  end

  def from_media(%{}), do: {:none, "no music"}

  defp available(true), do: :ok
  defp available(_other), do: {:none, "the music is not available"}

  # The first audio file of the manifest, which must be on the CDN.
  defp song_url(manifest) when is_binary(manifest) do
    urls =
      @base_url_re
      |> Regex.scan(manifest, capture: :all_but_first)
      |> Enum.map(fn [url] -> unescape(url) end)
      |> Enum.filter(&String.starts_with?(&1, "https://"))

    case urls do
      [] ->
        {:none, "no song file"}

      [first | _rest] ->
        case Enum.find(urls, &Cdn.cdn?/1) do
          nil -> {:none, "the song is not on Instagram's CDN (#{host(first)})"}
          url -> {:ok, url}
        end
    end
  end

  defp song_url(_manifest), do: {:none, "no song file"}

  # XML character references in the manifest's URLs (`&amp;` between parameters).
  defp unescape(url) do
    url
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  defp host(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" -> host
      _none -> "no host"
    end
  end

  defp map(%{} = map), do: map
  defp map(_other), do: %{}

  defp map_at(map, key), do: map(map[key])

  # Display texts are `{"text": ...}`; Threads separates words with no-break spaces.
  defp text(%{"text" => text}) when is_binary(text) do
    case text |> String.replace(" ", " ") |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp text(_value), do: nil

  defp start_ms(value) when is_number(value) and value >= 0, do: value / 1000
  defp start_ms(_value), do: 0.0
end
