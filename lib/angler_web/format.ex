defmodule AnglerWeb.Format do
  @moduledoc """
  Pure formatting helpers for the dashboard.

  Sizes use decimal units (1 MB = 1,000,000 bytes), matching how Telegram documents
  its limits and how `Angler.Settings` stores them. Missing values render as an em dash.
  """

  @placeholder "—"
  @byte_units ~w(kB MB GB TB PB)
  @minute 60
  @hour 3_600
  @day 86_400

  @doc "The text shown for missing values."
  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  @doc """
  Formats a byte count with decimal units.

      iex> AnglerWeb.Format.bytes(12_345_678)
      "12.3 MB"
      iex> AnglerWeb.Format.bytes(50_000_000)
      "50 MB"
  """
  @spec bytes(integer() | nil) :: String.t()
  def bytes(nil), do: @placeholder
  def bytes(bytes) when bytes < 1000, do: "#{bytes} B"
  def bytes(bytes), do: scale(bytes / 1000, @byte_units)

  defp scale(value, [unit]), do: "#{significant(value)} #{unit}"
  defp scale(value, [unit | _]) when value < 999.5, do: "#{significant(value)} #{unit}"
  defp scale(value, [_unit | larger]), do: scale(value / 1000, larger)

  # One decimal below 100 ("12.3"), whole numbers above ("512"), no trailing ".0".
  defp significant(value) when value >= 99.95, do: Integer.to_string(round(value))

  defp significant(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
  end

  @doc """
  Formats an integer with thousands separators.

      iex> AnglerWeb.Format.number(10_240)
      "10,240"
  """
  @spec number(integer() | nil) :: String.t()
  def number(nil), do: @placeholder

  def number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  Formats a media duration in seconds as a clock, like a video player does.

      iex> AnglerWeb.Format.duration(65.4)
      "1:05"
      iex> AnglerWeb.Format.duration(3723)
      "1:02:03"
  """
  @spec duration(number() | nil) :: String.t()
  def duration(nil), do: @placeholder

  def duration(seconds) when is_number(seconds) do
    total = trunc(seconds)
    hours = div(total, @hour)
    minutes = total |> rem(@hour) |> div(@minute)
    secs = rem(total, @minute)

    if hours > 0,
      do: "#{hours}:#{pad(minutes)}:#{pad(secs)}",
      else: "#{minutes}:#{pad(secs)}"
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  Formats a span of time in seconds with its two most significant units.

      iex> AnglerWeb.Format.elapsed(125)
      "2m 5s"
      iex> AnglerWeb.Format.elapsed(7_380)
      "2h 3m"
  """
  @spec elapsed(number() | nil) :: String.t()
  def elapsed(nil), do: @placeholder

  def elapsed(seconds) when is_number(seconds) do
    seconds = max(round(seconds), 0)

    cond do
      seconds < @minute ->
        "#{seconds}s"

      seconds < @hour ->
        units(div(seconds, @minute), "m", rem(seconds, @minute), "s")

      seconds < @day ->
        units(div(seconds, @hour), "h", seconds |> rem(@hour) |> div(@minute), "m")

      true ->
        units(div(seconds, @day), "d", seconds |> rem(@day) |> div(@hour), "h")
    end
  end

  @doc "Formats the time between two datetimes (see `elapsed/1`); nil if either is missing."
  @spec elapsed(DateTime.t() | nil, DateTime.t() | nil) :: String.t()
  def elapsed(%DateTime{} = from, %DateTime{} = to),
    do: elapsed(DateTime.diff(to, from, :millisecond) / 1000)

  def elapsed(_from, _to), do: @placeholder

  defp units(major, major_unit, 0, _minor_unit), do: "#{major}#{major_unit}"

  defp units(major, major_unit, minor, minor_unit),
    do: "#{major}#{major_unit} #{minor}#{minor_unit}"

  @doc """
  Describes a datetime relative to `now`: "just now", "3 min ago", "in 2 h", or a
  date for anything more than a week away. Mirrored by the `.RelativeTime` hook,
  which keeps the text fresh in the browser.
  """
  @spec relative_time(DateTime.t() | nil, DateTime.t()) :: String.t()
  def relative_time(datetime, now \\ DateTime.utc_now())
  def relative_time(nil, _now), do: @placeholder

  def relative_time(%DateTime{} = datetime, %DateTime{} = now) do
    diff = DateTime.diff(now, datetime)
    distance = abs(diff)
    minutes = round(distance / @minute)
    hours = round(distance / @hour)
    days = round(distance / @day)

    cond do
      distance < 45 and diff >= 0 -> "just now"
      distance < 45 -> "in a moment"
      minutes < 60 -> relative(diff, "#{minutes} min")
      hours < 24 -> relative(diff, "#{hours} h")
      days < 7 -> relative(diff, "#{days} d")
      datetime.year == now.year -> Calendar.strftime(datetime, "%b %-d")
      true -> Calendar.strftime(datetime, "%b %-d, %Y")
    end
  end

  defp relative(diff, amount) when diff >= 0, do: amount <> " ago"
  defp relative(_diff, amount), do: "in " <> amount

  @doc "Formats an absolute UTC timestamp, e.g. `2026-09-26 14:03:05 UTC`."
  @spec datetime(DateTime.t() | nil) :: String.t()
  def datetime(nil), do: @placeholder
  def datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  @doc """
  A human label for the chat an entry came from: its title, the sender's name for
  private chats, or the chat id.
  """
  @spec chat_label(map()) :: String.t()
  def chat_label(%{chat_title: title}) when is_binary(title) and title != "", do: title

  def chat_label(%{chat_type: "private", from_name: name}) when is_binary(name) and name != "",
    do: name

  def chat_label(%{chat_type: "private"}), do: "Private chat"
  def chat_label(%{chat_id: id}) when is_integer(id), do: "Chat #{id}"
  def chat_label(_entry), do: "Unknown chat"

  @doc """
  Shortens `text` to at most `max` characters, ending with an ellipsis when cut.

      iex> AnglerWeb.Format.truncate("abcdef", 4)
      "abc…"
  """
  @spec truncate(String.t() | nil, pos_integer()) :: String.t()
  def truncate(nil, _max), do: ""

  def truncate(text, max) when is_binary(text) and max > 0 do
    if String.length(text) > max,
      do: String.slice(text, 0, max - 1) <> "…",
      else: text
  end

  @doc """
  The host of a URL without a leading `www.`, or nil.

      iex> AnglerWeb.Format.host("https://www.tiktok.com/@user/video/1")
      "tiktok.com"
  """
  @spec host(String.t() | nil) :: String.t() | nil
  def host(nil), do: nil

  def host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host |> String.downcase() |> String.replace_prefix("www.", "")

      _ ->
        nil
    end
  end

  @doc "`part` as a percentage of `total`, clamped to 0..100 (0 when the total is unknown)."
  @spec percent(number() | nil, number() | nil) :: float()
  def percent(part, total) when is_number(part) and is_number(total) and total > 0,
    do: (part / total * 100) |> max(0.0) |> min(100.0)

  def percent(_part, _total), do: 0.0
end
