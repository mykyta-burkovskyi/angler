defmodule AnglerWeb.CommonComponentsTest do
  use ExUnit.Case, async: true

  import AnglerWeb.ComponentTestHelpers
  import AnglerWeb.CommonComponents

  test "empty_state/1 renders its title, text and actions" do
    html =
      render_html(&empty_state/1,
        id: "empty",
        icon: "hero-inbox",
        title: "Nothing here",
        inner_block: [%{inner_block: fn _, _ -> "Come back later" end}],
        actions: [%{inner_block: fn _, _ -> "Reload" end}]
      )

    assert text(html, "#empty h3") == "Nothing here"
    assert text(html, "#empty") =~ "Come back later"
    assert text(html, "#empty") =~ "Reload"
  end

  test "panel/1 renders a titled card" do
    html =
      render_html(&panel/1,
        id: "p",
        title: "Storage",
        description: "On disk",
        inner_block: [%{inner_block: fn _, _ -> "Body" end}]
      )

    assert text(html, "#p h2") == "Storage"
    assert text(html, "#p") =~ "On disk"
    assert text(html, "#p") =~ "Body"
  end

  test "relative_time/1 renders a machine-readable time" do
    at = ~U[2026-09-26 12:00:00Z]
    html = render_html(&relative_time/1, id: "t", at: at)

    assert attribute(html, "time#t", "datetime") == "2026-09-26T12:00:00Z"
    assert attribute(html, "time#t", "title") == "2026-09-26 12:00:00 UTC"
    assert attribute(html, "time#t", "phx-update") == "ignore"
  end

  test "copy_button/1 carries the value to copy" do
    html = render_html(&copy_button/1, id: "copy", value: "secret-ish", label: "Copy link")

    assert attribute(html, "#copy", "data-copy") == "secret-ish"
    assert attribute(html, "#copy", "aria-label") == "Copy link"
  end
end
