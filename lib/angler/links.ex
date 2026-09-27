defmodule Angler.Links do
  @moduledoc """
  Finds links in Telegram messages and normalizes them.

  Links are taken from the message entities Telegram computes server side
  (`url` and `text_link`), from `text`/`entities` for text messages and from
  `caption`/`caption_entities` for media messages. Entity offsets and lengths
  are counted in UTF-16 code units, so the text is sliced in UTF-16.

  Normalized URLs are what `Angler.Entries` stores and deduplicates on, so the
  same video shared twice (with different tracking parameters) maps to the same URL.
  They are ASCII: internationalized hosts are converted to Punycode (see
  `Angler.Links.IDN`) and other characters that are not valid in URIs are
  percent-encoded.
  """

  alias Angler.Links.IDN

  @max_links 5

  # Longer links are not real video links, and the database indexes entries by url:
  # a Postgres btree index row holds at most 2704 bytes, and one that doesn't fit
  # fails the insert on every delivery of the update.
  @max_url_bytes 2048

  # Printable ASCII characters URI.new/1 rejects, but Telegram keeps in links
  # (brackets are only valid around an IPv6 host).
  @unsafe_chars ~c'"<>\\^`{|}[]'

  @telegram_hosts ~w(t.me telegram.me telegram.org)
  @youtube_hosts ~w(youtube.com youtu.be)
  @twitter_hosts ~w(x.com twitter.com)
  @reddit_hosts ~w(reddit.com redd.it)

  # Query parameters that only track who shared a link and where; dropped everywhere.
  @tracking_params ~w(
    fbclid gclid gclsrc dclid msclkid yclid ttclid mc_cid mc_eid mibextid igsh igshid
    _r _t is_from_webapp sender_device sender_web_id web_id share_source share_app_id
    share_link_id share_item_id share_iid tt_from u_code
  )

  # Tracking parameters whose names are too generic to drop on every site.
  @host_tracking_params [
    {@youtube_hosts, ~w(si)},
    {@twitter_hosts, ~w(s t ref_src ref_url)},
    {@reddit_hosts, ~w(share_id rdt)}
  ]

  @doc """
  Returns the normalized `http`/`https` URLs found in a message, in order of
  appearance, without duplicates, Telegram's own links and links longer than
  #{@max_url_bytes} bytes, at most #{@max_links}.
  """
  @spec extract(map()) :: [String.t()]
  def extract(message) when is_map(message) do
    {text, entities} = text_and_entities(message)

    entities
    |> Enum.map(&entity_url(&1, text))
    |> Enum.map(&normalize/1)
    |> Enum.filter(&processable?/1)
    |> Enum.uniq()
    |> Enum.take(@max_links)
  end

  @doc """
  Normalizes a URL: trims it, adds `https://` when the scheme is missing,
  lowercases scheme and host, drops the fragment and tracking query parameters
  (keeping all other parameters in order). Returns nil when it can't be parsed.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(url) when is_binary(url) do
    with url when url != "" <- String.trim(url),
         {:ok, %URI{host: host} = uri} when host not in [nil, ""] <- parse(url) do
      host = String.downcase(host)

      %URI{
        uri
        | scheme: String.downcase(uri.scheme),
          host: host,
          fragment: nil,
          query: clean_query(uri.query, strip_www(host))
      }
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  def normalize(_url), do: nil

  @doc "Lowercased host of a URL without a leading `www.`, or nil."
  @spec host(String.t() | nil) :: String.t() | nil
  def host(url) do
    with normalized when is_binary(normalized) <- normalize(url) do
      normalized |> URI.parse() |> Map.fetch!(:host) |> strip_www()
    end
  end

  ## Entities

  defp text_and_entities(%{"text" => text} = message) when is_binary(text),
    do: {text, list(message["entities"])}

  defp text_and_entities(%{"caption" => caption} = message) when is_binary(caption),
    do: {caption, list(message["caption_entities"])}

  defp text_and_entities(_message), do: {"", []}

  defp list(entities) when is_list(entities), do: entities
  defp list(_entities), do: []

  defp entity_url(%{"type" => "text_link", "url" => url}, _text), do: url

  defp entity_url(%{"type" => "url", "offset" => offset, "length" => length}, text)
       when is_integer(offset) and is_integer(length) and offset >= 0 and length > 0,
       do: utf16_slice(text, offset, length)

  defp entity_url(_entity, _text), do: nil

  # Telegram counts offsets in UTF-16 code units; emoji outside the BMP take two.
  defp utf16_slice(text, offset, length) do
    utf16 = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})

    with true <- (offset + length) * 2 <= byte_size(utf16),
         slice = binary_part(utf16, offset * 2, length * 2),
         result when is_binary(result) <-
           :unicode.characters_to_binary(slice, {:utf16, :little}, :utf8) do
      result
    else
      _ -> nil
    end
  end

  defp processable?(nil), do: false
  defp processable?(url) when byte_size(url) > @max_url_bytes, do: false

  defp processable?(url) do
    %URI{scheme: scheme, host: host} = URI.parse(url)
    scheme in ["http", "https"] and not host_in?(strip_www(host), @telegram_hosts)
  end

  ## Normalization

  # Telegram links may contain characters URI.new/1 rejects: non-ASCII ones (e.g.
  # Cyrillic paths and hosts), spaces and some printable ASCII (| [ ] ...). Hosts get
  # their ASCII form; the rest is percent-encoded, leaving existing escapes alone.
  defp parse(url) do
    url = if Regex.match?(~r/^[a-z][a-z0-9+.-]*:\/\//i, url), do: url, else: "https://" <> url

    [origin, authority, rest] =
      Regex.run(~r{\A([a-z][a-z0-9+.-]*://)([^/?#]*)(.*)\z}is, url, capture: :all_but_first)

    URI.new(origin <> encode_authority(authority) <> URI.encode(rest, &uri_char?/1))
  end

  # `[userinfo@]host[:port]`: only the host may be internationalized.
  defp encode_authority(authority) do
    authority =
      if authority =~ ~r/[^\x00-\x7F]/ do
        [userinfo, host, port] =
          Regex.run(~r/\A(.*@)?([^@:]*)(.*)\z/s, authority, capture: :all_but_first)

        userinfo <> IDN.to_ascii(host) <> port
      else
        authority
      end

    URI.encode(authority, &(&1 in 0x21..0x7E))
  end

  defp uri_char?(char), do: char in 0x21..0x7E and char not in @unsafe_chars

  defp clean_query(nil, _host), do: nil

  defp clean_query(query, host) do
    case query |> String.split("&", trim: true) |> Enum.reject(&tracking_param?(&1, host)) do
      [] -> nil
      params -> Enum.join(params, "&")
    end
  end

  defp tracking_param?(param, host) do
    {name, value} =
      case String.split(param, "=", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, ""}
      end

    name = String.downcase(name)

    String.starts_with?(name, "utm_") or name in @tracking_params or
      (name == "feature" and value in ["share", "shared"]) or
      Enum.any?(@host_tracking_params, fn {hosts, names} ->
        name in names and host_in?(host, hosts)
      end)
  end

  defp host_in?(nil, _hosts), do: false

  defp host_in?(host, hosts),
    do: Enum.any?(hosts, &(host == &1 or String.ends_with?(host, "." <> &1)))

  defp strip_www(nil), do: nil
  defp strip_www(host), do: String.replace_prefix(host, "www.", "")
end
