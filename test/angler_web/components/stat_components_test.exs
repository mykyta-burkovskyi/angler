defmodule AnglerWeb.StatComponentsTest do
  use ExUnit.Case, async: true

  import AnglerWeb.ComponentTestHelpers
  import AnglerWeb.StatComponents

  test "stat_card/1 renders the value and caption" do
    html =
      render_html(&stat_card/1,
        id: "stat-x",
        label: "Queued",
        value: "1,234",
        icon: "hero-inbox",
        inner_block: [%{inner_block: fn _, _ -> "Waiting" end}]
      )

    assert text(html, "#stat-x [data-role=value]") =~ "1,234"
    assert text(html, "#stat-x") =~ "Waiting"
  end

  describe "storage_meter/1" do
    @usage %{
      used_bytes: 4_200_000_000,
      limit_bytes: 10_000_000_000,
      entries_with_files: 12,
      disk_total_bytes: 500_000_000_000,
      disk_free_bytes: 120_000_000_000
    }

    test "shows usage against the limit" do
      html = render_html(&storage_meter/1, id: "meter", usage: @usage)

      assert text(html, "[data-role=used]") =~ "4.2 GB"
      assert text(html, "[data-role=limit]") =~ "10 GB"
      assert text(html, "[data-role=percent]") =~ "42%"
      assert attribute(html, "[data-level]", "data-level") == "normal"
      assert text(html, "#meter") =~ "12 entries hold files"
      assert text(html, "#meter") =~ "120 GB free on disk"
    end

    test "warns when nearly full" do
      high = render_html(&storage_meter/1, id: "m", usage: %{@usage | used_bytes: 8_000_000_000})
      full = render_html(&storage_meter/1, id: "m", usage: %{@usage | used_bytes: 9_500_000_000})

      assert attribute(high, "[data-level]", "data-level") == "high"
      assert attribute(full, "[data-level]", "data-level") == "critical"
    end

    test "copes with unknown disk space and no limit" do
      usage = %{@usage | limit_bytes: 0, disk_free_bytes: nil, entries_with_files: 1}
      html = render_html(&storage_meter/1, id: "meter", usage: usage)

      assert text(html, "[data-role=percent]") =~ "0%"
      assert text(html, "#meter") =~ "1 entry holds files"
      refute text(html, "#meter") =~ "free on disk"
    end
  end
end
