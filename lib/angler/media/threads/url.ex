defmodule Angler.Media.Threads.Url do
  @moduledoc """
  Recognizes Threads post links without network access (pure).

    * posts: `(www.)threads.com/@<user>/post/<code>` and `(www.)threads.com/t/<code>`,
      also on `threads.net` (which redirects to `threads.com`); trailing segments
      (`/media`, `/embed`) and query strings (`xmt`, `slof`, ...) don't matter
    * share links, which only a request resolves: `threads.com/share/<token>`

  Anything else (other sites, profiles, search, ...) is `:not_threads`. A post code
  is in Instagram's alphabet: Threads posts share Instagram's media ids.
  """

  @hosts ~w(threads.com www.threads.com threads.net www.threads.net)
  @post_re ~r"\A/(?:@([A-Za-z0-9._]{1,64})/post|t)/([A-Za-z0-9_-]{1,64})(?:/|\z)"
  @share_re ~r"\A/share/([A-Za-z0-9_-]{1,64})/?\z"

  @type parsed :: {:post, String.t(), String.t() | nil} | {:share, String.t()} | :not_threads

  @doc """
  Recognizes a Threads link: `{:post, code, username}` (the username is nil for
  `/t/<code>` links), `{:share, url}` for share links (rebuilt as
  `https://www.threads.com/share/<token>/`, without query, port or user info), or
  `:not_threads`.
  """
  @spec parse(String.t()) :: parsed()
  def parse(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) ->
        classify(String.downcase(host), path || "/")

      _other ->
        :not_threads
    end
  end

  def parse(_url), do: :not_threads

  defp classify(host, path) when host in @hosts do
    cond do
      match = Regex.run(@post_re, path, capture: :all_but_first) ->
        [user, code] = match
        {:post, code, if(user == "", do: nil, else: user)}

      match = Regex.run(@share_re, path, capture: :all_but_first) ->
        {:share, "https://www.threads.com/share/#{hd(match)}/"}

      true ->
        :not_threads
    end
  end

  defp classify(_host, _path), do: :not_threads

  @doc """
  The canonical URL of a post: `https://www.threads.com/@<user>/post/<code>`, or
  `https://www.threads.com/t/<code>` without a username (Threads redirects that to
  the first form).
  """
  @spec canonical(String.t(), String.t() | nil) :: String.t()
  def canonical(code, nil), do: "https://www.threads.com/t/#{code}"
  def canonical(code, user), do: "https://www.threads.com/@#{user}/post/#{code}"
end
