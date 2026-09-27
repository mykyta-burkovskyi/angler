defmodule Angler.TikTokFixtures do
  @moduledoc """
  TikTok pages and a `Req.Test` stub (under the name `Angler.Media.TikTok`) for
  tests of `Angler.Media.TikTok` and `Angler.Media.Slideshow`.

  `recorded_page/1` returns real post pages trimmed to what matters
  (`test/fixtures/tiktok/*.html`): `"slideshow_page"` (natgeo, 4 landscape images
  and an AAC sound) and `"silent_slideshow_page"` (12 images, `playUrl` "").
  `page/1` builds a page around any `webapp.video-detail`.
  """

  @fixtures Path.expand("../fixtures/tiktok", __DIR__)

  @doc "A recorded, trimmed post page."
  def recorded_page(name), do: File.read!(Path.join(@fixtures, name <> ".html"))

  @doc "A post page carrying `detail` as its `webapp.video-detail` (escaped like TikTok does)."
  def page(detail) do
    json =
      %{
        "__DEFAULT_SCOPE__" => %{
          "webapp.app-context" => %{"language" => "en", "region" => "US"},
          "webapp.video-detail" => detail
        }
      }
      |> Jason.encode!()
      |> String.replace("/", "\\u002F")

    ~s(<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>TikTok</title></head>) <>
      ~s(<body><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">) <>
      json <> "</script></body></html>"
  end

  @doc "A `webapp.video-detail` with status 0 and `item`."
  def detail(item),
    do: %{"statusCode" => 0, "statusMsg" => "", "itemInfo" => %{"itemStruct" => item}}

  @doc "A `webapp.video-detail` with an error status."
  def status_detail(code), do: %{"statusCode" => code, "statusMsg" => "status #{code}"}

  @doc "The `itemStruct` of a regular video."
  def video_item(id) do
    %{
      "id" => id,
      "desc" => "I think Mom wanted to say it again",
      "author" => %{"uniqueId" => "memezar"},
      "video" => %{"playAddr" => "https://v16-webapp.tiktok.com/video/#{id}", "duration" => 11},
      "music" => %{"playUrl" => "https://v16m.tiktokcdn.com/audio/#{id}", "duration" => 11}
    }
  end

  @doc """
  The `itemStruct` of a photo post with `count` images at
  `https://p16.tiktokcdn.test/<id>/<n>.jpeg` (fallback host `p19`).

  Options: `:audio_url` (default a URL at `sf16.tiktokcdn.test`; `""` for none),
  `:duration` (music duration, default 16), `:precise` (default 16.33),
  `:desc` (default `"Photos from the match"`).
  """
  def slideshow_item(id, count, opts \\ []) do
    images =
      for n <- 1..count//1 do
        %{
          "imageURL" => %{
            "urlList" => [
              "https://p16.tiktokcdn.test/#{id}/#{n}.jpeg?x-signature=a",
              "https://p19.tiktokcdn.test/#{id}/#{n}.jpeg?x-signature=b"
            ]
          },
          "imageWidth" => 1080,
          "imageHeight" => 1440
        }
      end

    %{
      "id" => id,
      "desc" => Keyword.get(opts, :desc, "Photos from the match"),
      "author" => %{"uniqueId" => "hullcity"},
      "video" => %{"playAddr" => "", "duration" => 0},
      "imagePost" => %{"images" => images, "title" => ""},
      "music" => %{
        "playUrl" => Keyword.get(opts, :audio_url, "https://sf16.tiktokcdn.test/#{id}/sound"),
        "duration" => Keyword.get(opts, :duration, 16),
        "preciseDuration" => %{"preciseDuration" => Keyword.get(opts, :precise, 16.33)}
      }
    }
  end

  @doc """
  TikTok's proof-of-work page for answer `answer` (salt `"salt-123"`), with the
  `#wci`/`#rci`/`#rs` elements unless `extra: false`.
  """
  def challenge_page(answer, opts \\ []) do
    salt = "salt-123"
    digest = :crypto.hash(:sha256, salt <> Integer.to_string(answer))

    challenge =
      %{
        "v" => %{"a" => Base.encode64(salt), "c" => Base.encode64(digest)},
        "s" => "7c1d",
        "e" => 1_790_431_482
      }
      |> Jason.encode!()
      |> Base.encode64()

    extra =
      if Keyword.get(opts, :extra, true),
        do:
          ~s(<p id="wci" class="_wafchallengeid"></p><p id="rci" class="waforiginalreid"></p>) <>
            ~s(<p id="rs" class="rs-value-42"></p>),
        else: ""

    ~s(<!DOCTYPE html><html><head><title>Please wait...</title></head><body>) <>
      ~s(<div id="cs" class="#{challenge}"></div>#{extra}) <>
      ~s(<script>/* solver */</script></body></html>)
  end

  @doc """
  Stubs TikTok and its CDN with `handler` (called with the `Plug.Conn`). Every
  request is also sent to the calling process as
  `{:tiktok_request, method, "host/path", conn}`.
  """
  def stub_tiktok(handler) do
    test = self()

    Req.Test.stub(Angler.Media.TikTok, fn conn ->
      send(test, {:tiktok_request, conn.method, conn.host <> conn.request_path, conn})
      handler.(conn)
    end)
  end

  @doc "Responds with a redirect to `location`."
  def redirect(conn, location, status \\ 302) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(status, "")
  end

  @doc "Responds with `body` as bytes of `content_type`."
  def bytes(conn, body, content_type \\ "image/jpeg") do
    conn
    |> Plug.Conn.put_resp_content_type(content_type, nil)
    |> Plug.Conn.send_resp(200, body)
  end
end
