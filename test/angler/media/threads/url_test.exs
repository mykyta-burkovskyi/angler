defmodule Angler.Media.Threads.UrlTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Threads.Url

  describe "parse/1" do
    for {url, expected} <- [
          {"https://www.threads.com/@nasa/post/DeUWxGgjHSK", {:post, "DeUWxGgjHSK", "nasa"}},
          {"https://www.threads.com/@nasa/post/DePPcDfkc_a?xmt=AQG0&slof=1",
           {:post, "DePPcDfkc_a", "nasa"}},
          {"https://threads.com/@some.user_1/post/Dd-1_x/media",
           {:post, "Dd-1_x", "some.user_1"}},
          {"http://WWW.Threads.NET/@nasa/post/DeUWxGgjHSK/", {:post, "DeUWxGgjHSK", "nasa"}},
          {"https://threads.net/@zuck/post/Ddt7cL5EfUG/embed", {:post, "Ddt7cL5EfUG", "zuck"}},
          {"https://www.threads.com/t/DeUWxGgjHSK", {:post, "DeUWxGgjHSK", nil}},
          {"https://www.threads.net/t/DeUWxGgjHSK/", {:post, "DeUWxGgjHSK", nil}},
          {"https://www.threads.com/share/AbCdEf12_-/",
           {:share, "https://www.threads.com/share/AbCdEf12_-/"}},
          {"https://threads.net/share/AbCdEf12_-?x=1",
           {:share, "https://www.threads.com/share/AbCdEf12_-/"}},
          {"http://user:pw@www.threads.com:8443/share/AbCdEf12_-",
           {:share, "https://www.threads.com/share/AbCdEf12_-/"}},
          {"https://www.threads.com/@nasa", :not_threads},
          {"https://www.threads.com/@nasa/post/", :not_threads},
          {"https://www.threads.com/@nasa/replies", :not_threads},
          {"https://www.threads.com/search?q=nasa", :not_threads},
          {"https://www.threads.com/share/", :not_threads},
          {"https://www.threads.com/share/AbCdEf12_-/extra", :not_threads},
          {"https://www.threads.com/t/" <> String.duplicate("a", 65), :not_threads},
          {"https://www.threads.com/@" <> String.duplicate("a", 65) <> "/post/DeUWxGgjHSK",
           :not_threads},
          {"https://www.threads.com/", :not_threads},
          {"https://www.threads.com.evil.test/@nasa/post/DeUWxGgjHSK", :not_threads},
          {"https://notthreads.com/@nasa/post/DeUWxGgjHSK", :not_threads},
          {"https://www.instagram.com/p/DeUWxGgjHSK/", :not_threads},
          {"ftp://www.threads.com/@nasa/post/DeUWxGgjHSK", :not_threads},
          {"www.threads.com/@nasa/post/DeUWxGgjHSK", :not_threads},
          {"not a url", :not_threads}
        ] do
      test "#{inspect(url)}" do
        assert Url.parse(unquote(url)) == unquote(Macro.escape(expected))
      end
    end

    test "is :not_threads for anything but a string" do
      assert Url.parse(nil) == :not_threads
    end
  end

  test "canonical/2" do
    assert Url.canonical("DeUWxGgjHSK", "nasa") ==
             "https://www.threads.com/@nasa/post/DeUWxGgjHSK"

    assert Url.canonical("DeUWxGgjHSK", nil) == "https://www.threads.com/t/DeUWxGgjHSK"
  end
end
