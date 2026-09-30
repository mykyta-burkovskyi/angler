defmodule Angler.Media.Instagram.UrlTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Instagram.Url

  describe "parse/1" do
    for {url, expected} <- [
          {"https://www.instagram.com/p/DdwalmrkTSK/", {:post, "DdwalmrkTSK"}},
          {"https://www.instagram.com/p/DdwalmrkTSK/?img_index=2&igsh=abc",
           {:post, "DdwalmrkTSK"}},
          {"https://instagram.com/reel/Chunk8-jurw", {:post, "Chunk8-jurw"}},
          {"https://m.instagram.com/reels/Chunk8-jurw/", {:post, "Chunk8-jurw"}},
          {"https://www.instagram.com/tv/BQ0eAlwhDrw/", {:post, "BQ0eAlwhDrw"}},
          {"https://www.instagram.com/instagram/p/DdwalmrkTSK/", {:post, "DdwalmrkTSK"}},
          {"https://www.instagram.com/some.user_1/reel/Ddr-AMmDxqn/", {:post, "Ddr-AMmDxqn"}},
          {"http://WWW.Instagram.COM/p/Ddwoj5kBk9X", {:post, "Ddwoj5kBk9X"}},
          {"https://www.instagram.com/p/DduKfFmDxsG/embed/captioned/", {:post, "DduKfFmDxsG"}},
          {"https://instagr.am/p/DdwalmrkTSK/", {:post, "DdwalmrkTSK"}},
          {"http://www.instagr.am/reel/Chunk8-jurw/", {:post, "Chunk8-jurw"}},
          {"https://www.instagram.com/share/_a7bsO89b",
           {:share, "https://www.instagram.com/share/_a7bsO89b"}},
          {"https://instagram.com/share/p/BBFVaX2n1Y/?igsh=x",
           {:share, "https://www.instagram.com/share/p/BBFVaX2n1Y/"}},
          {"http://user:pw@m.instagram.com:8443/share/reel/_0ML8mSEs",
           {:share, "https://www.instagram.com/share/reel/_0ML8mSEs"}},
          {"https://www.instagram.com/instagram/", :not_instagram},
          {"https://www.instagram.com/instagram/reels/", :not_instagram},
          {"https://www.instagram.com/reels/audio/1234567890/", :not_instagram},
          {"https://www.instagram.com/stories/instagram/3994871258327437143/", :not_instagram},
          {"https://www.instagram.com/share/", :not_instagram},
          {"https://instagr.am/share/abc", :not_instagram},
          {"https://www.instagram.com/p/" <> String.duplicate("a", 65) <> "/", :not_instagram},
          {"https://www.instagram.com/", :not_instagram},
          {"https://www.instagram.com.evil.test/p/DdwalmrkTSK/", :not_instagram},
          {"https://notinstagram.com/p/DdwalmrkTSK/", :not_instagram},
          {"https://ig.me/p/DdwalmrkTSK/", :not_instagram},
          {"ftp://www.instagram.com/p/DdwalmrkTSK/", :not_instagram},
          {"www.instagram.com/p/DdwalmrkTSK/", :not_instagram},
          {"https://www.tiktok.com/@a/video/1", :not_instagram},
          {"not a url", :not_instagram}
        ] do
      test "#{url}" do
        assert Url.parse(unquote(url)) == unquote(Macro.escape(expected))
      end
    end

    test "accepts only strings" do
      assert Url.parse(nil) == :not_instagram
    end
  end

  test "pk/1 reads the code as Base64url digits" do
    assert Url.pk("DdwalmrkTSK") == "3994809802840683658"
    assert Url.pk("Chunk8-jurw") == "2913440072144448240"
    assert Url.pk("Ddwoj5kBk9X") == "3994871258327437143"
    # Private share codes carry a 28 character suffix.
    assert Url.pk("DdwalmrkTSK" <> String.duplicate("x", 28)) == "3994809802840683658"
  end

  test "canonical/1" do
    assert Url.canonical("DdwalmrkTSK") == "https://www.instagram.com/p/DdwalmrkTSK/"
  end
end
