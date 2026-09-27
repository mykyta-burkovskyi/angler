defmodule Angler.Media.TikTok.ChallengeTest do
  use ExUnit.Case, async: true

  import Angler.TikTokFixtures, only: [challenge_page: 1, challenge_page: 2, page: 1]

  alias Angler.Media.TikTok.Challenge

  # No recorded challenge page exists; this one follows the documented format.
  defp answer_cookie(cookie) do
    [name_value | _rest] = String.split(cookie, "; ")
    ["_wafchallengeid", value] = String.split(name_value, "=", parts: 2)
    value |> Base.decode64!() |> Jason.decode!()
  end

  test "challenge?/1 recognizes the proof-of-work page" do
    assert Challenge.challenge?(challenge_page(3))
    refute Challenge.challenge?(page(%{"statusCode" => 0}))
  end

  test "solve/1 finds the answer and builds both cookies" do
    assert {:ok, cookie} = Challenge.solve(challenge_page(57))

    assert ["_wafchallengeid=" <> _answer, "waforiginalreid=rs-value-42"] =
             String.split(cookie, "; ")

    challenge = answer_cookie(cookie)
    assert Base.decode64!(challenge["d"]) == "57"
    # The rest of the challenge is sent back unchanged.
    assert challenge["s"] == "7c1d"
    assert challenge["e"] == 1_790_431_482
    assert %{"a" => _salt, "c" => _digest} = challenge["v"]
  end

  test "solve/1 uses the default cookie name and skips the optional cookie when absent" do
    assert {:ok, cookie} = Challenge.solve(challenge_page(0, extra: false))
    refute cookie =~ ";"
    assert Base.decode64!(answer_cookie(cookie)["d"]) == "0"
  end

  test "solve/1 accepts the class before the id and unpadded Base64" do
    html = challenge_page(123)
    [_, encoded] = Regex.run(~r/id="cs" class="([^"]*)"/, html)

    swapped =
      String.replace(
        html,
        ~s(id="cs" class="#{encoded}"),
        ~s(class="#{String.trim_trailing(encoded, "=")}" id="cs")
      )

    assert {:ok, cookie} = Challenge.solve(swapped)
    assert Base.decode64!(answer_cookie(cookie)["d"]) == "123"
  end

  test "solve/1 ignores cookie names and values that could inject headers" do
    html =
      challenge_page(5, extra: false) <>
        ~s(<p id="wci" class="bad name;x=1"></p><p id="rci" class="ok"></p><p id="rs" class="a;b"></p>)

    assert {:ok, cookie} = Challenge.solve(html)
    assert "_wafchallengeid=" <> _value = cookie
    refute cookie =~ ";"
  end

  test "solve/1 returns :error without a solvable challenge" do
    assert Challenge.solve("<html></html>") == :error
    assert Challenge.solve(~s(<div id="cs" class="%%%"></div>)) == :error
    assert Challenge.solve(~s(<div id="cs" class="#{Base.encode64("{}")}"></div>)) == :error

    wrong_digest = Base.encode64(Jason.encode!(%{"v" => %{"a" => "c2FsdA==", "c" => "c2hvcnQ="}}))
    assert Challenge.solve(~s(<div id="cs" class="#{wrong_digest}"></div>)) == :error
  end

  test "find_answer/2 searches 0..1_000_000 and gives up beyond" do
    digest = &:crypto.hash(:sha256, "salt" <> Integer.to_string(&1))

    assert Challenge.find_answer("salt", digest.(0)) == 0
    assert Challenge.find_answer("salt", digest.(999)) == 999
    assert Challenge.find_answer("salt", digest.(1_000_000)) == 1_000_000
    assert Challenge.find_answer("salt", digest.(1_000_001)) == nil
    assert Challenge.find_answer("salt", "not a digest") == nil
  end
end
