defmodule Angler.Media.TikTok.Challenge do
  @moduledoc """
  Solves the proof-of-work page TikTok's firewall sometimes serves instead of a post.

  The page carries the challenge in element classes:

    * `#cs` - Base64 JSON `c` with `c.v.a` (Base64 salt) and `c.v.c` (Base64
      SHA-256 digest). The answer is the number `n` in `0..1_000_000` with
      `sha256(salt <> Integer.to_string(n)) == digest`
    * `#wci` - the name of the answer cookie (`_wafchallengeid` so far), whose value
      is Base64 of `c` with `"d" => Base64(n)` added
    * `#rci` and `#rs` - optional: another cookie name and its value

  Fetching the page again with those cookies returns the real page. The search is
  bounded by the number range (about a second in the worst case); the answer has
  been below 100 in practice.
  """

  @max_answer 1_000_000
  @token ~r/\A[A-Za-z0-9_\-]+\z/
  @cookie_value ~r/\A[A-Za-z0-9_\-+\/=.]+\z/

  @doc "Whether `html` is the challenge page (it has an element with id `cs`)."
  @spec challenge?(String.t()) :: boolean()
  def challenge?(html), do: class_of(html, "cs") != nil

  @doc """
  Solves the challenge in `html` and returns the `cookie` header value to send with
  the next request, or `:error` when the page holds no solvable challenge.
  """
  @spec solve(String.t()) :: {:ok, String.t()} | :error
  def solve(html) when is_binary(html) do
    with encoded when is_binary(encoded) <- class_of(html, "cs"),
         {:ok, json} <- Base.decode64(encoded, padding: false),
         {:ok, %{"v" => %{"a" => salt, "c" => digest}} = challenge} <- Jason.decode(json),
         {:ok, salt} <- decode(salt),
         {:ok, digest} <- decode(digest),
         n when is_integer(n) <- find_answer(salt, digest) do
      answer =
        challenge
        |> Map.put("d", Base.encode64(Integer.to_string(n)))
        |> Jason.encode!()
        |> Base.encode64()

      cookies = [{cookie_name(html), answer} | extra_cookie(html)]
      {:ok, Enum.map_join(cookies, "; ", fn {name, value} -> name <> "=" <> value end)}
    else
      _other -> :error
    end
  end

  @doc "The answer `n` with `sha256(salt <> to_string(n)) == digest`, or nil."
  @spec find_answer(binary(), binary()) :: non_neg_integer() | nil
  def find_answer(salt, digest) when byte_size(digest) == 32 do
    Enum.find(0..@max_answer, &(:crypto.hash(:sha256, [salt, Integer.to_string(&1)]) == digest))
  end

  def find_answer(_salt, _digest), do: nil

  defp decode(value) when is_binary(value), do: Base.decode64(value, padding: false)
  defp decode(_value), do: :error

  defp cookie_name(html) do
    case class_of(html, "wci") do
      name when is_binary(name) -> if name =~ @token, do: name, else: "_wafchallengeid"
      nil -> "_wafchallengeid"
    end
  end

  defp extra_cookie(html) do
    with name when is_binary(name) <- class_of(html, "rci"),
         value when is_binary(value) <- class_of(html, "rs"),
         true <- name =~ @token and value =~ @cookie_value do
      [{name, value}]
    else
      _other -> []
    end
  end

  # The class of the element with the given id, whichever attribute comes first.
  defp class_of(html, id) do
    patterns = [
      ~r/<[^>]+\bid="#{id}"[^>]*\bclass="([^"]*)"/,
      ~r/<[^>]+\bclass="([^"]*)"[^>]*\bid="#{id}"/
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, html, capture: :all_but_first) do
        [value] -> value
        nil -> nil
      end
    end)
  end
end
