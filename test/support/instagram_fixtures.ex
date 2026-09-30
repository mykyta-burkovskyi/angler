defmodule Angler.InstagramFixtures do
  @moduledoc """
  Instagram answers and a `Req.Test` stub (under the name `Angler.Media.Instagram`)
  for tests of `Angler.Media.Instagram` and of Instagram album downloads.

  `recorded/1` reads real answers (2026-09-29) trimmed to what matters
  (`test/fixtures/instagram/`):

    * GraphQL answers, `graphql_<what>_<code>.json`: `photo_Ddwoj5kBk9X` (one
      2000x2500 photo), `carousel_3photos_DdwalmrkTSK`,
      `carousel_photo_video_DduKfFmDxsG`, `carousel_3videos_Ddr-AMmDxqn`,
      `carousel_12photos_DdulMV-D4cS`, `reel_Chunk8-jurw`, `not_found_DdwalmrkTSX`
      (`xig_polaris_media: null`) and `gated_pk123` (a region gate); see
      `graphql/1`
    * post pages: `page_carousel_DdwalmrkTSK.html` (the data blob only) and
      `page_not_found_DdwalmrkTSX.html` (Instagram's error page)
    * yt-dlp metadata lines (`--print-to-file "video:%()j"`):
      `ytdlp_carousel_photo_video_DduKfFmDxsG.jsonl`,
      `ytdlp_carousel_3photos_DdwalmrkTSK.jsonl`, `ytdlp_photo_Ddwoj5kBk9X.jsonl`

  `photo/1`, `video/1`, `post/2` and `graphql_answer/1` build answers of any shape.
  """

  alias Angler.Media.Instagram.Url

  @fixtures Path.expand("../fixtures/instagram", __DIR__)

  @doc "The path of a recorded answer."
  def fixture_path(name), do: Path.join(@fixtures, name)

  @doc "A recorded answer, e.g. `recorded(\"page_carousel_DdwalmrkTSK.html\")`."
  def recorded(name), do: File.read!(fixture_path(name))

  @doc "The recorded GraphQL answer (JSON text) for a post code, e.g. `\"DdwalmrkTSK\"`."
  def graphql(code) do
    case Path.wildcard(Path.join(@fixtures, "graphql_*_#{code}.json")) do
      [path] -> File.read!(path)
      _other -> raise ArgumentError, "no recorded GraphQL answer for #{code}"
    end
  end

  @doc "The recorded yt-dlp metadata (decoded lines) of a post code."
  def ytdlp_entries(code) do
    [path] = Path.wildcard(Path.join(@fixtures, "ytdlp_*_#{code}.jsonl"))
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  A photo item (`media_type` 1) with two candidates at
  `https://scontent.cdninstagram.com/v/<name>.jpg` (the original, then `_1080`).

  Options: `:name` (default "photo"), `:width`/`:height` (the original's, default
  1080x1350), `:code`.
  """
  def photo(opts \\ []) do
    name = Keyword.get(opts, :name, "photo")
    base = "https://scontent.cdninstagram.com/v/t51.82787-15/#{name}"

    %{
      "media_type" => 1,
      "code" => Keyword.get(opts, :code, "C" <> name),
      "original_width" => Keyword.get(opts, :width, 1080),
      "original_height" => Keyword.get(opts, :height, 1350),
      "image_versions2" => %{
        "candidates" => [
          %{"url" => base <> ".jpg?stp=dst-jpg_e35_tt6&oh=00_sig&oe=6AC1D6AC"},
          %{"url" => base <> "_1080.jpg?stp=dst-jpg_e35_p1080x1080_tt6&oh=00_sig&oe=6AC1D6AC"}
        ]
      }
    }
  end

  @doc """
  A video item (`media_type` 2) at `https://scontent.cdninstagram.com/o1/v/<name>.mp4`
  (listed three times, like Instagram does), with a DASH manifest giving its
  duration.

  Options: `:name` (default "video"), `:duration` (seconds, default 17.875),
  `:width`/`:height` (default 1080x1350), `:code`.
  """
  def video(opts \\ []) do
    name = Keyword.get(opts, :name, "video")

    url =
      "https://scontent.cdninstagram.com/o1/v/t16/f2/m84/#{name}.mp4?efg=x&oh=00_sig&oe=6AC1D6AC"

    duration = Keyword.get(opts, :duration, 17.875)

    %{
      "media_type" => 2,
      "code" => Keyword.get(opts, :code, "C" <> name),
      "original_width" => Keyword.get(opts, :width, 1080),
      "original_height" => Keyword.get(opts, :height, 1350),
      "image_versions2" => %{
        "candidates" => [
          %{
            "url" => "https://scontent.cdninstagram.com/v/#{name}.jpg",
            "width" => 720,
            "height" => 900
          }
        ]
      },
      "video_versions" => Enum.map([101, 102, 103], &%{"type" => &1, "url" => url}),
      "video_dash_manifest" =>
        ~s(<?xml version="1.0"?>\n<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" ) <>
          ~s(mediaPresentationDuration="PT#{duration}S"><Period duration="PT#{duration}S"></Period></MPD>)
    }
  end

  @doc """
  A post with `items` (made with `photo/1` and `video/1`): a carousel of several
  items, or the single item itself.

  Options: `:code` (default "Cpost"), `:caption` (default "Post text", nil for
  none), `:username` (default "someone").
  """
  def post(items, opts \\ []) do
    base =
      case items do
        [item] -> item
        items -> %{"media_type" => 8, "carousel_media" => items}
      end

    caption =
      case Keyword.get(opts, :caption, "Post text") do
        nil -> nil
        text -> %{"text" => text}
      end

    Map.merge(base, %{
      "code" => Keyword.get(opts, :code, "Cpost"),
      "caption" => caption,
      "user" => %{
        "username" => Keyword.get(opts, :username, "someone"),
        "full_name" => "Some One"
      }
    })
  end

  @doc "A GraphQL answer (JSON text) with `media` as the post."
  def graphql_answer(media) do
    Jason.encode!(%{
      "data" => %{
        "xig_polaris_media" => %{
          "__typename" => "XIGPolarisCarouselMedia",
          "code" => media["code"],
          "if_not_gated_logged_out" => media,
          "gating_ruling" => nil
        }
      },
      "extensions" => %{"is_final" => true}
    })
  end

  @doc """
  Stubs Instagram and its CDN with `handler` (called with the `Plug.Conn`). Every
  request is also sent to the calling process as
  `{:instagram_request, method, "host/path", conn}`.
  """
  def stub_instagram(handler) do
    test = self()

    Req.Test.stub(Angler.Media.Instagram, fn conn ->
      send(test, {:instagram_request, conn.method, conn.host <> conn.request_path, conn})
      handler.(conn)
    end)
  end

  @doc """
  Stubs Instagram's GraphQL API with the answers (JSON text) for post codes, e.g.
  `stub_graphql(%{"DdwalmrkTSK" => graphql("DdwalmrkTSK")})`. Other requests
  (post pages, the CDN) go to `other` (default: HTTP 500).
  """
  def stub_graphql(answers, other \\ &Plug.Conn.send_resp(&1, 500, "")) do
    by_pk = Map.new(answers, fn {code, answer} -> {Url.pk(code), answer} end)

    stub_instagram(fn conn ->
      case conn.request_path do
        "/api/graphql" ->
          {media_id, conn} = graphql_media_id(conn)
          javascript(conn, Map.fetch!(by_pk, media_id))

        _other ->
          other.(conn)
      end
    end)
  end

  @doc "Reads the media id a GraphQL request asks for: `{media_id, conn}`."
  def graphql_media_id(conn) do
    {params, conn} = form(conn)
    {params |> Map.fetch!("variables") |> Jason.decode!() |> Map.fetch!("media_id"), conn}
  end

  @doc "Reads a form request's parameters: `{params, conn}`."
  def form(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {URI.decode_query(body), conn}
  end

  @doc "Responds with `body` served as `text/javascript`, like the GraphQL API does."
  def javascript(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("text/javascript")
    |> Plug.Conn.send_resp(status, body)
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
