defmodule Angler.Media.Instagram.Cdn do
  @moduledoc """
  Instagram's CDN (`*.cdninstagram.com`, `*.fbcdn.net`, https only): the only
  hosts photos, videos and songs of Instagram posts are downloaded from. No
  cookies, no redirects, and hosts only in the logs, since the URLs are signed.
  """
  require Logger

  alias Angler.Media.{Fetch, Instagram}

  @cdn_domains ["cdninstagram.com", "fbcdn.net"]
  @default_timeout :timer.minutes(2)

  @doc """
  Whether `url` may be downloaded: https (port 443) on Instagram's CDN hosts
  (`cdninstagram.com`, `fbcdn.net` and their subdomains), without user info.
  """
  @spec cdn?(term()) :: boolean()
  def cdn?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", userinfo: nil, host: host, port: port}
      when is_binary(host) and port in [nil, 443] ->
        host = String.downcase(host)
        Enum.any?(@cdn_domains, &(host == &1 or String.ends_with?(host, "." <> &1)))

      _other ->
        false
    end
  end

  def cdn?(_url), do: false

  @doc """
  Downloads `url` into `path` with `Angler.Media.Fetch.to_file/3`, through
  `Angler.Media.Instagram.request/1`: without cookies and without following
  redirects. A URL that is not on the CDN (`cdn?/1`) is refused without a request:
  `{:error, {:host_not_allowed, host}}`, logged with its host only.

  Options:
    * `:max_bytes` (required) - `{:error, :too_large}` beyond it
    * `:timeout` - milliseconds for the whole download, default 2 minutes
    * `:budget` - a byte budget shared with other fetches (`Angler.Media.Fetch.budget/1`)
  """
  @spec fetch(String.t(), Path.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, Fetch.reason()}
  def fetch(url, path, opts) do
    if cdn?(url) do
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      # Req's own time limit backs up Fetch's deadline.
      request = fn options ->
        options
        |> Keyword.merge(redirect: false, request_timeout: timeout + 5_000)
        |> Instagram.request()
      end

      Fetch.to_file(url, path, Keyword.merge(opts, timeout: timeout, request: request))
    else
      host = URI.parse(url).host
      Logger.warning("Not downloading Instagram media from #{host || "a URL without a host"}")
      {:error, {:host_not_allowed, host}}
    end
  end
end
