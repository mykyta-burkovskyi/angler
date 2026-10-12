defmodule Angler.Media.Threads.Page do
  @moduledoc """
  Reads a Threads post from its page (`https://www.threads.com/@<user>/post/<code>`),
  logged out and without cookies.

  Loaded like a browser navigation (`accept: text/html...` and `sec-fetch-*`
  headers; without them Threads serves an app shell without data), the page embeds
  the answer of the query the website shows the post with in one of its
  `<script type="application/json" data-sjs>` blobs (a `RelayPrefetchedStreamCache`
  entry): `data.media`, a post in Instagram's shape (`code`, `media_type`,
  `image_versions2`, `video_versions`, `carousel_media`, `caption`, `user`, ...).

  The post is found by its code and shape, not by the query's name (Meta renames
  them): the blobs mentioning the code are decoded, and the post is the
  `data.media` with that code, else any object with that code and a `media_type`
  (other blobs hold related posts of other users).

  A missing post (deleted, private, or never shown logged out) redirects to
  `https://www.threads.com/?error=invalid_post`. A page for another username, a
  `/t/<code>` page and other hosts redirect to the post's canonical page; one such
  redirect to the same post on `www.threads.com` is followed, no other.
  """

  alias Angler.Media.{Cookies, Instagram, Threads}
  alias Angler.Media.Threads.Url

  @blob_re ~r/<script\b[^>]*\bdata-sjs\b[^>]*>(.*?)<\/script>/s
  @headers [
    {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
    {"accept-language", "en-US,en;q=0.9"},
    {"sec-fetch-dest", "document"},
    {"sec-fetch-mode", "navigate"},
    {"sec-fetch-site", "none"},
    {"sec-fetch-user", "?1"},
    {"upgrade-insecure-requests", "1"}
  ]

  @type result ::
          {:ok, map()} | :missing | {:rate_limited, String.t()} | {:gave_up, String.t()}

  @doc """
  Loads the page of the post `code` (by `username`, or by its `/t/` link when nil)
  and reads the post from it (see `read/2`): the post's media map, `:missing`,
  `{:rate_limited, reason}` (HTTP 429), or `{:gave_up, reason}` when the page could
  not be loaded or held no post.
  """
  @spec fetch(String.t(), String.t() | nil) :: result()
  def fetch(code, username), do: load(Url.canonical(code, username), code, 1)

  defp load(url, code, redirects) do
    headers = [{"user-agent", Instagram.user_agent()} | @headers]

    case Req.request(Threads.request(url: url, headers: headers)) do
      {:ok, %Req.Response{status: 200, body: html}} when is_binary(html) ->
        read(html, code)

      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        response
        |> Req.Response.get_header("location")
        |> List.first()
        |> redirected(url, code, redirects)

      {:ok, %Req.Response{status: 429}} ->
        {:rate_limited, "the post page answered with HTTP 429"}

      {:ok, %Req.Response{status: status}} ->
        {:gave_up, "the post page answered with HTTP #{status}"}

      {:error, exception} ->
        {:gave_up, "the post page: " <> Cookies.request_error(exception)}
    end
  end

  defp redirected(nil, _url, _code, _redirects),
    do: {:gave_up, "the post page redirected without a location"}

  defp redirected(location, url, code, redirects) do
    %URI{host: host, path: path} = target = URI.merge(url, location)

    cond do
      path in [nil, "", "/"] ->
        :missing

      path =~ ~r{\A/(?:accounts/)?login(?:/|\z)} ->
        {:gave_up, "the post page redirected to the login page"}

      redirects > 0 and host == "www.threads.com" ->
        case Url.parse(URI.to_string(target)) do
          {:post, ^code, username} when is_binary(username) ->
            load(Url.canonical(code, username), code, redirects - 1)

          _other ->
            {:gave_up, "the post page redirected elsewhere"}
        end

      true ->
        {:gave_up, "the post page redirected elsewhere"}
    end
  end

  @doc """
  Reads the post `code` from a post page: `{:ok, media}`, `:missing` when Threads
  marks the post unavailable (`text_post_app_info.is_post_unavailable`), or
  `{:gave_up, reason}` for a page without the post (an app shell: Threads served
  the page without data this time, or changed it).
  """
  @spec read(String.t(), String.t()) :: {:ok, map()} | :missing | {:gave_up, String.t()}
  def read(html, code) when is_binary(html) do
    blobs =
      @blob_re
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(&hd/1)
      |> Enum.filter(&String.contains?(&1, ~s("#{code}")))
      |> Enum.map(&decode/1)

    media = Enum.find_value(blobs, &target(&1, code)) || Enum.find_value(blobs, &post(&1, code))

    cond do
      is_map(media) and unavailable?(media) -> :missing
      is_map(media) -> {:ok, media}
      true -> {:gave_up, "no post data in the post page"}
    end
  end

  defp decode(blob) do
    case Jason.decode(blob) do
      {:ok, json} -> json
      {:error, _invalid} -> nil
    end
  end

  # The answer of the page's own query: `data.media` with this code.
  defp target(%{"data" => %{"media" => %{"code" => code} = media}}, code), do: media
  defp target(%{} = map, code), do: map |> Map.values() |> target(code)
  defp target(list, code) when is_list(list), do: Enum.find_value(list, &target(&1, code))
  defp target(_value, _code), do: nil

  # Anywhere else: an object with this code and a media type.
  defp post(%{"code" => code, "media_type" => type} = media, code) when is_integer(type),
    do: media

  defp post(%{} = map, code), do: map |> Map.values() |> post(code)
  defp post(list, code) when is_list(list), do: Enum.find_value(list, &post(&1, code))
  defp post(_value, _code), do: nil

  defp unavailable?(media) do
    match?(%{"text_post_app_info" => %{"is_post_unavailable" => true}}, media)
  end
end
