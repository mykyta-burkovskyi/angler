defmodule Angler.Media.Instagram.Page do
  @moduledoc """
  Reads a post from its page (`https://www.instagram.com/p/<code>/`), the fallback
  when the GraphQL API (`Angler.Media.Instagram.GraphQL`) gave up. No cookies.

  Loaded like a browser navigation (`sec-fetch-*` headers; without them Instagram
  serves a page without data), the page embeds the GraphQL answer in one of its
  `<script type="application/json" data-sjs>` blobs (a `RelayPrefetchedStreamCache`
  entry). The blob mentioning `xig_polaris_media` is decoded, and the embedded
  answer (its `data` with the `errors` next to it) is classified like a GraphQL
  answer. A page for a missing post is Instagram's error page
  (`"tracePolicy":"polaris.httpErrorPage"`).
  """

  alias Angler.Media.Cookies
  alias Angler.Media.Instagram
  alias Angler.Media.Instagram.{GraphQL, Url}

  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
  @blob_re ~r/<script\b[^>]*\bdata-sjs\b[^>]*>(.*?)<\/script>/s
  @error_page ~s("tracePolicy":"polaris.httpErrorPage")

  @type result :: GraphQL.answer() | {:gave_up, String.t()}

  @doc """
  Loads the page of the post `code` once and reads the post from it (see `read/1`);
  `{:gave_up, reason}` when the page could not be loaded.
  """
  @spec fetch(String.t()) :: result()
  def fetch(code) do
    headers = [
      {"user-agent", @user_agent},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"accept-language", "en-US,en;q=0.9"},
      {"sec-fetch-dest", "document"},
      {"sec-fetch-mode", "navigate"},
      {"sec-fetch-site", "none"}
    ]

    case Req.request(Instagram.request(url: Url.canonical(code), headers: headers)) do
      {:ok, %Req.Response{status: 200, body: html}} when is_binary(html) ->
        read(html)

      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        if response |> Req.Response.get_header("location") |> Enum.any?(&(&1 =~ "/login")),
          do: {:gave_up, "the post page redirected to the login page"},
          else: {:gave_up, "the post page redirected with HTTP #{status}"}

      {:ok, %Req.Response{status: status}} ->
        {:gave_up, "the post page answered with HTTP #{status}"}

      {:error, exception} ->
        {:gave_up, "the post page: " <> Cookies.request_error(exception)}
    end
  end

  @doc """
  Reads the post from a post page: the post, `{:gated, title}` or `:missing` as
  for a GraphQL answer (`:missing` also for Instagram's error page), or
  `{:gave_up, reason}` for a page without post data.
  """
  @spec read(String.t()) :: result()
  def read(html) when is_binary(html) do
    answer =
      @blob_re
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.find_value(fn [blob] ->
        String.contains?(blob, "xig_polaris_media") and embedded_answer(blob)
      end)

    cond do
      is_map(answer) ->
        case GraphQL.classify(answer) do
          {:retry, reason} -> {:gave_up, "the post page: " <> reason}
          answer -> answer
        end

      String.contains?(html, @error_page) ->
        :missing

      true ->
        {:gave_up, "no post data in the post page"}
    end
  end

  # The GraphQL answer wherever it is in the blob: the Relay `result` whose `data`
  # holds the `xig_polaris_media` key, with its `errors` (a null post with errors
  # is a server error, not a missing post). A `xig_polaris_media` key outside of
  # such a result is taken as the answer's data.
  defp embedded_answer(blob) do
    case Jason.decode(blob) do
      {:ok, json} -> find_answer(json)
      {:error, _invalid} -> nil
    end
  end

  defp find_answer(%{"data" => %{"xig_polaris_media" => _media}} = answer), do: answer
  defp find_answer(%{"xig_polaris_media" => _media} = data), do: %{"data" => data}
  defp find_answer(%{} = map), do: map |> Map.values() |> find_answer()
  defp find_answer(list) when is_list(list), do: Enum.find_value(list, &find_answer/1)
  defp find_answer(_value), do: nil
end
