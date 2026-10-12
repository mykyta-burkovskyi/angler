defmodule Angler.Media.Threads do
  @moduledoc """
  Reads Threads posts, which yt-dlp can't (it has no Threads extractor), logged out
  and without cookies. Threads serves its posts in Instagram's shape, from
  Instagram's CDN, so they are delivered like Instagram posts.

  For a post link (`/@<user>/post/<code>`, `/t/<code>` and `/share/<token>` links on
  `threads.com` or `threads.net`, see `Angler.Media.Threads.Url`) `route/1`:

    1. recognizes the post's code, following share links with one request that
       reads the redirect location
    2. loads the post's page and reads the post from it
       (`Angler.Media.Threads.Page`), retried a few times when the page comes
       without it
    3. builds the post (`Angler.Media.Instagram.Post.from_media/1`, with `site:
       "Threads"`) and classifies it: a single video is downloaded from the CDN
       (`Angler.Media.Threads.Video`); a photo post (one photo, or photos only) is
       a slideshow when it has music (`Angler.Media.Threads.Music`, which Threads
       shows logged out), else an album; a post with a video among several items
       is an album. A post with neither (text, links, quotes, GIFs) is
       `:unsupported`.

  Only what the post itself shows is sent: not the other posts of a thread, a
  quoted post, or the target of a link.

  No request carries cookies or follows redirects (see `request/1`), and requests
  go only to `www.threads.com` URLs built from what `Url` parsed.

  Configuration (`config :angler, Angler.Media.Threads`): `:req_options` (extra
  `Req` options for every request to Threads; tests use
  `plug: {Req.Test, Angler.Media.Threads}`; the CDN is requested through
  `Angler.Media.Instagram.request/1`) and `:retry_delays` (milliseconds to wait
  before each new load of a page without the post, default `[1000, 2000]`).
  """
  require Logger

  alias Angler.Media.{Cookies, Error, Instagram}
  alias Angler.Media.Instagram.Post
  alias Angler.Media.Threads.{Music, Page, Url}

  @timeout 15_000
  @request_timeout 30_000
  @retry_delays [1_000, 2_000]
  @share_user_agent "curl/8.7.1"

  @expired_message "This Threads link has expired or is invalid"
  @missing_message "This Threads post is private, deleted or not shown to logged-out visitors"
  @no_media_message "This Threads post has no photos or videos"
  @rate_limited_message "Threads is rate limiting requests, trying again later"

  @type route ::
          :not_threads
          | {:video, Post.t()}
          | {:album, Post.t()}
          | {:slideshow, Post.t(), Instagram.Music.t()}
          | {:error, Error.t()}

  @doc """
  Decides how `Angler.Media.download/3` gets `url`, see the module documentation:

    * `:not_threads` - not a Threads post link; nothing was requested
    * `{:video, post}` - a single video (`Angler.Media.Threads.Video`)
    * `{:album, post}` - a photo post without (usable) music, or a post with a video
      among several items
    * `{:slideshow, post, music}` - a photo post with music
    * `{:error, error}` - `:unavailable` for expired share links and posts Threads
      doesn't show, `:unsupported` for posts without photos or videos,
      `:transient` when Threads could not be read (yet)
  """
  @spec route(String.t()) :: route()
  def route(url) do
    with {:ok, code, username} <- locate(url),
         {:ok, media} <- lookup(code, username),
         {:ok, post} <- build(media, code, username) do
      cond do
        not Post.album?(post) -> {:video, post}
        Post.photos?(post) -> photos(post, media)
        true -> {:album, post}
      end
    end
  end

  defp photos(post, media) do
    case Music.from_media(media) do
      {:ok, music} ->
        {:slideshow, post, music}

      {:none, "no music"} ->
        {:album, post}

      {:none, reason} ->
        Logger.info("Threads post #{post.code}: no usable music (#{reason}), sending an album")
        {:album, post}
    end
  end

  @doc """
  A `Req` request for Threads: no automatic retries, 15 s connect and receive
  timeouts, 30 s for the whole response, plus `options` and the configured
  `:req_options`. Redirects are never followed, whatever those options say.
  """
  @spec request(keyword()) :: Req.Request.t()
  def request(options) do
    [
      retry: false,
      redirect: false,
      receive_timeout: @timeout,
      connect_options: [timeout: @timeout],
      request_timeout: @request_timeout
    ]
    |> Keyword.merge(options)
    |> Req.new()
    |> Req.merge(config(:req_options, []))
    # Last, so neither `options` nor the configuration can turn redirects back on.
    |> Req.merge(redirect: false)
  end

  defp config(key, default) do
    :angler |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  ## Code

  defp locate(url) do
    case Url.parse(url) do
      {:post, code, username} -> {:ok, code, username}
      {:share, share_url} -> follow(share_url)
      :not_threads -> :not_threads
    end
  end

  # One request without following the redirect: live share links point to the
  # post (`/@<user>/post/<code>?xmt=...`) for clients that are not browsers;
  # invalid ones answer 200 with the app shell.
  defp follow(share_url) do
    request = request(url: share_url, headers: [{"user-agent", @share_user_agent}])

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        response |> Req.Response.get_header("location") |> List.first() |> shared(share_url)

      {:ok, %Req.Response{status: 200}} ->
        {:error, Error.new(:unavailable, @expired_message)}

      {:ok, %Req.Response{status: 429}} ->
        Logger.warning("Threads is rate limiting requests (share link)")
        {:error, Error.new(:transient, @rate_limited_message)}

      {:ok, %Req.Response{status: status}} ->
        share_failed("HTTP #{status}")

      {:error, exception} ->
        share_failed(Cookies.request_error(exception))
    end
  end

  defp shared(nil, _share_url), do: share_failed("no redirect location")

  defp shared(location, share_url) do
    location = share_url |> URI.merge(location) |> URI.to_string()

    case {Url.parse(location), URI.parse(location).path} do
      {{:post, code, username}, _path} ->
        {:ok, code, username}

      {_other, path} when path in [nil, "", "/"] ->
        {:error, Error.new(:unavailable, @expired_message)}

      {_other, "/login" <> _rest} ->
        share_failed("redirected to the login page")

      _other ->
        share_failed("redirected elsewhere")
    end
  end

  defp share_failed(reason) do
    message = "Could not open the Threads share link (#{reason})"
    Logger.warning(message)
    {:error, Error.new(:transient, message)}
  end

  ## Post

  defp lookup(code, username), do: lookup(code, username, config(:retry_delays, @retry_delays))

  defp lookup(code, username, delays) do
    case Page.fetch(code, username) do
      {:ok, media} ->
        {:ok, media}

      :missing ->
        {:error, Error.new(:unavailable, @missing_message)}

      {:rate_limited, reason} ->
        Logger.warning("Threads post #{code}: Threads is rate limiting requests (#{reason})")
        {:error, Error.new(:transient, @rate_limited_message)}

      {:gave_up, reason} ->
        case delays do
          [delay | rest] ->
            Logger.debug("Threads post #{code}: #{reason}, loading it again")
            Process.sleep(delay)
            lookup(code, username, rest)

          [] ->
            message = "Could not load the Threads post (#{reason})"
            Logger.warning("Threads post #{code}: #{message}")
            {:error, Error.new(:transient, message)}
        end
    end
  end

  defp build(media, code, username) do
    case Post.from_media(media) do
      {:ok, post} ->
        username = post.username || username
        {:ok, %{post | site: "Threads", code: code, webpage_url: Url.canonical(code, username)}}

      {:error, %Error{kind: :unsupported}} ->
        {:error, Error.new(:unsupported, @no_media_message)}
    end
  end
end
