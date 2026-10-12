defmodule Angler.ThreadsFixtures do
  @moduledoc """
  Threads answers and a `Req.Test` stub (under the name `Angler.Media.Threads`) for
  tests of `Angler.Media.Threads`. Photos and videos come from Instagram's CDN, which
  is stubbed with `Angler.InstagramFixtures.stub_instagram/1`.

  `recorded/1` reads real answers (2026-10-12, logged out) trimmed to what matters
  and with the CDN signatures replaced by `REDACTED` (`test/fixtures/threads/`):

    * `page_photo_DeUWxGgjHSK.html`: a post page as served (one photo by @nasa),
      keeping one unrelated `data-sjs` blob and the one with the post
    * the post (`data.media` of the page's query answer) of each kind,
      `media_<kind>_<code>.json`, see `media/1`: `photo_DeUWxGgjHSK`,
      `video_DeMqtuYgkaL` (89 s), `carousel_Ddt7cL5EfUG` (7 photos and 2 videos),
      `photo_music_DePPcDfkc_a` (a photo with music, read from @nasa's profile
      page), `text_Dd1MqfcG0aH` and `quote_DeIqbp0lJAa` (posts without photos or
      videos)

  `page/1` wraps any post in a page like Threads serves it.
  """

  @fixtures Path.expand("../fixtures/threads", __DIR__)

  @doc "A recorded answer, e.g. `recorded(\"page_photo_DeUWxGgjHSK.html\")`."
  def recorded(name), do: File.read!(Path.join(@fixtures, name))

  @doc "The recorded post (decoded) with the code `code`, e.g. `media(\"DeUWxGgjHSK\")`."
  def media(code) do
    case Path.wildcard(Path.join(@fixtures, "media_*_#{code}.json")) do
      [path] -> path |> File.read!() |> Jason.decode!() |> get_in(["data", "media"])
      _other -> raise ArgumentError, "no recorded post #{code}"
    end
  end

  @doc """
  A post page (HTML) embedding `media` like Threads does: in a `data-sjs` blob as
  the result of the page's query, next to a blob of another post (related posts).
  """
  def page(media) do
    result = %{"data" => %{"media" => media, "viewer" => %{"user" => nil}}}
    related = %{"code" => "Crelated", "media_type" => 1, "caption" => %{"text" => "Other"}}

    blob = %{
      "require" => [
        [
          "ScheduledServerJS",
          "handle",
          nil,
          [
            %{
              "__bbox" => %{
                "require" => [
                  [
                    "RelayPrefetchedStreamCache@abc",
                    "next",
                    [],
                    [
                      "adp_BarcelonaPostPageTargetQueryRelayPreloader_1",
                      %{"__bbox" => %{"complete" => true, "result" => result}}
                    ]
                  ]
                ]
              }
            }
          ]
        ]
      ]
    }

    """
    <!DOCTYPE html><html><head><title>Threads</title>
    <script type="application/json" data-sjs>#{Jason.encode!(%{"related" => [related]})}</script>
    </head><body>
    <script type="application/json" nonce="x" data-sjs>#{Jason.encode!(blob)}</script>
    </body></html>
    """
  end

  @doc "The app shell Threads serves instead of a post page (no post data)."
  def shell do
    ~s(<!DOCTYPE html><html><head><title>Threads</title></head><body>) <>
      ~s(<script type="application/json" data-sjs>{"require":[]}</script></body></html>)
  end

  @doc """
  Stubs Threads with `handler` (called with the `Plug.Conn`). Every request is also
  sent to the calling process as `{:threads_request, method, "host/path", conn}`.
  """
  def stub_threads(handler) do
    test = self()

    Req.Test.stub(Angler.Media.Threads, fn conn ->
      send(test, {:threads_request, conn.method, conn.host <> conn.request_path, conn})
      handler.(conn)
    end)
  end

  @doc """
  Stubs Threads with the pages of posts: `%{"<code>" => media}` (a map, served with
  `page/1`) or `%{"<code>" => html}`. A post page of another code redirects to
  Threads' "invalid post" page; other requests answer HTTP 500.
  """
  def stub_pages(posts) do
    stub_threads(fn conn ->
      case Regex.run(~r"\A/(?:@[^/]+/post|t)/([^/]+)", conn.request_path) do
        [_path, code] ->
          case Map.get(posts, code) do
            nil ->
              Angler.InstagramFixtures.redirect(
                conn,
                "https://www.threads.com/?error=invalid_post"
              )

            html when is_binary(html) ->
              html(conn, html)

            media ->
              html(conn, page(media))
          end

        nil ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)
  end

  @doc "Responds with an HTML page."
  def html(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(status, body)
  end
end
