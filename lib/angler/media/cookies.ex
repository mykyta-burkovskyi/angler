defmodule Angler.Media.Cookies do
  @moduledoc """
  The cookies file (`YTDLP_COOKIES_FILE`, the Netscape format yt-dlp and browser
  extensions write) for the app's own requests that use it: TikTok post pages load
  once more with it when TikTok hides a post from logged-out visitors
  (`Angler.Media.TikTok.Page`), and the music of Instagram photo posts is read
  with it (`Angler.Media.Instagram.MediaInfo`). yt-dlp gets its own copy of the
  file (`Angler.Media.Ytdlp`), which is how other Instagram lookups use it.

  The file is read on every use (`load/0`), so a replaced file takes effect without
  a restart. Lines are 7 tab-separated fields: `domain include_subdomains path
  secure expires name value`; `#HttpOnly_` lines are cookies, other `#` lines
  comments.

  Cookie values are session secrets, so:

    * only cookies whose name is an HTTP token and whose value is made of RFC 6265
      cookie-octets are kept: HTTP clients put an invalid header value verbatim
      into their error messages, which end up in logs and on the dashboard
    * a request that carries cookies never follows redirects, and describes its
      failures with `request_error/1` instead of the exception message
    * `inspect/2` leaves values out (`Angler.Media.Cookies.Cookie`)
  """
  require Logger

  alias Angler.Media
  alias Angler.Media.Cookies.Cookie

  @max_file_bytes 1_000_000
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  # RFC 6265 cookie-octets, optionally in double quotes.
  @value ~r/\A(?:[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]*|"[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]*")\z/
  @domain ~r/\A[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\z/
  @expires ~r/\A(-?\d+)(?:\.\d*)?\z/

  @doc "Whether a cookies file is configured (`YTDLP_COOKIES_FILE`), readable or not."
  @spec configured?() :: boolean()
  def configured?, do: is_binary(Media.config(:cookies_file))

  @doc """
  Reads the configured cookies file: `[]` when none is configured, or when it is
  unreadable or larger than 1 MB (logged, without its contents). Invalid lines are
  skipped (logged with their line numbers).
  """
  @spec load() :: [Cookie.t()]
  def load do
    case Media.config(:cookies_file) do
      path when is_binary(path) -> read(path)
      _none -> []
    end
  end

  defp read(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_file_bytes + 1)) do
      {:ok, contents} when is_binary(contents) and byte_size(contents) > @max_file_bytes ->
        Logger.warning("Ignoring the cookies file: it is larger than 1 MB")
        []

      {:ok, contents} when is_binary(contents) ->
        {cookies, skipped} = parse_lines(contents)
        log_skipped(skipped)
        cookies

      {:ok, :eof} ->
        []

      {:ok, {:error, reason}} ->
        Logger.warning("Ignoring the cookies file: #{:file.format_error(reason)}")
        []

      {:error, reason} ->
        Logger.warning("Ignoring the cookies file: #{:file.format_error(reason)}")
        []
    end
  end

  defp log_skipped([]), do: :ok

  defp log_skipped(lines) do
    shown = lines |> Enum.take(10) |> Enum.join(", ")

    Logger.warning(
      "Ignoring #{length(lines)} lines of the cookies file that are not valid cookies " <>
        "(lines #{shown}#{if length(lines) > 10, do: ", ..."})"
    )
  end

  @doc """
  Parses cookies in the Netscape format. Lines that are not valid cookies are
  skipped: wrong field count, invalid names, values or domains, expiry times that
  are not numbers. An empty or `0` expiry is a session cookie; decimals are
  truncated. A later line replaces an earlier cookie with the same domain, path
  and name, in its place (as in browsers and yt-dlp's cookie jar, e.g. when a
  fresh export was appended to an old file).
  """
  @spec parse(String.t()) :: [Cookie.t()]
  def parse(contents) when is_binary(contents), do: contents |> parse_lines() |> elem(0)

  defp parse_lines(contents) do
    {cookies, skipped} =
      contents
      |> String.replace_prefix("\uFEFF", "")
      # Only line breaks: a cookie with an empty value ends with a tab.
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {line, number}, {cookies, skipped} ->
        case parse_line(String.replace_suffix(line, "\r", "")) do
          {:ok, cookie} -> {[cookie | cookies], skipped}
          :ignore -> {cookies, skipped}
          :error -> {cookies, [number | skipped]}
        end
      end)

    {cookies |> Enum.reverse() |> replace_duplicates(), Enum.reverse(skipped)}
  end

  defp replace_duplicates(cookies) do
    latest = Map.new(cookies, &{cookie_key(&1), &1})
    cookies |> Enum.uniq_by(&cookie_key/1) |> Enum.map(&Map.fetch!(latest, cookie_key(&1)))
  end

  defp cookie_key(%Cookie{domain: domain, path: path, name: name}), do: {domain, path, name}

  defp parse_line("#HttpOnly_" <> line), do: cookie(line)
  defp parse_line("#" <> _comment), do: :ignore

  defp parse_line(line) do
    if String.trim(line) == "", do: :ignore, else: cookie(line)
  end

  defp cookie(line) do
    with [domain, subdomains, path, secure, expires, name, value] <- String.split(line, "\t"),
         host = domain |> String.downcase() |> String.replace_prefix(".", ""),
         true <- Regex.match?(@domain, host),
         true <- Regex.match?(@token, name),
         true <- Regex.match?(@value, value),
         {:ok, expires} <- expires(expires) do
      {:ok,
       %Cookie{
         domain: host,
         include_subdomains: flag?(subdomains) or String.starts_with?(domain, "."),
         path: if(path == "", do: "/", else: path),
         secure: flag?(secure),
         expires: expires,
         name: name,
         value: value
       }}
    else
      _invalid -> :error
    end
  end

  defp flag?(field), do: String.upcase(field) == "TRUE"

  defp expires(""), do: {:ok, nil}

  defp expires(field) do
    case Regex.run(@expires, field, capture: :all_but_first) do
      [seconds] ->
        case String.to_integer(seconds) do
          0 -> {:ok, nil}
          seconds -> {:ok, seconds}
        end

      nil ->
        :error
    end
  end

  @doc """
  The `cookie` header value for a request to `url`: the cookies whose domain,
  path and `secure` flag match it (RFC 6265 5.1.3, 5.1.4) and that have not
  expired at `now` (Unix seconds), as `"a=1; b=2"`. More specific domains, then
  longer paths come first, and only the first cookie of each name is sent (of
  cookies with the same domain, path and name, `parse/1` keeps the last). nil
  when none matches.
  """
  @spec header([Cookie.t()], String.t(), integer()) :: String.t() | nil
  def header(cookies, url, now \\ System.os_time(:second)) do
    with %URI{scheme: scheme, host: host, path: path} when scheme in ["http", "https"] <-
           URI.parse(url),
         true <- is_binary(host) and host != "" do
      host = host |> String.downcase() |> String.trim_trailing(".")
      path = if path in [nil, ""], do: "/", else: path

      cookies
      |> Enum.filter(fn cookie ->
        domain_match?(cookie, host) and path_match?(cookie.path, path) and
          (scheme == "https" or not cookie.secure) and not expired?(cookie, now)
      end)
      |> Enum.sort_by(&{byte_size(&1.domain), byte_size(&1.path)}, :desc)
      |> Enum.uniq_by(& &1.name)
      |> Enum.map_join("; ", &(&1.name <> "=" <> &1.value))
      |> then(&if(&1 == "", do: nil, else: &1))
    else
      _other -> nil
    end
  end

  defp domain_match?(%Cookie{domain: host}, host), do: true

  defp domain_match?(%Cookie{domain: domain, include_subdomains: true}, host),
    do: String.ends_with?(host, "." <> domain) and not ip_address?(host)

  defp domain_match?(_cookie, _host), do: false

  defp ip_address?(host), do: match?({:ok, _address}, :inet.parse_address(to_charlist(host)))

  defp path_match?(path, path), do: true

  defp path_match?(cookie_path, path) do
    String.starts_with?(path, cookie_path) and
      (String.ends_with?(cookie_path, "/") or
         binary_part(path, byte_size(cookie_path), 1) == "/")
  end

  defp expired?(%Cookie{expires: nil}, _now), do: false
  defp expired?(%Cookie{expires: expires}, now), do: expires <= now

  @doc """
  Merges two `cookie` header values (either may be nil); for a name in both, the
  later value wins. nil when both are empty.
  """
  @spec merge(String.t() | nil, String.t() | nil) :: String.t() | nil
  def merge(first, second) do
    (pairs(first) ++ pairs(second))
    |> Enum.reverse()
    |> Enum.uniq_by(fn pair -> pair |> String.split("=", parts: 2) |> hd() end)
    |> Enum.reverse()
    |> Enum.join("; ")
    |> then(&if(&1 == "", do: nil, else: &1))
  end

  defp pairs(nil), do: []

  defp pairs(header) do
    header |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Describes why a request failed without the exception's message: for a request
  that carried cookies, the message can contain the `cookie` header (Mint reports
  invalid header values verbatim). Transport errors keep their reason (an atom such
  as `:timeout`).
  """
  @spec request_error(Exception.t()) :: String.t()
  def request_error(%Req.TransportError{reason: reason}) when is_atom(reason),
    do: "network error (#{reason})"

  def request_error(%module{}), do: "network error (#{inspect(module)})"
end
