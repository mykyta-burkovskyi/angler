defmodule Angler.InstagramMusicFixtures do
  @moduledoc """
  Instagram's logged-in media info and the music of photo posts, for tests of
  `Angler.Media.Instagram.MediaInfo`, `Angler.Media.Instagram.Music` and the
  slideshows made of Instagram photo posts (see `Angler.InstagramFixtures` for
  the logged-out answers and the `Req.Test` stub).

  Recorded answers (2026-09-30, trimmed to 3 photos, URLs replaced by fake ones,
  in `test/fixtures/instagram/`):

    * `info_carousel_music_DdlJg0lFG8-.json` - the logged-in media info of a
      photo carousel with the song "Solace" by Txmy (140.586 s, the post plays
      90 s from 1.5 s), at `https://scontent-iev1-1.xx.fbcdn.net/.../song.mp4`;
      see `media_info/1`
    * `graphql_carousel_music_DdlJg0lFG8-.json` - the logged-out GraphQL answer
      for the same post (no music), see `Angler.InstagramFixtures.graphql/1`

  `music_metadata/1`, `with_music/2` and `media_info_answer/1` build answers of
  any shape; `cookies_text/1` a cookies file with an Instagram session.
  """

  import Angler.InstagramFixtures, only: [graphql_media_id: 1, javascript: 2, stub_instagram: 1]

  alias Angler.Media.Instagram.Url

  @fixtures Path.expand("../fixtures/instagram", __DIR__)
  @song_url "https://scontent-iev1-1.xx.fbcdn.net/o1/v/t2/f2/m69/song.mp4?efg=x&oh=00_sig&oe=6AC1D6AC"
  @preview_url "https://scontent-iev1-1.xx.fbcdn.net/o1/v/t2/f2/m69/preview.mp4?efg=x&oh=00_sig&oe=6AC1D6AC"

  @doc "The song URL of the recorded answer and of `music_metadata/1`."
  def song_url, do: @song_url

  @doc "The recorded media info answer (JSON text) for a post code, e.g. `\"DdlJg0lFG8-\"`."
  def media_info(code) do
    case Path.wildcard(Path.join(@fixtures, "info_*_#{code}.json")) do
      [path] -> File.read!(path)
      _other -> raise ArgumentError, "no recorded media info for #{code}"
    end
  end

  @doc "A media info answer (JSON text) with `media` as its only item."
  def media_info_answer(media) do
    Jason.encode!(%{"items" => [media], "num_results" => 1, "status" => "ok"})
  end

  @doc """
  A `music_metadata` map like Instagram's, by default the recorded post's.

  Options:
    * `:audio_type` - `:licensed` (default, `music_info`) or `:original`
      (`original_sound_info`, which has no fast-start or preview URL and no clip)
    * `:url` - the song (`progressive_download_url`, default `song_url/0`)
    * `:fast_start_url` - default the same as `:url`
    * `:preview_url` - the 30-second preview, default one next to the song
    * `:start_ms` (default 1500), `:overlap_ms` (default 90000) - the clip
    * `:duration_ms` - the song, default 140586
    * `:should_mute` - `should_mute_audio` (of `music_consumption_info`, or of the
      original sound), default false
    * `:mute_audio` - `audio_muting_info.mute_audio` (of an original sound:
      `consumption_info.should_mute_audio`), default false

  A nil URL option leaves that URL out (null).
  """
  def music_metadata(opts \\ []) do
    url = Keyword.get(opts, :url, @song_url)
    should_mute = Keyword.get(opts, :should_mute, false)
    mute_audio = Keyword.get(opts, :mute_audio, false)
    duration_ms = Keyword.get(opts, :duration_ms, 140_586)

    case Keyword.get(opts, :audio_type, :licensed) do
      :licensed ->
        %{
          "audio_type" => "licensed_music",
          "music_canonical_id" => "18449779159110476",
          "original_sound_info" => nil,
          "music_info" => %{
            "music_asset_info" => %{
              "title" => "Solace",
              "display_artist" => "Txmy",
              "duration_in_ms" => duration_ms,
              "dash_manifest" => nil,
              "progressive_download_url" => url,
              "fast_start_progressive_download_url" => Keyword.get(opts, :fast_start_url, url),
              "web_30s_preview_download_url" => Keyword.get(opts, :preview_url, @preview_url)
            },
            "music_consumption_info" => %{
              "audio_asset_start_time_in_ms" => Keyword.get(opts, :start_ms, 1500),
              "overlap_duration_in_ms" => Keyword.get(opts, :overlap_ms, 90_000),
              "should_mute_audio" => should_mute,
              "should_mute_audio_reason" => "",
              "audio_muting_info" => %{"mute_audio" => mute_audio, "mute_reason_str" => ""}
            }
          }
        }

      :original ->
        %{
          "audio_type" => "original_sound",
          "music_info" => nil,
          "original_sound_info" => %{
            "audio_asset_id" => "1234567890",
            "original_audio_title" => "Original audio",
            "ig_artist" => %{"username" => "someone"},
            "duration_in_ms" => duration_ms,
            "dash_manifest" => nil,
            "progressive_download_url" => url,
            "should_mute_audio" => should_mute,
            "consumption_info" => %{"should_mute_audio" => mute_audio}
          }
        }
    end
  end

  @doc "`media` (a post or media info item) with `music` as its `music_metadata`."
  def with_music(media, music), do: Map.put(media, "music_metadata", music)

  @doc "The path of the media info request for a post code."
  def info_path(code), do: "/api/v1/media/#{Url.pk(code)}/info/"

  @doc """
  A cookies file (Netscape format) with an Instagram session: `.instagram.com`
  cookies `sessionid` and `csrftoken`, and a `.tiktok.com` `sessionid` (`T1KTOK`).

  Options:
    * `:instagram` - false leaves out the Instagram cookies (default true)
    * `:session` - the `sessionid` value (default `"S3SSION"`)
    * `:csrf` - the `csrftoken` value (default `"CSRF7"`), nil leaves it out
    * `:expires` - the Instagram cookies' expiry, Unix seconds (default 0, a
      session cookie)
  """
  def cookies_text(opts \\ []) do
    expires = Keyword.get(opts, :expires, 0)

    instagram =
      if Keyword.get(opts, :instagram, true) do
        [
          {"sessionid", Keyword.get(opts, :session, "S3SSION")},
          {"csrftoken", Keyword.get(opts, :csrf, "CSRF7")}
        ]
        |> Enum.reject(fn {_name, value} -> is_nil(value) end)
        |> Enum.map(fn {name, value} ->
          ".instagram.com\tTRUE\t/\tTRUE\t#{expires}\t#{name}\t#{value}\n"
        end)
      else
        []
      end

    Enum.join(
      ["# Netscape HTTP Cookie File\n" | instagram] ++
        [".tiktok.com\tTRUE\t/\tTRUE\t0\tsessionid\tT1KTOK\n"]
    )
  end

  @doc """
  Stubs Instagram and its CDN (with `Angler.InstagramFixtures.stub_instagram/1`,
  so every request is also sent to the calling process): GraphQL requests are
  answered from `graphql_answers` (JSON text by post code), media info requests
  (`GET /api/v1/media/...`) go to `info` and anything else (the CDN) to `cdn`,
  each called with the `Plug.Conn`.
  """
  def stub_music(graphql_answers, info, cdn) do
    by_pk = Map.new(graphql_answers, fn {code, answer} -> {Url.pk(code), answer} end)

    stub_instagram(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/graphql"} ->
          {media_id, conn} = graphql_media_id(conn)
          javascript(conn, Map.fetch!(by_pk, media_id))

        {"GET", "/api/v1/media/" <> _rest} ->
          info.(conn)

        _other ->
          cdn.(conn)
      end
    end)
  end

  @doc "Responds with `body` (JSON text, or a term to encode) as `application/json`."
  def json(conn, body, status \\ 200) do
    body = if is_binary(body), do: body, else: Jason.encode!(body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end
end
