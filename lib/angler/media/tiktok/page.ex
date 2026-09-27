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

  `webapp.video-detail.statusCode`: 0 is a post, 10204 a deleted post, 10216 and
  10222 private posts and accounts; anything else is reported as is.
  """
  require Logger

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
  """
  @spec fetch(String.t(), [non_neg_integer()]) :: {:ok, map()} | {:error, failure()}
  def fetch(url, retry_delays) do
    case fetch_once(url) do
      {:retry, reason} ->
        case retry_delays do
          [delay | rest] ->
            Logger.debug("TikTok page attempt failed (#{reason}), retrying in #{delay} ms")
            Process.sleep(delay)
            fetch(url, rest)

          [] ->
            {:error, {:gave_up, reason}}
        end

      result ->
        result
    end
  end

  defp fetch_once(url) do
    with {:ok, html} <- get(url, []) do
      case detail(html) do
        {:ok, detail} -> item(detail)
        :error -> solve_challenge(url, html)
      end
    end
  end

  defp solve_challenge(url, html) do
    case Challenge.solve(html) do
      {:ok, cookie} ->
        Logger.debug("Solved the TikTok challenge")

        with {:ok, html} <- get(url, [{"cookie", cookie}]) do
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

  defp get(url, extra_headers) do
    headers = [{"user-agent", @user_agent}, {"accept-language", "en-US,en;q=0.9"} | extra_headers]
    request = TikTok.request(url: url, headers: headers, request_timeout: @request_timeout)

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
        {:retry, Exception.message(exception)}
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
