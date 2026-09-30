defmodule Angler.Media.Instagram do
  @moduledoc """
  Reads Instagram posts before yt-dlp sees a link, so that photos and carousels
  can be sent as they are (an album, `Angler.Media.Instagram.Post`): yt-dlp only
  downloads a post's videos, and only the first one of a carousel.

  For a post link (`/p/`, `/reel/`, `/tv/` and `/share/` links, see
  `Angler.Media.Instagram.Url`) `route/3`:

    1. recognizes the post's shortcode, following share links with one request
       that reads the redirect location
    2. asks Instagram's logged-out GraphQL API for the post
       (`Angler.Media.Instagram.GraphQL`, retried a few times), then, if that gave
       up, loads the post page and reads the same data from it
       (`Angler.Media.Instagram.Page`)
    3. falls back to yt-dlp's metadata of the post (`Angler.Media.Ytdlp.metadata/3`)
       when both gave up, and when Instagram hides the post from logged-out
       visitors or rate limits them but a cookies file is configured: yt-dlp gets
       the cookies, so this is where they are used. Without cookies such posts
       fail at once (hidden: `:unavailable`, rate limited: `:transient`)
    4. classifies the post: one with photos or several items is an album, a
       single video (a reel) goes to yt-dlp with the post text as its title

  There is no blind yt-dlp download of a link the resolver could not read: it
  would deliver a carousel as its first video.

  Cookies are never sent with this module's own requests, which also never
  follow redirects (see `request/1`).

  Configuration (`config :angler, Angler.Media.Instagram`): `:req_options` (extra
  `Req` options for every request to Instagram and its CDN; tests use
  `plug: {Req.Test, Angler.Media.Instagram}`) and `:retry_delays` (milliseconds to
  wait before each retry of a failed GraphQL request, default `[1000, 2000]`).
  """
  require Logger

  alias Angler.Media.{Cookies, Error, Ytdlp}
  alias Angler.Media.Instagram.{GraphQL, Page, Post, Url}

  @timeout 15_000
  @request_timeout 30_000
  @retry_delays [1_000, 2_000]
  @share_user_agent "curl/8.7.1"

  @expired_message "This Instagram link has expired or is invalid"
  @hidden_message "This Instagram post is private, deleted or age-restricted"
  @rate_limited_message "Instagram is rate limiting requests, trying again later"

  @type route ::
          :not_instagram
          | {:album, Post.t()}
          | {:ytdlp, String.t(), %{title: String.t() | nil}}
          | {:error, Error.t()}

  @doc """
  Decides how `Angler.Media.download/3` gets `url`, see the module documentation:

    * `:not_instagram` - not an Instagram post link; nothing was requested
    * `{:album, post}` - a post with photos or several items
    * `{:ytdlp, url, %{title: text}}` - a single video: the canonical post URL for
      yt-dlp, and the post text (or nil)
    * `{:error, error}` - `:unavailable` for expired share links and hidden posts
      (without cookies), `:transient` when Instagram could not be read (yet)

  `dir` is the entry directory yt-dlp's metadata run uses. Options:
  `:final_attempt` (default true): unless set, a post yt-dlp found nothing in is
  retried (`:transient`) instead of failing as `:unavailable`.
  """
  @spec route(String.t(), Path.t(), keyword()) :: route()
  def route(url, dir, opts \\ []) do
    with {:ok, code} <- locate(url),
         {:ok, post} <- lookup(code, dir, opts) do
      if Post.album?(post),
        do: {:album, post},
        else: {:ytdlp, Url.canonical(code), %{title: post.caption}}
    end
  end

  @doc """
  A `Req` request for Instagram or its CDN: no automatic retries, 15 s connect and
  receive timeouts, 30 s for the whole response, plus `options` and the
  configured `:req_options`. Redirects are never followed, whatever those options
  say.
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

  ## Shortcode

  defp locate(url) do
    case Url.parse(url) do
      {:post, code} -> {:ok, code}
      {:share, share_url} -> follow(share_url)
      :not_instagram -> :not_instagram
    end
  end

  # One request without following the redirect: live share links point to the
  # post (`/p/<code>/?igsh=...`), invalid ones answer 200 with the home page.
  defp follow(share_url) do
    request = request(url: share_url, headers: [{"user-agent", @share_user_agent}])

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        response |> Req.Response.get_header("location") |> List.first() |> shared(share_url)

      {:ok, %Req.Response{status: 200}} ->
        {:error, Error.new(:unavailable, @expired_message)}

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
      {{:post, code}, _path} ->
        {:ok, code}

      {_other, path} when path in [nil, "", "/"] ->
        {:error, Error.new(:unavailable, @expired_message)}

      {_other, "/accounts/login" <> _rest} ->
        share_failed("redirected to the login page")

      _other ->
        share_failed("redirected elsewhere")
    end
  end

  defp share_failed(reason) do
    message = "Could not open the Instagram share link (#{reason})"
    Logger.warning(message)
    {:error, Error.new(:transient, message)}
  end

  ## Post

  defp lookup(code, dir, opts) do
    case GraphQL.fetch(code, config(:retry_delays, @retry_delays)) do
      {:gave_up, reason} ->
        Logger.info("Instagram post #{code}: GraphQL gave up (#{reason}), loading its page")
        found(Page.fetch(code), code, dir, opts)

      result ->
        found(result, code, dir, opts)
    end
  end

  defp found({:ok, media}, code, dir, opts) do
    case Post.from_media(media) do
      {:ok, post} ->
        {:ok, with_code(post, code)}

      # Instagram's data changed shape rather than the post having nothing in it.
      {:error, error} ->
        Logger.warning("Instagram post #{code}: #{error.message} in Instagram's data")
        metadata(code, dir, opts)
    end
  end

  defp found({:gated, title}, code, dir, opts),
    do: hidden(title || @hidden_message, code, dir, opts)

  defp found(:missing, code, dir, opts), do: hidden(@hidden_message, code, dir, opts)

  defp found({:rate_limited, reason}, code, dir, opts) do
    Logger.warning("Instagram post #{code}: Instagram is rate limiting requests (#{reason})")

    if Cookies.configured?(),
      do: metadata(code, dir, opts),
      else: {:error, Error.new(:transient, @rate_limited_message)}
  end

  defp found({:gave_up, reason}, code, dir, opts) do
    Logger.warning("Instagram post #{code}: could not read it (#{reason}), asking yt-dlp")
    metadata(code, dir, opts)
  end

  # Logged out, Instagram hides the post: with cookies, yt-dlp may see it.
  defp hidden(message, code, dir, opts) do
    if Cookies.configured?(),
      do: metadata(code, dir, opts),
      else: {:error, Error.new(:unavailable, message)}
  end

  defp metadata(code, dir, opts) do
    case Ytdlp.metadata(Url.canonical(code), dir) do
      {:ok, entries} ->
        with {:ok, post} <- Post.from_ytdlp(entries), do: {:ok, with_code(post, code)}

      # yt-dlp's "no video" answers: Instagram gave it nothing usable (this time).
      {:error, %Error{kind: :unsupported} = error} ->
        kind = if Keyword.get(opts, :final_attempt, true), do: :unavailable, else: :transient
        message = "Could not load the Instagram post (#{error.message})"
        {:error, Error.new(kind, message, error.output)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp with_code(%Post{} = post, code) do
    %{post | code: post.code || code, webpage_url: post.webpage_url || Url.canonical(code)}
  end
end
