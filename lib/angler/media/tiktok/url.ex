defmodule Angler.Media.TikTok.Url do
  @moduledoc """
  Recognizes TikTok post links without network access (pure).

    * posts: `(www.|m.)tiktok.com/@user/video/<id>` and `/@user/photo/<id>` (the user
      name may be empty), `tiktokv.com/share/video/<id>`, `tiktok.com/embed(/v2)/<id>`
    * short links, which only a request resolves: `vm.tiktok.com/<code>`,
      `vt.tiktok.com/<code>` and `(www.)tiktok.com/t/<code>`

  Anything else (other sites, profiles, music and live pages) is `:not_tiktok`.
  """

  @post_hosts ~w(tiktok.com www.tiktok.com m.tiktok.com tiktokv.com www.tiktokv.com m.tiktokv.com)
  @short_hosts ~w(vm.tiktok.com vt.tiktok.com)
  @web_hosts ~w(tiktok.com www.tiktok.com m.tiktok.com)

  @type parsed :: {:post, String.t(), :video | :photo} | {:short, String.t()} | :not_tiktok

  @doc """
  Recognizes a TikTok link: `{:post, id, :video | :photo}`, `{:short, url}` for short
  links (as `https`, without the query), or `:not_tiktok`.
  """
  @spec parse(String.t()) :: parsed()
  def parse(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) ->
        classify(String.downcase(host), path || "/")

      _other ->
        :not_tiktok
    end
  end

  def parse(_url), do: :not_tiktok

  defp classify(host, path) when host in @short_hosts do
    if path =~ ~r{\A/\w+/?\z}, do: {:short, "https://" <> host <> path}, else: :not_tiktok
  end

  defp classify(host, path) when host in @post_hosts do
    cond do
      match = Regex.run(~r{\A/@[^/]*/(video|photo)/(\d+)}, path, capture: :all_but_first) ->
        [kind, id] = match
        {:post, id, if(kind == "photo", do: :photo, else: :video)}

      match = Regex.run(~r{\A/(?:share/video|embed(?:/v2)?)/(\d+)}, path) ->
        {:post, List.last(match), :video}

      host in @web_hosts and path =~ ~r{\A/t/\w+/?\z} ->
        {:short, "https://" <> host <> path}

      true ->
        :not_tiktok
    end
  end

  defp classify(_host, _path), do: :not_tiktok

  @doc """
  The page of a post, and the URL yt-dlp gets for a TikTok video:
  `https://www.tiktok.com/@/video/<id>`. It works for any user name (even an empty
  one), and only this page carries the post data, for photo posts too.
  """
  @spec canonical(String.t()) :: String.t()
  def canonical(id), do: "https://www.tiktok.com/@/video/#{id}"
end
