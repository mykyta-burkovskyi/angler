defmodule Angler.Media.TikTok.Page do
  @moduledoc """
  Loads a TikTok post page and reads the post (`itemStruct`) from its rehydration
  data: the JSON in `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">`, at
  `__DEFAULT_SCOPE__["webapp.video-detail"]`.

  Only the `/@/video/<id>` page carries that data (for photo posts too; the
  `/photo/` page does not). A Linux Chrome user agent gets the page without a
  challenge almost always; when TikTok serves its proof-of-work page instead, it is
  solved (`Angler.Media.TikTok.Challenge`) and the page loaded again with the
  answer cookies. A redirect means TikTok wants a login. No cookies are needed
  for public posts.

  The cookies file (`Angler.Media.Cookies`) is a fallback, never the first try:
  when the logged-out page says the post is private or needs a login, or could
  not be read at all, the page is loaded once more with the file's cookies for
  it (and a challenge answer, if TikTok asks again). A post from that load wins;
  anything else keeps the logged-out result, since a logged-in page may look
  different. Page loads never follow redirects, and describe network errors
  without the exception message (`Angler.Media.Cookies.request_error/1`).

  `webapp.video-detail.statusCode`: 0 is a post, 10204 a deleted post, 10216 and
  10222 private posts and accounts; anything else is reported as is.
  """
  require Logger

  alias Angler.Media.Cookies
  alias Angler.Media.TikTok
  alias Angler.Media.TikTok.Challenge

  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
                "Chrome/140.0.0.0 Safari/537.36"
  @data_re ~r{<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>}s
  @request_timeout 30_000

  @type failure ::
          :deleted | :private | :login_required | {:status, integer()} | {:gave_up, String.t()}

  @doc """
  Loads the post page at `url`, retrying network errors, unexpected responses and
  unsolved challenges once per entry of `retry_delays` (milliseconds to wait first).
  `{:gave_up, reason}` means every attempt failed that way.

  When the result is `:private`, `:login_required` or `{:gave_up, reason}` and the
  cookies file has cookies for `url`, the page is loaded once more with them (see
  the module documentation).
  """
  @spec fetch(String.t(), [non_neg_integer()]) :: {:ok, map()} | {:error, failure()}
  def fetch(url, retry_delays) do
    case logged_out(url, retry_delays) do
      {:error, reason} = result when reason in [:private, :login_required] ->
        with_cookies(url, result)

      {:error, {:gave_up, _reason}} = result ->
        with_cookies(url, result)

      result ->
        result
    end
  end

  defp logged_out(url, retry_delays) do
    case fetch_once(url, nil) do
      {:retry, reason} ->
        case retry_delays do
          [delay | rest] ->
            Logger.debug("TikTok page attempt failed (#{reason}), retrying in #{delay} ms")
            Process.sleep(delay)
            logged_out(url, rest)

          [] ->
            {:error, {:gave_up, reason}}
        end

      result ->
        result
    end
  end

  # The cookies travel as `Cookie` structs (their values hidden from inspect/2);
  # the header is only built for the request.
  defp with_cookies(url, logged_out) do
    cookies = Cookies.load()

    if Cookies.header(cookies, url) == nil do
      logged_out
    else
      case fetch_once(url, cookies) do
        {:ok, item} ->
          Logger.info("Read the TikTok post page with the cookies file")
          {:ok, item}

        _other ->
          Logger.info("The cookies file did not help to read the TikTok post page")
          logged_out
      end
    end
  end

  defp fetch_once(url, cookies) do
    with {:ok, html} <- get(url, cookies, nil) do
      case detail(html) do
        {:ok, detail} -> item(detail)
        :error -> solve_challenge(url, html, cookies)
      end
    end
  end

  defp solve_challenge(url, html, cookies) do
    case Challenge.solve(html) do
      {:ok, answer} ->
        Logger.debug("Solved the TikTok challenge")

        with {:ok, html} <- get(url, cookies, answer) do
          case detail(html) do
            {:ok, detail} -> item(detail)
            :error -> {:retry, "the challenge answer was not accepted"}
          end
        end

      :error ->
        if Challenge.challenge?(html),
          do: {:retry, "unsolvable challenge"},
          else: {:retry, "no post data in the page"}
    end
  end

  # `cookies`: the cookies file's (or nil), `answer`: a challenge answer (or nil).
  defp get(url, cookies, answer) do
    headers = [{"user-agent", @user_agent}, {"accept-language", "en-US,en;q=0.9"}]

    headers =
      case Cookies.merge(cookies && Cookies.header(cookies, url), answer) do
        nil -> headers
        cookie -> [{"cookie", cookie} | headers]
      end

    # Redirects off after the configured options: the request may carry cookies.
    request =
      [url: url, headers: headers, request_timeout: @request_timeout]
      |> TikTok.request()
      |> Req.merge(redirect: false)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        if response |> Req.Response.get_header("location") |> Enum.any?(&(&1 =~ "/login")),
          do: {:error, :login_required},
          else: {:retry, "redirected with HTTP #{status}"}

      {:ok, %Req.Response{status: status}} ->
        {:retry, "HTTP #{status}"}

      {:error, exception} ->
        {:retry, Cookies.request_error(exception)}
    end
  end

  @doc """
  Reads `webapp.video-detail` from a post page, or `:error` when the page has no
  such data (a challenge or an unexpected page).
  """
  @spec detail(String.t()) :: {:ok, map()} | :error
  def detail(html) when is_binary(html) do
    with [json] <- Regex.run(@data_re, html, capture: :all_but_first),
         {:ok, %{"__DEFAULT_SCOPE__" => %{"webapp.video-detail" => %{} = detail}}} <-
           Jason.decode(json) do
      {:ok, detail}
    else
      _other -> :error
    end
  end

  @doc "The post of a `webapp.video-detail`, or why there is none (see `t:failure/0`)."
  @spec item(map()) :: {:ok, map()} | {:error, failure()} | {:retry, String.t()}
  def item(detail) do
    item =
      case detail do
        %{"itemInfo" => %{"itemStruct" => %{} = item}} -> item
        _other -> nil
      end

    case {detail["statusCode"] || 0, item} do
      {0, %{} = item} -> {:ok, item}
      {0, _missing} -> {:retry, "no post in the page data"}
      {10204, _item} -> {:error, :deleted}
      {code, _item} when code in [10216, 10222] -> {:error, :private}
      {code, _item} -> {:error, {:status, code}}
    end
  end
end
