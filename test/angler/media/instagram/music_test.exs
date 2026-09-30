defmodule Angler.Media.Instagram.MusicTest do
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures
  import Angler.InstagramMusicFixtures

  alias Angler.Media.Instagram.Music

  defp recorded_media do
    %{"items" => [media]} = Jason.decode!(media_info("DdlJg0lFG8-"))
    media
  end

  defp music(opts), do: Music.from_media(with_music(post([photo()]), music_metadata(opts)))

  test "reads the recorded post's licensed music and the clip it plays" do
    assert Music.from_media(recorded_media()) ==
             {:ok,
              %Music{
                kind: :licensed,
                url: song_url(),
                duration: 140.586,
                start: 1.5,
                clip_duration: 90.0,
                title: "Solace",
                artist: "Txmy"
              }}
  end

  test "muted music is no music" do
    assert music(should_mute: true) == {:none, "the music is muted"}
    assert music(mute_audio: true) == {:none, "the music is muted"}
  end

  test "uses the fast-start URL when the progressive one is missing" do
    fast_start = "https://scontent.cdninstagram.com/o1/v/fast.mp4?oh=00_sig"
    assert {:ok, %Music{url: ^fast_start}} = music(url: nil, fast_start_url: fast_start)

    assert {:ok, %Music{url: ^fast_start}} =
             music(url: "http://scontent.cdninstagram.com/song.mp4", fast_start_url: fast_start)
  end

  test "never uses the preview or a DASH manifest" do
    # Only the preview (its place in the song is unknown), or only a DASH manifest.
    assert music(url: nil, fast_start_url: nil) == {:none, "no song file"}
    assert music(url: 42, fast_start_url: "") == {:none, "no song file"}
  end

  test "a song off Instagram's CDN is not used; the reason names its host only" do
    assert {:none, reason} = music(url: "https://songs.evil.test/o1/song.mp4?oh=00_secret")
    assert reason == "the song is not on Instagram's CDN (songs.evil.test)"

    # Another candidate on the CDN wins.
    assert {:ok, %Music{url: url}} =
             music(url: "https://songs.evil.test/song.mp4", fast_start_url: song_url())

    assert url == song_url()
  end

  test "reads the clip window leniently" do
    assert {:ok, %Music{start: +0.0, clip_duration: nil}} = music(start_ms: -5, overlap_ms: 0)
    assert {:ok, %Music{start: +0.0, clip_duration: nil}} = music(start_ms: nil, overlap_ms: nil)

    assert {:ok, %Music{start: +0.0, clip_duration: nil}} =
             music(start_ms: "1500", overlap_ms: "9")

    assert {:ok, %Music{start: 30.25, clip_duration: 15.5}} =
             music(start_ms: 30_250, overlap_ms: 15_500)

    assert {:ok, %Music{duration: nil}} = music(duration_ms: 0)
  end

  test "reads an original sound from its start, as a whole" do
    assert music(audio_type: :original) ==
             {:ok,
              %Music{
                kind: :original,
                url: song_url(),
                duration: 140.586,
                start: 0.0,
                clip_duration: nil,
                title: "Original audio",
                artist: "someone"
              }}

    assert music(audio_type: :original, should_mute: true) == {:none, "the music is muted"}
    assert music(audio_type: :original, mute_audio: true) == {:none, "the music is muted"}
    assert music(audio_type: :original, url: nil) == {:none, "no song file"}
  end

  test "licensed music is read first, whatever the audio type says" do
    metadata =
      music_metadata()
      |> Map.put("audio_type", "original_sound")
      |> Map.put(
        "original_sound_info",
        music_metadata(audio_type: :original)["original_sound_info"]
      )

    assert {:ok, %Music{kind: :licensed}} = Music.from_media(with_music(%{}, metadata))
  end

  test "posts without music" do
    assert Music.from_media(with_music(recorded_media(), nil)) == {:none, "no music"}
    assert Music.from_media(%{}) == {:none, "no music"}

    assert Music.from_media(with_music(%{}, %{"music_info" => nil, "original_sound_info" => nil})) ==
             {:none, "no music"}

    # The logged-out answer has no music.
    %{"data" => %{"xig_polaris_media" => %{"if_not_gated_logged_out" => logged_out}}} =
      Jason.decode!(graphql("DdlJg0lFG8-"))

    assert Music.from_media(logged_out) == {:none, "no music"}
  end

  test "inspect/2 leaves out the signed URL" do
    assert {:ok, music} = Music.from_media(recorded_media())
    refute inspect(music) =~ "oh="
    refute inspect(music) =~ "song.mp4"
    assert inspect(music) =~ "Solace"
  end
end
