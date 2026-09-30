defmodule Angler.Media.TikTok do
  @moduledoc """
  Tells TikTok photo posts (slideshows) from videos before yt-dlp sees a link.

  yt-dlp answers "Unsupported URL" for `/photo/` links (and photo short links) and
  returns only the sound for slideshows behind `/video/` links. So for TikTok links
  `resolve/1`:

    1. recognizes the post id, following short links (`vm.`/`vt.tiktok.com/<code>`,
       `tiktok.com/t/<code>`) with one request that reads the redirect location
    2. loads `https://www.tiktok.com/@/video/<id>` and reads the post from the page
       (`Angler.Media.TikTok.Page`, which also solves TikTok's proof-of-work page,
       and loads it once more with the cookies file when TikTok hides the post
       from logged-out visitors or the page can't be read; short links are always
       followed without cookies)
    3. classifies it: a post with images is a slideshow (`Angler.Media.TikTok.Post`,
       assembled into a video by `Angler.Media.Slideshow`); anything else is a video
       whose canonical `/video/` URL goes to yt-dlp

  `route/1` adds the fallback that keeps regular videos as reliable as before: when
  the page can't be loaded (network errors, challenges, page changes), links not
  known to be photo posts still go to yt-dlp as they are.

  Configuration (`config :angler, Angler.Media.TikTok`): `:req_options` (extra `Req`
  options for every request to TikTok and its CDN; tests use
  `plug: {Req.Test, Angler.Media.TikTok}`) and `:retry_delays` (milliseconds to wait
  before the second and third page load, default `[1000, 2000]`).
  """
  require Logger

  alias Angler.Media
  alias Angler.Media.Error
  alias Angler.Media.TikTok.{Page, Post, Url}

  @timeout 15_000
  @retry_delays [1_000, 2_000]
  @short_link_user_agent "facebookexternalhit/1.1"

  @expired_message "This TikTok link has expired or is invalid"
  @deleted_message "This TikTok post was deleted"
  @private_message "This TikTok post is private"
  @login_message "TikTok requires login to view this post"

  @type resolution ::
          {:ok, :video, String.t()}
          | {:ok, {:slideshow, Post.t()}}
          | {:error, Error.t()}
          | :not_tiktok

  @doc """
  Resolves a TikTok link, see the module documentation. Returns `:not_tiktok` for
  links that are not TikTok posts (other sites, profiles, music pages, ...).

  Errors: `:unavailable` for expired short links and deleted, private or login-only
  posts; `:transient` when TikTok could not be reached or its page not read after
  three attempts.
  """
  @spec resolve(String.t()) :: resolution()
  def resolve(url) do
    case locate(url) do
      {:ok, id, _kind} -> lookup(id)
      {:other, location} -> {:ok, :video, location}
      other -> other
    end
  end

  @doc """
  Decides how `Angler.Media.download/3` gets `url`: `{:ytdlp, url}` (the canonical
  URL of a TikTok video, or `url` itself), `{:slideshow, post}`, or an error.

  When resolving fails with an error that may not be final (anything but a deleted
  post or an expired link; private and login-only posts count too when a yt-dlp
  cookies file is configured) and the link is not known to be a photo post, the
  original link goes to yt-dlp, as it did before slideshows were supported.
  """
  @spec route(String.t()) :: {:ytdlp, String.t()} | {:slideshow, Post.t()} | {:error, Error.t()}
  def route(url) do
    case locate(url) do
      {:ok, id, kind} ->
        case lookup(id) do
          {:ok, :video, canonical_url} -> {:ytdlp, canonical_url}
          {:ok, {:slideshow, post}} -> {:slideshow, post}
          {:error, error} -> fallback(url, kind, error)
        end

      {:error, error} ->
        fallback(url, :unknown, error)

      _not_a_post ->
        {:ytdlp, url}
    end
  end

  defp fallback(url, kind, %Error{} = error) do
    if kind != :photo and not final?(error) do
      Logger.info("TikTok lookup failed (#{error.message}), handing the link to yt-dlp")
      {:ytdlp, url}
    else
      {:error, error}
    end
  end

  defp final?(%Error{kind: :unavailable, message: message})
       when message in [@private_message, @login_message],
       do: is_nil(Media.config(:cookies_file))

  defp final?(%Error{kind: kind}), do: kind == :unavailable

  @doc "Recognizes a TikTok link without network access, see `Angler.Media.TikTok.Url.parse/1`."
  @spec parse_url(String.t()) :: Url.parsed()
  defdelegate parse_url(url), to: Url, as: :parse

  @doc "The URL yt-dlp gets for a TikTok video: `https://www.tiktok.com/@/video/<id>`."
  @spec canonical_url(String.t()) :: String.t()
  defdelegate canonical_url(id), to: Url, as: :canonical

  @doc """
  A `Req` request for TikTok or its CDN: no automatic retries or redirects, 15 s
  connect and receive timeouts, plus the configured `:req_options`.
  """
  @spec request(keyword()) :: Req.Request.t()
  def request(options) do
    [
      retry: false,
      redirect: false,
      receive_timeout: @timeout,
      connect_options: [timeout: @timeout]
    ]
    |> Keyword.merge(options)
    |> Req.new()
    |> Req.merge(config(:req_options, []))
  end

  defp config(key, default) do
    :angler |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  ## Post id

  defp locate(url) do
    case parse_url(url) do
      {:post, id, kind} -> {:ok, id, kind}
      {:short, short_url} -> follow(short_url)
      :not_tiktok -> :not_tiktok
    end
  end

  # One request without following the redirect: live links point to
  # /@/video/<id> or /@/photo/<id>, expired ones to https://www.tiktok.com/?_r=1.
  defp follow(short_url) do
    request = request(url: short_url, headers: [{"user-agent", @short_link_user_agent}])

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        response |> Req.Response.get_header("location") |> List.first() |> located(short_url)

      {:ok, %Req.Response{status: 404}} ->
        {:error, Error.new(:unavailable, @expired_message)}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.new(:transient, "TikTok short link answered with HTTP #{status}")}

      {:error, exception} ->
        {:error,
         Error.new(:transient, "Could not reach TikTok: " <> Exception.message(exception))}
    end
  end

  defp located(nil, _short_url),
    do: {:error, Error.new(:transient, "TikTok short link did not redirect")}

  defp located(location, short_url) do
    location = short_url |> URI.merge(location) |> URI.to_string()

    case parse_url(location) do
      {:post, id, kind} ->
        {:ok, id, kind}

      _other ->
        if URI.parse(location).path in [nil, "", "/"],
          do: {:error, Error.new(:unavailable, @expired_message)},
          else: {:other, location}
    end
  end

  ## Post page

  defp lookup(id) do
    case Page.fetch(canonical_url(id), config(:retry_delays, @retry_delays)) do
      {:ok, item} ->
        if Post.slideshow?(item),
          do: {:ok, {:slideshow, Post.from_item(item, id)}},
          else: {:ok, :video, canonical_url(id)}

      {:error, :deleted} ->
        {:error, Error.new(:unavailable, @deleted_message)}

      {:error, :private} ->
        {:error, Error.new(:unavailable, @private_message)}

      {:error, :login_required} ->
        {:error, Error.new(:unavailable, @login_message)}

      {:error, {:status, code}} ->
        {:error, Error.new(:unavailable, "This TikTok post is not available (status #{code})")}

      {:error, {:gave_up, reason}} ->
        Logger.warning("TikTok post #{id}: could not read its page (#{reason})")
        {:error, Error.new(:transient, "Could not load the TikTok post (#{reason})")}
    end
  end
end
