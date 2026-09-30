defmodule Angler.Media.Instagram.Url do
  @moduledoc """
  Recognizes Instagram post links without network access (pure).

    * posts: `(www.|m.)instagram.com/(<user>/)(p|reel|reels|tv)/<code>` and
      `(www.)instagr.am/...` (the same paths); query strings (`img_index`, `igsh`,
      ...) don't matter
    * share links, which only a request resolves: `instagram.com/share/<token>` and
      `instagram.com/share/(p|reel|reels|tv)/<token>`

  Anything else (other sites, profiles, stories, `/reels/audio/` pages) is
  `:not_instagram`.
  """

  @instagram_hosts ~w(instagram.com www.instagram.com m.instagram.com)
  @hosts @instagram_hosts ++ ~w(instagr.am www.instagr.am)
  @alphabet ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  @max_code_length 64

  @type parsed :: {:post, String.t()} | {:share, String.t()} | :not_instagram

  @doc """
  Recognizes an Instagram link: `{:post, code}`, `{:share, url}` for share links
  (rebuilt as `https://www.instagram.com<path>`, without query, port or user
  info), or `:not_instagram`.
  """
  @spec parse(String.t()) :: parsed()
  def parse(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) ->
        classify(String.downcase(host), path || "/")

      _other ->
        :not_instagram
    end
  end

  def parse(_url), do: :not_instagram

  defp classify(host, path) when host in @hosts do
    cond do
      path =~ ~r{\A/(?:reels/audio|share)(?:/|\z)} ->
        share(host, path)

      match = Regex.run(~r{\A/(?:[A-Za-z0-9._]+/)?(?:p|reels?|tv)/([A-Za-z0-9_-]+)(?:/|\z)}, path) ->
        code(List.last(match))

      true ->
        :not_instagram
    end
  end

  defp classify(_host, _path), do: :not_instagram

  defp share(host, path) do
    if host in @instagram_hosts and
         path =~ ~r"\A/share/(?:(?:p|reels?|tv)/)?[A-Za-z0-9_-]{1,64}/?\z",
       do: {:share, "https://www.instagram.com" <> path},
       else: :not_instagram
  end

  defp code(code) when byte_size(code) <= @max_code_length, do: {:post, code}
  defp code(_code), do: :not_instagram

  @doc """
  The media id (`pk`) of a post code, as a decimal string: the code in Base64url
  digits. Codes longer than 28 characters (private share links) carry a suffix
  that is dropped.
  """
  @spec pk(String.t()) :: String.t()
  def pk(code) do
    code = if String.length(code) > 28, do: String.slice(code, 0..-29//1), else: code

    code
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, pk -> pk * 64 + Enum.find_index(@alphabet, &(&1 == char)) end)
    |> Integer.to_string()
  end

  @doc "The canonical URL of a post: `https://www.instagram.com/p/<code>/`."
  @spec canonical(String.t()) :: String.t()
  def canonical(code), do: "https://www.instagram.com/p/#{code}/"
end
