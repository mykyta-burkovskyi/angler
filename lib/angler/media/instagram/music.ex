defmodule Angler.Media.Instagram.Music do
  @moduledoc """
  The music of an Instagram post, read from its logged-in media info
  (`music_metadata` of `Angler.Media.Instagram.MediaInfo.fetch/2`'s media; for a
  carousel the carousel's own, its items have none). Pure.

    * `:url` - the signed CDN URL of the whole song (left out of `inspect/2`)
    * `:duration` - the whole song, in seconds (Instagram's number), or nil
    * `:start`, `:clip_duration` - the part of the song the post plays: where it
      starts and how long it is (nil: to the end of the song), in seconds
    * `:title`, `:artist` - if known
    * `:kind` - `:licensed` (a song from Instagram's music library) or `:original`
      (someone's original sound)

  Licensed music (`music_info`) is read first, whatever `audio_type` says: the
  song is `music_asset_info.progressive_download_url` (or its fast-start
  variant), the clip comes from `music_consumption_info`
  (`audio_asset_start_time_in_ms`, `overlap_duration_in_ms`). The 30-second
  preview is never used: where it lies in the song is unknown. Original sounds
  (`original_sound_info`) are read on a best-effort basis: the sound from its
  start, as a whole.

  There is no usable music (`{:none, reason}`) when the post has none, when
  Instagram mutes it, when there is no song file (only a DASH manifest or a
  preview), or when the song is not on Instagram's CDN
  (`Angler.Media.Instagram.Cdn.cdn?/1`). Reasons are fixed texts; the last one
  names the song's host, never its URL.
  """

  alias Angler.Media.Instagram.Cdn

  @derive {Inspect, except: [:url]}
  @enforce_keys [:url]
  defstruct [:url, :duration, :clip_duration, :title, :artist, start: 0.0, kind: :licensed]

  @type t :: %__MODULE__{
          url: String.t(),
          duration: float() | nil,
          start: float(),
          clip_duration: float() | nil,
          title: String.t() | nil,
          artist: String.t() | nil,
          kind: :licensed | :original
        }

  @doc """
  Reads the music of `media` (a media info item), see the module documentation:
  `{:ok, music}`, or `{:none, reason}` when it has no usable music.
  """
  @spec from_media(map()) :: {:ok, t()} | {:none, String.t()}
  def from_media(media) when is_map(media) do
    case media["music_metadata"] do
      %{"music_info" => %{} = info} -> licensed(info)
      %{"original_sound_info" => %{} = sound} -> original(sound)
      _none -> {:none, "no music"}
    end
  end

  defp licensed(info) do
    asset = map(info["music_asset_info"])
    consumption = map(info["music_consumption_info"])

    muted? =
      consumption["should_mute_audio"] == true or
        map(consumption["audio_muting_info"])["mute_audio"] == true

    urls = [asset["progressive_download_url"], asset["fast_start_progressive_download_url"]]

    with :ok <- unmuted(muted?),
         {:ok, url} <- song_url(urls) do
      {:ok,
       %__MODULE__{
         url: url,
         duration: ms(asset["duration_in_ms"]),
         start: start_ms(consumption["audio_asset_start_time_in_ms"]),
         clip_duration: ms(consumption["overlap_duration_in_ms"]),
         title: string(asset["title"]),
         artist: string(asset["display_artist"]),
         kind: :licensed
       }}
    end
  end

  defp original(sound) do
    muted? =
      sound["should_mute_audio"] == true or
        map(sound["consumption_info"])["should_mute_audio"] == true

    with :ok <- unmuted(muted?),
         {:ok, url} <- song_url([sound["progressive_download_url"]]) do
      {:ok,
       %__MODULE__{
         url: url,
         duration: ms(sound["duration_in_ms"]),
         start: 0.0,
         clip_duration: nil,
         title: string(sound["original_audio_title"]),
         artist: string(map(sound["ig_artist"])["username"]),
         kind: :original
       }}
    end
  end

  defp unmuted(true), do: {:none, "the music is muted"}
  defp unmuted(false), do: :ok

  # The first candidate on the CDN, of the https ones.
  defp song_url(candidates) do
    case candidates |> Enum.filter(&https?/1) |> Enum.uniq() do
      [] ->
        {:none, "no song file"}

      [first | _rest] = urls ->
        case Enum.find(urls, &Cdn.cdn?/1) do
          nil -> {:none, "the song is not on Instagram's CDN (#{host(first)})"}
          url -> {:ok, url}
        end
    end
  end

  defp https?(url) when is_binary(url), do: URI.parse(url).scheme == "https"
  defp https?(_url), do: false

  defp host(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" -> host
      _none -> "no host"
    end
  end

  defp map(%{} = map), do: map
  defp map(_other), do: %{}

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  # Milliseconds as seconds: a positive number, else nil (strings don't count).
  defp ms(value) when is_number(value) and value > 0, do: value / 1000
  defp ms(_value), do: nil

  defp start_ms(value) when is_number(value) and value >= 0, do: value / 1000
  defp start_ms(_value), do: 0.0
end
