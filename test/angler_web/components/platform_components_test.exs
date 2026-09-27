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
end
