defmodule Angler.Media.InstagramMusicTest do
  # Photo posts with music: Angler.Media.Instagram.route/3 looking up the music with
  # the cookies file (Angler.Media.Instagram.Soundtrack), and Angler.Media.download/3
  # sending the post as a slideshow or an album. Changes the Angler.Media
  # application environment (the cookies file).
  use ExUnit.Case, async: false

  import Angler.InstagramFixtures
  import Angler.InstagramMusicFixtures
  import ExUnit.CaptureLog

  alias Angler.Media
  alias Angler.Media.{Download, Error, Instagram, Probe}
  alias Angler.Media.Instagram.{Music, Post}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @code "DdlJg0lFG8-"
  @url "https://www.instagram.com/p/DdlJg0lFG8-/?img_index=17&stkn=abc"

  setup %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "entry")
    File.mkdir_p!(dir)

    original = Application.get_env(:angler, Media)
    on_exit(fn -> Application.put_env(:angler, Media, original) end)

    put_media_env(
      data_dir: Path.join(tmp_dir, "data"),
      ytdlp_path: Path.join(tmp_dir, "no-yt-dlp"),
      cookies_file: nil,
      ytdlp_update_channel: nil,
      allow_private_networks: false
    )

    %{dir: dir, cookies: Path.join(tmp_dir, "cookies.txt")}
  end

  defp put_media_env(values) do
    Application.put_env(
      :angler,
      Media,
      Keyword.merge(Application.get_env(:angler, Media), values)
    )
  end

  defp use_cookies(path, opts \\ []) do
    File.write!(path, cookies_text(opts))
    put_media_env(cookies_file: path)
  end

  # The recorded post, logged out, and its media info through `info`; the CDN
  # through `cdn` (default: every file is its name, the song is refused).
  defp stub_post(info, cdn \\ &serve_cdn(&1, 403)) do
    stub_music(%{@code => graphql(@code)}, info, cdn)
  end

  defp serve_cdn(conn, song_status) do
    case Path.basename(conn.request_path) do
      "song.mp4" -> Plug.Conn.send_resp(conn, song_status, "")
      name -> bytes(conn, name)
    end
  end

  # The recorded media info item, with `music` as its music_metadata.
  defp info_with(music) do
    media = @code |> media_info() |> Jason.decode!() |> Map.fetch!("items") |> hd()
    media_info_answer(with_music(media, music))
  end

  # The requests the stub got, in order: {method, "host/path", conn}.
  defp requests do
    receive do
      {:instagram_request, method, path, conn} -> [{method, path, conn} | requests()]
    after
      0 -> []
    end
  end

  defp info_requests(requests) do
    Enum.filter(requests, fn {_method, path, _conn} -> path =~ "/api/v1/" end)
  end

  defp header(conn, name), do: Plug.Conn.get_req_header(conn, name)

  describe "with an Instagram session in the cookies file" do
    setup %{cookies: cookies} do
      use_cookies(cookies)
    end

    test "a photo carousel with music is a slideshow", %{dir: dir} do
      stub_post(&json(&1, media_info(@code)))

      assert {:slideshow, %Post{code: @code, items: [_, _, _]} = post, %Music{} = music} =
               Instagram.route(@url, dir)

      assert Enum.all?(post.items, &(&1.type == :photo))

      assert %Music{
               start: 1.5,
               clip_duration: 90.0,
               duration: 140.586,
               title: "Solace",
               artist: "Txmy",
               kind: :licensed
             } = music

      assert music.url == song_url()

      # The logged-out GraphQL request carries no cookies, the one info request does.
      assert [{"POST", "www.instagram.com/api/graphql", graphql}, {"GET", path, info}] =
               requests()

      assert header(graphql, "cookie") == []
      assert path == "www.instagram.com" <> info_path(@code)
      assert [cookie] = header(info, "cookie")
      assert "sessionid=S3SSION" in String.split(cookie, "; ")
      assert header(info, "x-csrftoken") == ["CSRF7"]
    end

    test "a single photo with music is a slideshow", %{dir: dir} do
      media = post([photo()], code: "Cphoto")

      stub_music(
        %{"Cphoto" => graphql_answer(media)},
        &json(&1, info_answer(media)),
        &serve_cdn(&1, 403)
      )

      assert {:slideshow, %Post{code: "Cphoto", items: [%{type: :photo}]}, %Music{start: 1.5}} =
               Instagram.route("https://www.instagram.com/p/Cphoto/", dir)

      assert [_info] = info_requests(requests())
    end

    test "carousels with a video and reels are never looked up", %{dir: dir} do
      stub_music(
        %{"DduKfFmDxsG" => graphql("DduKfFmDxsG"), "Chunk8-jurw" => graphql("Chunk8-jurw")},
        fn _conn -> flunk("unexpected media info request") end,
        &serve_cdn(&1, 403)
      )

      assert {:album, %Post{items: [%{type: :photo}, %{type: :video}]}} =
               Instagram.route("https://www.instagram.com/p/DduKfFmDxsG/", dir)

      assert {:ytdlp, "https://www.instagram.com/p/Chunk8-jurw/", _meta} =
               Instagram.route("https://www.instagram.com/reel/Chunk8-jurw/", dir)

      assert info_requests(requests()) == []
    end

    test "answers without usable music give an album after one request, even with retries left",
         %{dir: dir} do
      for info <- [
            &json(&1, info_with(music_metadata(should_mute: true))),
            &json(&1, info_with(music_metadata(mute_audio: true))),
            &json(&1, info_with(nil)),
            &json(&1, info_with(music_metadata(url: nil, fast_start_url: nil))),
            &json(&1, %{"items" => [], "num_results" => 0, "status" => "ok"}),
            &redirect(&1, "https://www.instagram.com/accounts/login/?next=%2Fapi%2Fv1%2F"),
            &redirect(&1, "https://www.instagram.com/challenge/?next=%2F"),
            &json(&1, %{"message" => "login_required", "require_login" => true}, 401),
            &Plug.Conn.send_resp(&1, 429, ""),
            &json(&1, %{"message" => "Please wait a few minutes", "require_login" => true}, 400),
            &Req.Test.html(&1, "<html>Log in</html>"),
            &Plug.Conn.send_resp(&1, 403, "")
          ] do
        stub_post(info)

        assert {:album, %Post{code: @code, items: [_, _, _]}} =
                 Instagram.route(@url, dir, final_attempt: false)

        assert [{"GET", _path, _conn}] = info_requests(requests())
      end
    end

    test "tells to export the cookies again when Instagram rejects the login", %{dir: dir} do
      stub_post(&redirect(&1, "https://www.instagram.com/accounts/login/?next=%2Fapi%2Fv1%2F"))

      log = capture_log(fn -> assert {:album, _post} = Instagram.route(@url, dir) end)

      assert log =~
               "Instagram did not accept the login in the cookies file (redirected to the " <>
                 "login page): photo posts are sent as albums until the cookies are exported again"

      # The redirect is never followed.
      assert [{"POST", _graphql, _}, {"GET", _info, _}] = requests()
    end

    test "a server error is retried, or gives the album on the final attempt", %{dir: dir} do
      stub_post(&json(&1, %{"status" => "fail"}, 500))

      assert Instagram.route(@url, dir, final_attempt: false) ==
               {:error,
                Error.new(
                  :transient,
                  "Could not look up the music of the Instagram post (HTTP 500)"
                )}

      log =
        capture_log(fn ->
          assert {:album, %Post{}} = Instagram.route(@url, dir, final_attempt: true)
        end)

      assert log =~ "Instagram post #{@code}: could not look up its music (HTTP 500)"
    end

    test "downloads the album when the CDN refuses the song on the final attempt", %{dir: dir} do
      stub_post(&json(&1, media_info(@code)))

      assert {:error,
              %Error{
                kind: :transient,
                message: "Could not download the slideshow sound (HTTP 403)"
              }} =
               Media.download(@url, Path.join(dir, "retried"),
                 target_bytes: 50_000_000,
                 final_attempt: false
               )

      assert {:ok, %Download{kind: :album, items: [_, _, _], extractor: "Instagram"}} =
               Media.download(@url, dir, target_bytes: 50_000_000)

      refute File.exists?(Path.join(dir, "album/sound"))

      # Only the media info request carries cookies; not the photos, not the song.
      requests = requests()
      assert Enum.any?(requests, fn {_method, path, _conn} -> path =~ "/song.mp4" end)

      for {_method, path, conn} <- requests,
          not (path =~ "/api/v1/"),
          do: assert(header(conn, "cookie") == [])
    end

    test "ffprobe running out of time on the song is retried, or gives the album on the final attempt",
         %{dir: dir, tmp_dir: tmp_dir} do
      # An ffprobe that never answers, stopped after 1 s.
      ffprobe = Path.join(tmp_dir, "ffprobe")
      File.write!(ffprobe, "#!/bin/sh\nexec sleep 30\n")
      File.chmod!(ffprobe, 0o755)
      put_media_env(ffprobe_path: ffprobe)
      Application.put_env(:angler, Probe, timeout: 1_000)
      on_exit(fn -> Application.delete_env(:angler, Probe) end)

      stub_post(&json(&1, media_info(@code)), &bytes(&1, Path.basename(&1.request_path)))

      assert {:error, %Error{kind: :timeout, message: "ffprobe took longer than 1 second"}} =
               Media.download(@url, Path.join(dir, "retried"),
                 target_bytes: 50_000_000,
                 final_attempt: false
               )

      log =
        capture_log(fn ->
          assert {:ok, %Download{kind: :album, items: [_, _, _]}} =
                   Media.download(@url, dir, target_bytes: 50_000_000)
        end)

      assert log =~
               "Instagram post #{@code}: ffprobe took longer than 1 second, " <>
                 "sending its photos as an album"

      refute File.exists?(Path.join(dir, "album/sound"))
    end

    test "logs no cookies, song or signed URLs", %{dir: dir, cookies: cookies} do
      # Debug and info lines too: the module changes the application environment
      # anyway, so no other test runs meanwhile.
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log(fn ->
          stub_post(&json(&1, media_info(@code)))
          assert {:slideshow, _post, _music} = Instagram.route(@url, dir)
          assert {:ok, %Download{kind: :album}} = Media.download(@url, dir, target_bytes: 1)

          for info <- [
                &redirect(&1, "https://www.instagram.com/accounts/login/?next=%2Fsecret"),
                &Plug.Conn.send_resp(&1, 500, ""),
                &Req.Test.transport_error(&1, :econnrefused),
                &json(&1, info_with(music_metadata(url: "https://evil.test/private.mp4?oh=x")))
              ] do
            stub_post(info)
            assert {:album, _post} = Instagram.route(@url, dir)
          end

          # Lookups tried again later log at debug level.
          for info <- [
                &Plug.Conn.send_resp(&1, 500, ""),
                &Req.Test.transport_error(&1, :econnrefused)
              ] do
            stub_post(info)

            assert {:error, %Error{kind: :transient}} =
                     Instagram.route(@url, dir, final_attempt: false)
          end

          use_cookies(cookies, instagram: false)
          stub_post(&json(&1, media_info(@code)))
          assert {:album, _post} = Instagram.route(@url, dir)
        end)

      # Info and debug lines were captured too.
      assert log =~ "Instagram post #{@code}: no usable music (the song is not on Instagram's CDN"
      assert log =~ "Instagram post #{@code}: could not look up its music (HTTP 500), retrying"
      assert log =~ "Instagram post #{@code}: no Instagram login in the cookies file"

      for secret <- ~w(S3SSION CSRF7 T1KTOK oh=00_sig oh=x song.mp4 private.mp4 secret) do
        refute log =~ secret
      end
    end
  end

  describe "without an Instagram session" do
    test "photo posts are albums, and nothing is looked up", %{dir: dir, cookies: cookies} do
      # Production logs at info level: a configured cookies file without a usable
      # Instagram login must say so there.
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      for {setup, logged?} <- [
            {fn -> put_media_env(cookies_file: nil) end, false},
            {fn -> use_cookies(cookies, instagram: false) end, true},
            {fn -> use_cookies(cookies, expires: 1_000_000) end, true},
            {fn -> put_media_env(cookies_file: Path.join(cookies, "missing.txt")) end, true}
          ] do
        setup.()
        stub_post(&json(&1, media_info(@code)))

        log =
          capture_log(fn ->
            assert {:album, %Post{code: @code, items: [_, _, _]}} = Instagram.route(@url, dir)
          end)

        assert [{"POST", "www.instagram.com/api/graphql", _conn}] = requests()

        message =
          "[info] Instagram post #{@code}: no Instagram login in the cookies file " <>
            "(or it has expired), sending it as an album"

        assert String.contains?(log, message) == logged?
      end
    end
  end

  defp info_answer(media), do: media_info_answer(with_music(media, music_metadata()))
end
