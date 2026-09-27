defmodule AnglerWeb.FormatTest do
  use ExUnit.Case, async: true

  alias AnglerWeb.Format

  doctest AnglerWeb.Format

  describe "bytes/1" do
    test "uses decimal units with one decimal below 100" do
      assert Format.bytes(0) == "0 B"
      assert Format.bytes(999) == "999 B"
      assert Format.bytes(1_000) == "1 kB"
      assert Format.bytes(1_500) == "1.5 kB"
      assert Format.bytes(12_345_678) == "12.3 MB"
      assert Format.bytes(99_960_000) == "100 MB"
      assert Format.bytes(123_456_789) == "123 MB"
      assert Format.bytes(10_240_000_000) == "10.2 GB"
      assert Format.bytes(2_000_000_000_000) == "2 TB"
    end

    test "moves to the next unit instead of showing 1000" do
      assert Format.bytes(999_499) == "999 kB"
      assert Format.bytes(999_600) == "1 MB"
    end

    test "renders a placeholder for nil" do
      assert Format.bytes(nil) == "—"
    end
  end

  test "number/1 adds thousands separators" do
    assert Format.number(0) == "0"
    assert Format.number(999) == "999"
    assert Format.number(1_000) == "1,000"
    assert Format.number(1_234_567) == "1,234,567"
    assert Format.number(-12_345) == "-12,345"
    assert Format.number(nil) == "—"
  end

  test "duration/1 formats media durations as a clock" do
    assert Format.duration(0) == "0:00"
    assert Format.duration(5) == "0:05"
    assert Format.duration(65) == "1:05"
    assert Format.duration(65.9) == "1:05"
    assert Format.duration(600) == "10:00"
    assert Format.duration(3_723) == "1:02:03"
    assert Format.duration(nil) == "—"
  end

  describe "elapsed/1" do
    test "shows the two most significant units" do
      assert Format.elapsed(0) == "0s"
      assert Format.elapsed(45) == "45s"
      assert Format.elapsed(60) == "1m"
      assert Format.elapsed(125) == "2m 5s"
      assert Format.elapsed(3_600) == "1h"
      assert Format.elapsed(7_380) == "2h 3m"
      assert Format.elapsed(168 * 3_600) == "7d"
      assert Format.elapsed(90_000) == "1d 1h"
    end

    test "rounds fractions and clamps negative spans" do
      assert Format.elapsed(1.6) == "2s"
      assert Format.elapsed(-5) == "0s"
      assert Format.elapsed(nil) == "—"
    end
  end

  test "elapsed/2 measures between two datetimes" do
    from = ~U[2026-09-26 10:00:00Z]

    assert Format.elapsed(from, ~U[2026-09-26 10:00:42Z]) == "42s"
    assert Format.elapsed(from, ~U[2026-09-26 12:30:00Z]) == "2h 30m"
    assert Format.elapsed(from, nil) == "—"
    assert Format.elapsed(nil, from) == "—"
  end

  describe "relative_time/2" do
    @now ~U[2026-09-26 12:00:00Z]

    test "describes past times" do
      assert Format.relative_time(DateTime.add(@now, -10), @now) == "just now"
      assert Format.relative_time(DateTime.add(@now, -50), @now) == "1 min ago"
      assert Format.relative_time(DateTime.add(@now, -3 * 60), @now) == "3 min ago"
      assert Format.relative_time(DateTime.add(@now, -59 * 60 - 50), @now) == "1 h ago"
      assert Format.relative_time(DateTime.add(@now, -5 * 3_600), @now) == "5 h ago"
      assert Format.relative_time(DateTime.add(@now, -2 * 86_400), @now) == "2 d ago"
    end

    test "describes future times" do
      assert Format.relative_time(DateTime.add(@now, 10), @now) == "in a moment"
      assert Format.relative_time(DateTime.add(@now, 2 * 60), @now) == "in 2 min"
      assert Format.relative_time(DateTime.add(@now, 3 * 3_600), @now) == "in 3 h"
    end

    test "shows a date beyond a week" do
      assert Format.relative_time(~U[2026-09-03 08:00:00Z], @now) == "Sep 3"
      assert Format.relative_time(~U[2025-12-24 08:00:00Z], @now) == "Dec 24, 2025"
    end

    test "defaults to the current time and handles nil" do
      assert Format.relative_time(DateTime.utc_now()) == "just now"
      assert Format.relative_time(nil) == "—"
    end
  end

  test "datetime/1 formats an absolute UTC timestamp" do
    assert Format.datetime(~U[2026-09-26 14:03:05.123456Z]) == "2026-09-26 14:03:05 UTC"
    assert Format.datetime(nil) == "—"
  end

  describe "chat_label/1" do
    test "prefers the chat title" do
      assert Format.chat_label(%{chat_title: "Memes", chat_type: "supergroup", chat_id: -100}) ==
               "Memes"
    end

    test "uses the sender's name for private chats" do
      assert Format.chat_label(%{chat_title: nil, chat_type: "private", from_name: "Ann"}) ==
               "Ann"

      assert Format.chat_label(%{chat_title: nil, chat_type: "private", from_name: nil}) ==
               "Private chat"
    end

    test "falls back to the chat id" do
      assert Format.chat_label(%{chat_title: "", chat_type: "group", chat_id: -42}) == "Chat -42"
      assert Format.chat_label(%{}) == "Unknown chat"
    end
  end

  test "truncate/2 cuts long text with an ellipsis" do
    assert Format.truncate("short", 10) == "short"
    assert Format.truncate("exactly10!", 10) == "exactly10!"
    assert Format.truncate("this is too long", 8) == "this is…"
    assert Format.truncate(nil, 5) == ""
  end

  test "host/1 extracts the host without www" do
    assert Format.host("https://www.TikTok.com/@a/video/1") == "tiktok.com"
    assert Format.host("https://youtu.be/abc") == "youtu.be"
    assert Format.host("not a url") == nil
    assert Format.host(nil) == nil
  end

  test "percent/2 is clamped and safe with unknown totals" do
    assert Format.percent(25, 100) == 25.0
    assert Format.percent(150, 100) == 100.0
    assert Format.percent(-5, 100) == 0.0
    assert Format.percent(5, 0) == 0.0
    assert Format.percent(nil, 100) == 0.0
  end
end
