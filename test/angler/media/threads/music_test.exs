defmodule Angler.Media.Threads.MusicTest do
  use ExUnit.Case, async: true

  import Angler.ThreadsFixtures

  alias Angler.Media.Instagram.Music
  alias Angler.Media.Threads.Music, as: ThreadsMusic

  test "reads the song of a recorded photo post with music" do
    assert {:ok, %Music{} = music} = ThreadsMusic.from_media(media("DePPcDfkc_a"))

    assert music.url =~ ~r"\Ahttps://video-[a-z0-9-]+\.xx\.fbcdn\.net/"
    # The manifest's `&amp;` are unescaped.
    refute music.url =~ "&amp;"
    assert music.url =~ "&oe="
    assert music.start == 7.0
    assert music.clip_duration == 30.0
    assert is_float(music.duration) and music.duration > 30
    assert music.title == "Fly Me To The Moon (In Other Words)"
    assert music.artist == "Frank Sinatra, Count Basie"
    assert music.kind == :licensed
  end

  test "posts without music have none" do
    for code <- ~w(DeUWxGgjHSK DeMqtuYgkaL Ddt7cL5EfUG Dd1MqfcG0aH) do
      assert ThreadsMusic.from_media(media(code)) == {:none, "no music"}
    end

    assert ThreadsMusic.from_media(%{"text_app_music_info" => nil}) == {:none, "no music"}
  end

  test "music Threads doesn't let play is not usable" do
    media =
      put_in(media("DePPcDfkc_a"), ["text_app_music_info", "is_available_for_consumption"], false)

    assert ThreadsMusic.from_media(media) == {:none, "the music is not available"}
  end

  test "a song without a file, or not on the CDN, is not usable" do
    assert ThreadsMusic.from_media(with_manifest("<MPD></MPD>")) == {:none, "no song file"}
    assert ThreadsMusic.from_media(with_manifest(nil)) == {:none, "no song file"}

    assert ThreadsMusic.from_media(
             with_manifest("<BaseURL>http://video.xx.fbcdn.net/a.mp4</BaseURL>")
           ) ==
             {:none, "no song file"}

    assert ThreadsMusic.from_media(
             with_manifest("<BaseURL>https://evil.test/song.mp4?a=1&amp;b=2</BaseURL>")
           ) ==
             {:none, "the song is not on Instagram's CDN (evil.test)"}
  end

  test "reads what it can of a sparse answer" do
    manifest =
      ~s(<MPD mediaPresentationDuration="PT1M4.5S"><BaseURL>) <>
        ~s(https://video.xx.fbcdn.net/song.mp4?a=1&amp;b=2</BaseURL></MPD>)

    assert {:ok, music} = ThreadsMusic.from_media(with_manifest(manifest, %{}))
    assert music.url == "https://video.xx.fbcdn.net/song.mp4?a=1&b=2"
    assert music.duration == 64.5
    assert music.start == 0.0
    assert music.title == nil
    assert music.artist == nil
  end

  defp with_manifest(manifest, extra \\ %{"display_title" => %{"text" => "Song"}}) do
    %{
      "text_app_music_info" => %{
        "is_available_for_consumption" => true,
        "music_consumable_video" => %{
          "audio_metadata" => %{"audio_asset" => Map.put(extra, "dash_manifest", manifest)}
        }
      }
    }
  end
end
