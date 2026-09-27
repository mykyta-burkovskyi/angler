defmodule Angler.Links.IDNTest do
  use ExUnit.Case, async: true

  alias Angler.Links.IDN

  test "encodes non-ASCII labels with Punycode" do
    assert IDN.to_ascii("пример.рф") == "xn--e1afmkfd.xn--p1ai"
    assert IDN.to_ascii("bücher.de") == "xn--bcher-kva.de"
    assert IDN.to_ascii("例え.テスト") == "xn--r8jz45g.xn--zckzah"
  end

  test "matches the samples of RFC 3492" do
    samples = [
      {[
         0x0644,
         0x064A,
         0x0647,
         0x0645,
         0x0627,
         0x0628,
         0x062A,
         0x0643,
         0x0644,
         0x0645,
         0x0648,
         0x0634,
         0x0639,
         0x0631,
         0x0628,
         0x064A,
         0x061F
       ], "egbpdaj6bu4bxfgehfvwxn"},
      {[0x4ED6, 0x4EEC, 0x4E3A, 0x4EC0, 0x4E48, 0x4E0D, 0x8BF4, 0x4E2D, 0x6587],
       "ihqwcrb4cv8a8dqg056pqjye"},
      {[0x0033, 0x5E74, 0x0042, 0x7D44, 0x91D1, 0x516B, 0x5148, 0x751F],
       "3b-ww4c5e180e575a65lsy2b"},
      {[0x5B89, 0x5BA4, 0x5948, 0x7F8E, 0x6075] ++ ~c"-with-SUPER-MONKEYS",
       "-with-super-monkeys-pc58ag80a8qai00g7n9n"}
    ]

    for {code_points, punycode} <- samples do
      assert IDN.to_ascii(List.to_string(code_points)) == "xn--" <> punycode
    end
  end

  test "lowercases, normalizes to NFC and accepts other full stops" do
    assert IDN.to_ascii("ПРИМЕР。РФ") == "xn--e1afmkfd.xn--p1ai"
    # "u" followed by a combining diaeresis is "ü".
    assert IDN.to_ascii("bücher.de") == "xn--bcher-kva.de"
  end

  test "leaves ASCII labels and invalid UTF-8 alone" do
    assert IDN.to_ascii("www.Example.com") == "www.example.com"
    assert IDN.to_ascii("пример.example.com") == "xn--e1afmkfd.example.com"
    assert IDN.to_ascii(<<0xFF, ?a>>) == <<0xFF, ?a>>
  end
end
