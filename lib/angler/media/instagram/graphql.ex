defmodule Angler.Media.Instagram.GraphQL do
  @moduledoc """
  Reads a post through Instagram's logged-out GraphQL API, the query the website
  runs for a post page (`PolarisLoggedOutDesktopWWWPostRootContentQuery`), without
  cookies.

  The request is a form POST to `https://www.instagram.com/api/graphql` with the
  post's media id (`Angler.Media.Instagram.Url.pk/1`). Instagram answers with an
  HTML page unless it carries `sec-fetch-site: same-origin` and the same `lsd`
  token in the `x-fb-lsd` header and the form (any value works); the other
  headers are what the website sends. The answer is JSON served as
  `text/javascript`, with the post at `data.xig_polaris_media`:

    * `if_not_gated_logged_out` - the post (`Angler.Media.Instagram.Post.from_media/1`)
    * `gating_ruling` instead - hidden by a region, legal or age gate
    * `xig_polaris_media: null` - deleted, private or age restricted (Instagram
      does not tell which)

  The query id (`doc_id`) is not published anywhere and may change; answers of
  any other shape are retried and then reported as `{:gave_up, reason}`, so the
  caller can fall back to the post page and to yt-dlp.
  """
  require Logger

  alias Angler.Media.Cookies
  alias Angler.Media.Instagram
  alias Angler.Media.Instagram.Url

  @endpoint "https://www.instagram.com/api/graphql"
  @doc_id "27130156389949648"
  @query "PolarisLoggedOutDesktopWWWPostRootContentQuery"

  @typedoc "What Instagram said about a post (see the module documentation)."
  @type answer :: {:ok, map()} | {:gated, String.t() | nil} | :missing

  @type result :: answer() | {:rate_limited, String.t()} | {:gave_up, String.t()}

  @doc """
  Asks for the post `code`, retrying network errors, server errors and answers of
  an unknown shape once per entry of `retry_delays` (milliseconds to wait first).

  Signs of rate limiting (HTTP 429, a 401 answer that requires a login, a
  redirect to the login page) end the attempts at once: `{:rate_limited, reason}`.
  `{:gave_up, reason}` means every attempt failed otherwise.
  """
  @spec fetch(String.t(), [non_neg_integer()]) :: result()
  def fetch(code, retry_delays) do
    case fetch_once(code) do
      {:retry, reason} ->
        case retry_delays do
          [delay | rest] ->
            Logger.debug("Instagram GraphQL attempt failed (#{reason}), retrying in #{delay} ms")
            Process.sleep(delay)
            fetch(code, rest)

          [] ->
            {:gave_up, reason}
        end

      result ->
        result
    end
  end

  defp fetch_once(code) do
    lsd = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    request =
      Instagram.request(
        method: :post,
        url: @endpoint,
        headers: headers(code, lsd),
        form: form(code, lsd),
        decode_body: false
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, answer} -> classify(answer)
          {:error, _html} -> {:retry, "the answer is not JSON"}
        end

      {:ok, %Req.Response{status: 401, body: body}} ->
        if login_required?(body),
          do: {:rate_limited, "HTTP 401, login required"},
          else: {:retry, "HTTP 401"}

      {:ok, %Req.Response{status: 429}} ->
        {:rate_limited, "HTTP 429"}

      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        if login_redirect?(response),
          do: {:rate_limited, "redirected to the login page"},
          else: {:retry, "redirected with HTTP #{status}"}

      {:ok, %Req.Response{status: status}} ->
        {:retry, "HTTP #{status}"}

      {:error, exception} ->
        {:retry, Cookies.request_error(exception)}
    end
  end

  defp headers(code, lsd) do
    [
      {"user-agent", Instagram.user_agent()},
      {"accept", "*/*"},
      {"accept-language", "en-US,en;q=0.9"},
      {"origin", "https://www.instagram.com"},
      {"referer", Url.canonical(code)},
      {"x-fb-lsd", lsd},
      {"x-fb-friendly-name", @query},
      {"x-ig-app-id", Instagram.app_id()},
      {"x-asbd-id", Instagram.asbd_id()},
      {"x-ig-www-claim", "0"},
      {"x-requested-with", "XMLHttpRequest"},
      {"sec-fetch-site", "same-origin"},
      {"sec-fetch-mode", "cors"},
      {"sec-fetch-dest", "empty"}
    ]
  end

  defp form(code, lsd) do
    [
      lsd: lsd,
      doc_id: @doc_id,
      variables: Jason.encode!(%{"media_id" => Url.pk(code)}),
      fb_api_caller_class: "RelayModern",
      fb_api_req_friendly_name: @query,
      server_timestamps: "true"
    ]
  end

  defp login_required?(body) do
    match?({:ok, %{"require_login" => true}}, Jason.decode(body || ""))
  end

  defp login_redirect?(response) do
    response |> Req.Response.get_header("location") |> Enum.any?(&(&1 =~ "/accounts/login"))
  end

  @doc """
  Classifies a decoded answer (also the post page's data, see
  `Angler.Media.Instagram.Page`): the post, `{:gated, title}` (the gate's title or
  description, if any), `:missing` only when `xig_polaris_media` is present, null
  and the answer has no errors, else `{:retry, reason}`.
  """
  @spec classify(term()) :: answer() | {:retry, String.t()}
  def classify(%{"data" => %{"xig_polaris_media" => %{} = media}}) do
    case media do
      %{"if_not_gated_logged_out" => %{} = post} ->
        {:ok, post}

      # Gated answers also carry top-level errors.
      %{"gating_ruling" => %{} = ruling} ->
        {:gated, text(ruling["title"]) || text(ruling["description"])}

      _other ->
        {:retry, "no post in the answer"}
    end
  end

  def classify(%{"data" => %{"xig_polaris_media" => nil}} = answer) do
    if answer["errors"] in [nil, []], do: :missing, else: {:retry, "the answer has errors"}
  end

  def classify(%{"errors" => _errors}), do: {:retry, "the answer has errors"}
  def classify(_answer), do: {:retry, "unexpected answer"}

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_value), do: nil
end
