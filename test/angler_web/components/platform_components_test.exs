defmodule AnglerWeb.PlatformComponentsTest do
  use ExUnit.Case, async: true

  import AnglerWeb.ComponentTestHelpers
  import AnglerWeb.PlatformComponents

  test "platform_tile/1 falls back to an icon for unknown hosts" do
    html = render_html(&platform_tile/1, host: "example.com")
    assert exists?(html, ".hero-film")

    html = render_html(&platform_tile/1, host: "m.youtube.com")
    assert text(html, "div[title=YouTube]") =~ "YT"
  end

  test "platform_name/1 names known platforms" do
    assert platform_name("vm.tiktok.com") == "TikTok"
    assert platform_name("example.com") == nil
  end

  test "TikTok's share domain is TikTok too" do
    assert platform_name("www.tt.site") == "TikTok"
    assert platform_name("tt.site") == "TikTok"
  end

  test "Instagram's short domain is Instagram too" do
    assert platform_name("instagr.am") == "Instagram"
    assert platform_name("www.instagr.am") == "Instagram"
    assert platform_name("instagram.com") == "Instagram"
    assert platform_name("notinstagr.am") == nil

    html = render_html(&platform_tile/1, host: "instagr.am")
    assert text(html, "div[title=Instagram]") =~ "IG"
  end
end
