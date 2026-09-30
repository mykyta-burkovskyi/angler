defmodule Angler.Media.Instagram.MediaInfo do
  @moduledoc """
  Reads a post through Instagram's logged-in media info API
  (`GET https://www.instagram.com/api/v1/media/<pk>/info/`, the request the website
  and yt-dlp make for a post when logged in). This is the only request in the
  app's own code that carries Instagram cookies: it is how the music of a photo
  post is read (`Angler.Media.Instagram.Music`), which Instagram shows only to
  logged-in visitors.

  `fetch/2` makes one request, and only when the cookies hold an Instagram
  session (an unexpired `sessionid` for `www.instagram.com`), with the headers
  the website sends (`x-csrftoken` from the `csrftoken` cookie). Like every
  request that carries cookies it never follows redirects, and describes network
  errors without the exception message (`Angler.Media.Cookies.request_error/1`).

  Failures (`t:failure/0`) come with fixed reasons, never with server text:

    * `:no_session` - no Instagram session in the cookies; nothing was requested
    * `:missing` - Instagram does not know the post (HTTP 404, no items, "Media
      not found")
    * `{:login_rejected, reason}` - Instagram did not accept the session: a
      redirect to the login page or a checkpoint, `login_required`,
      `checkpoint_required`, HTTP 401
    * `{:rate_limited, reason}` - HTTP 429, "Please wait a few minutes",
      `feedback_required`; checked before the signs of a rejected login, which
      Instagram's rate limit answers also carry (`require_login: true`)
    * `{:unexpected, reason}` - an answer of another shape or about another post,
      another redirect or HTTP error
    * `{:unreachable, reason}` - a network error, HTTP 408 or a server error:
      worth asking again later

  This module logs nothing; the caller logs the post code and the reason. The
  cookie header, the redirect location and response bodies are neither logged
  nor returned.
  """

  alias Angler.Media.{Cookies, Instagram}
  alias Angler.Media.Cookies.Cookie
  alias Angler.Media.Instagram.Url

  @wait_re ~r/please wait a few minutes/i
  @missing_re ~r/media not found|invalid media_id/i
  @checkpoints ["checkpoint_required", "challenge_required"]

  @type failure ::
          :no_session
          | :missing
          | {:login_rejected, String.t()}
          | {:rate_limited, String.t()}
          | {:unexpected, String.t()}
          | {:unreachable, String.t()}

  @doc "The media info URL of the post `code` (`.../api/v1/media/<pk>/info/`)."
  @spec url(String.t()) :: String.t()
  def url(code), do: "https://www.instagram.com/api/v1/media/#{Url.pk(code)}/info/"

  @doc """
  Asks for the post `code` with `cookies` (the cookies file's,
  `Angler.Media.Cookies.load/0`) and returns its media: `items[0]` of the answer,
  which has the shape of the logged-out post data
  (`Angler.Media.Instagram.Post.from_media/1`) plus `music_metadata`. The media's
  `pk` or `code` must be the post's. See the module documentation for the
  failures.
  """
  @spec fetch(String.t(), [Cookie.t()]) :: {:ok, map()} | {:error, failure()}
  def fetch(code, cookies) do
    url = url(code)
    header = Cookies.header(cookies, url)

    if cookie_value(header, "sessionid") do
      [url: url, headers: headers(header), decode_body: false]
      |> Instagram.request()
      |> Req.request()
      |> classify(url, code)
    else
      {:error, :no_session}
    end
  end

  defp headers(cookie) do
    csrf = cookie_value(cookie, "csrftoken")

    [
      {"user-agent", Instagram.user_agent()},
      {"accept", "*/*"},
      {"accept-language", "en-US,en;q=0.9"},
      {"origin", "https://www.instagram.com"},
      {"referer", "https://www.instagram.com/"},
      {"x-ig-app-id", Instagram.app_id()},
      {"x-asbd-id", Instagram.asbd_id()},
      {"x-ig-www-claim", "0"},
      {"x-requested-with", "XMLHttpRequest"},
      {"sec-fetch-site", "same-origin"},
      {"sec-fetch-mode", "cors"},
      {"sec-fetch-dest", "empty"},
      {"cookie", cookie}
    ] ++ if(csrf, do: [{"x-csrftoken", csrf}], else: [])
  end

  # A non-empty value from a `Cookies.header/2` result, or nil.
  defp cookie_value(nil, _name), do: nil

  defp cookie_value(header, name) do
    header
    |> String.split("; ")
    |> Enum.find_value(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [^name, value] when value != "" -> value
        _other -> nil
      end
    end)
  end

  defp classify({:ok, %Req.Response{status: 200, body: body}}, _url, code) do
    case decode(body) do
      {:ok, %{"items" => [%{} = media | _rest]}} ->
        if same_post?(media, code),
          do: {:ok, media},
          else: {:error, {:unexpected, "the answer is about another post"}}

      {:ok, %{"items" => []}} ->
        {:error, :missing}

      {:ok, %{} = answer} ->
        {:error, refusal(answer, 200) || {:unexpected, "unexpected answer"}}

      {:ok, _other} ->
        {:error, {:unexpected, "unexpected answer"}}

      :error ->
        {:error, {:unexpected, "the answer is not JSON"}}
    end
  end

  defp classify({:ok, %Req.Response{status: status} = response}, url, _code)
       when status in 300..399,
       do: {:error, redirect(response, url)}

  defp classify({:ok, %Req.Response{status: 429}}, _url, _code),
    do: {:error, {:rate_limited, "HTTP 429"}}

  defp classify({:ok, %Req.Response{status: status, body: body}}, _url, _code)
       when status in 400..499 do
    answer =
      case decode(body) do
        {:ok, %{} = answer} -> answer
        _other -> %{}
      end

    {:error, refusal(answer, status) || {:unexpected, "HTTP #{status}"}}
  end

  defp classify({:ok, %Req.Response{status: status}}, _url, _code) when status >= 500,
    do: {:error, {:unreachable, "HTTP #{status}"}}

  defp classify({:ok, %Req.Response{status: status}}, _url, _code),
    do: {:error, {:unexpected, "HTTP #{status}"}}

  defp classify({:error, exception}, _url, _code),
    do: {:error, {:unreachable, Cookies.request_error(exception)}}

  defp decode(body) do
    case is_binary(body) && Jason.decode(body) do
      {:ok, answer} -> {:ok, answer}
      _not_json -> :error
    end
  end

  defp same_post?(media, code), do: pk(media["pk"]) == Url.pk(code) or media["code"] == code

  defp pk(pk) when is_binary(pk), do: pk
  defp pk(pk) when is_integer(pk), do: Integer.to_string(pk)
  defp pk(_pk), do: nil

  # Why Instagram refused, from an error answer (or a 200 answer with a message),
  # in this order: rate limits, checkpoints, logins, missing posts. nil when none
  # of these applies. Only fixed texts, never the server's.
  defp refusal(answer, status) do
    message = if is_binary(answer["message"]), do: answer["message"], else: ""

    cond do
      message =~ @wait_re ->
        {:rate_limited, "HTTP #{status}, please wait"}

      message == "feedback_required" or answer["spam"] == true ->
        {:rate_limited, "HTTP #{status}, feedback_required"}

      message in @checkpoints or answer["checkpoint_url"] != nil or answer["challenge"] != nil ->
        checkpoint = if message in @checkpoints, do: message, else: "checkpoint_required"
        {:login_rejected, "HTTP #{status}, #{checkpoint}"}

      message == "login_required" or answer["require_login"] == true or status == 401 ->
        {:login_rejected, "HTTP #{status}, login required"}

      status == 404 or message =~ @missing_re ->
        :missing

      status == 408 ->
        {:unreachable, "HTTP 408"}

      true ->
        nil
    end
  end

  # The location stays out of the reason: it may carry the post's URL and tokens.
  defp redirect(response, url) do
    location = response |> Req.Response.get_header("location") |> List.first()
    path = location && URI.merge(url, location).path

    cond do
      location in [nil, ""] ->
        {:unexpected, "redirected with HTTP #{response.status}"}

      path in [nil, "", "/"] or String.starts_with?(path, "/accounts/login") ->
        {:login_rejected, "redirected to the login page"}

      String.starts_with?(path, ["/challenge", "/accounts/suspended"]) ->
        {:login_rejected, "redirected to a checkpoint"}

      true ->
        {:unexpected, "redirected with HTTP #{response.status}"}
    end
  end
end
