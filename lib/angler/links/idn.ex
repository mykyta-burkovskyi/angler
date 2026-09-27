defmodule Angler.Links.IDN do
  @moduledoc """
  Converts internationalized host names (e.g. `пример.рф`) to the ASCII form DNS,
  yt-dlp and the host filters work with (`xn--e1afmkfd.xn--p1ai`).

  Hosts are lowercased and NFC-normalized, and every label with non-ASCII
  characters is Punycode-encoded (RFC 3492) with the `xn--` prefix. That is the
  part of IDNA real links need, not all of UTS #46.
  """

  # Punycode parameters (RFC 3492, section 5).
  @base 36
  @tmin 1
  @tmax 26
  @skew 38
  @damp 700
  @initial_bias 72
  @initial_n 128

  # Ideographic, fullwidth and halfwidth full stops separate labels like "." does.
  @dots ["。", "．", "｡"]

  @doc """
  Returns the ASCII form of `host`. ASCII labels are only lowercased; a host that
  is not valid UTF-8 is returned unchanged.
  """
  @spec to_ascii(String.t()) :: String.t()
  def to_ascii(host) when is_binary(host) do
    with true <- String.valid?(host),
         normalized when is_binary(normalized) <-
           host |> String.downcase() |> :unicode.characters_to_nfc_binary() do
      normalized
      |> String.replace(@dots, ".")
      |> String.split(".")
      |> Enum.map_join(".", &label/1)
    else
      _ -> host
    end
  end

  defp label(label) do
    if label =~ ~r/[^\x00-\x7F]/,
      do: "xn--" <> punycode(String.to_charlist(label)),
      else: label
  end

  ## Punycode (RFC 3492, section 6.3)

  defp punycode(input) do
    basic = Enum.filter(input, &(&1 < 0x80))
    handled = length(basic)
    prefix = if basic == [], do: [], else: basic ++ [?-]
    digits = encode(input, @initial_n, 0, @initial_bias, handled, handled, [])
    List.to_string(prefix ++ digits)
  end

  # `handled` code points are encoded so far, `basic` of them are ASCII.
  defp encode(input, n, delta, bias, handled, basic, acc) do
    case Enum.filter(input, &(&1 >= n)) do
      [] ->
        Enum.reverse(acc)

      rest ->
        m = Enum.min(rest)
        delta = delta + (m - n) * (handled + 1)

        {delta, bias, handled, acc} =
          Enum.reduce(input, {delta, bias, handled, acc}, fn
            char, {delta, bias, handled, acc} when char < m ->
              {delta + 1, bias, handled, acc}

            char, {delta, bias, handled, acc} when char == m ->
              acc = variable_integer(delta, bias, @base, acc)
              {0, adapt(delta, handled + 1, handled == basic), handled + 1, acc}

            _char, state ->
              state
          end)

        encode(input, m + 1, delta + 1, bias, handled, basic, acc)
    end
  end

  defp variable_integer(q, bias, k, acc) do
    t = threshold(k, bias)

    if q < t,
      do: [digit(q) | acc],
      else:
        variable_integer(div(q - t, @base - t), bias, k + @base, [
          digit(t + rem(q - t, @base - t)) | acc
        ])
  end

  defp threshold(k, bias) when k <= bias, do: @tmin
  defp threshold(k, bias) when k >= bias + @tmax, do: @tmax
  defp threshold(k, bias), do: k - bias

  defp adapt(delta, points, first?) do
    delta = if first?, do: div(delta, @damp), else: div(delta, 2)
    scale(delta + div(delta, points), 0)
  end

  defp scale(delta, k) when delta > div((@base - @tmin) * @tmax, 2),
    do: scale(div(delta, @base - @tmin), k + @base)

  defp scale(delta, k), do: k + div((@base - @tmin + 1) * delta, delta + @skew)

  defp digit(d) when d < 26, do: ?a + d
  defp digit(d), do: ?0 + d - 26
end
