defmodule Angler.Pipeline.Caption do
  @moduledoc """
  The caption `Angler.Pipeline.Upload` posts with a video: the entry's title (the
  YouTube title, the TikTok post text or slideshow caption, Instagram's "Video by
  …", ...), when the `title_captions` setting is on.

  Captions are plain text: they are sent without `parse_mode`, so nothing in a
  title is interpreted as formatting.
  """
  alias Angler.Entries.Entry
  alias Angler.Settings.Setting

  # Telegram's caption limit. Counted in UTF-16 code units (as Telegram counts
  # entity offsets), which is never less than the number of characters.
  @max_length 1024
  @ellipsis "…"

  # Control characters other than tab and newline.
  @control_chars ~r/[^\P{Cc}\t\n]/u
  # yt-dlp names some videos without a title after their id, e.g. "Facebook video #1234…".
  @generated_title ~r/^(?:\S+ (?:video|post) )?#?(\S+)$/iu
  @numeric_id ~r/^#?\d{6,}$/
  @link ~r{^https?://\S+$}iu

  @doc """
  The caption for `entry` with `settings`, or nil when titles aren't posted as
  captions or the entry has no title worth posting (see `build/2`).
  """
  @spec for_entry(Entry.t(), Setting.t()) :: String.t() | nil
  def for_entry(%Entry{} = entry, %Setting{title_captions: true}),
    do: build(entry.title, entry.url)

  def for_entry(%Entry{}, %Setting{}), do: nil

  @doc """
  Turns the `title` of a video from `url` into a caption, or returns nil when there
  is nothing worth posting: no title, a blank one, or a title that is just a link
  or the video's id (yt-dlp falls back to those, e.g. "Facebook video #1234…").

  A video id is recognized as a part of `url` (a path segment, with or without its
  file extension, or a query value) or as a number of at least 6 digits, the id of
  a post behind a short link.

  Line breaks are normalized, control characters removed, trailing spaces of lines
  dropped, runs of blank lines collapsed into one and the whole text trimmed. A
  caption longer than Telegram's limit (#{@max_length} UTF-16 code units) is cut on
  a character (grapheme) boundary and ends with "#{@ellipsis}".
  """
  @spec build(String.t() | nil, String.t() | nil) :: String.t() | nil
  def build(title, url \\ nil)

  def build(title, url) when is_binary(title) do
    text = if String.valid?(title), do: normalize(title), else: ""

    if text == "" or placeholder?(text, url), do: nil, else: truncate(text)
  end

  def build(_title, _url), do: nil

  defp normalize(title) do
    title
    |> String.replace(~r/\r\n?/, "\n")
    |> String.replace(@control_chars, "")
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp placeholder?(text, url) do
    Regex.match?(@link, text) or same_url?(text, url) or video_id?(text, url)
  end

  defp same_url?(_text, nil), do: false
  defp same_url?(text, url), do: bare_url(text) == bare_url(url)

  defp bare_url(url) do
    url
    |> String.downcase()
    |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "")
    |> String.replace_prefix("www.", "")
    |> String.trim_trailing("/")
  end

  defp video_id?(text, url) do
    parts = url_parts(url)
    ids = [text | Regex.run(@generated_title, text, capture: :all_but_first) || []]
    Enum.any?(ids, &(Regex.match?(@numeric_id, &1) or String.downcase(&1) in parts))
  end

  # Path segments (also without their extension) and query values of `url`.
  defp url_parts(nil), do: []

  defp url_parts(url) do
    uri = URI.parse(url)
    segments = (uri.path || "") |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)
    values = if uri.query, do: uri.query |> URI.decode_query() |> Map.values(), else: []

    (segments ++ Enum.map(segments, &Path.rootname/1) ++ values)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  rescue
    # A malformed percent-encoding.
    ArgumentError -> []
  end

  defp truncate(text) do
    if utf16_length(text) <= @max_length do
      text
    else
      budget = @max_length - utf16_length(@ellipsis)

      kept =
        text
        |> String.graphemes()
        |> Enum.reduce_while({[], 0}, fn grapheme, {kept, used} ->
          used = used + utf16_length(grapheme)
          if used <= budget, do: {:cont, {[grapheme | kept], used}}, else: {:halt, {kept, used}}
        end)
        |> elem(0)
        |> Enum.reverse()
        |> IO.iodata_to_binary()
        |> String.trim_trailing()

      # Only a grapheme longer than the whole limit leaves nothing to post.
      if kept == "", do: nil, else: kept <> @ellipsis
    end
  end

  defp utf16_length(text),
    do: text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)
end
