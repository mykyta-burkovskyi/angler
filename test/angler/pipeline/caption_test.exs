defmodule Angler.Pipeline.CaptionTest do
  use ExUnit.Case, async: true

  import Angler.TelegramFixtures, only: [utf16_length: 1]

  alias Angler.Entries.Entry
  alias Angler.Pipeline.Caption
  alias Angler.Settings.Setting

  @limit 1024

  describe "build/2" do
    test "posts the title as it is" do
      assert Caption.build(
               "Rick Astley - Never Gonna Give You Up",
               "https://youtu.be/dQw4w9WgXcQ"
             ) ==
               "Rick Astley - Never Gonna Give You Up"

      assert Caption.build("Video by anglerfish", "https://www.instagram.com/reel/C8xAbC/") ==
               "Video by anglerfish"
    end

    test "keeps markup as plain text" do
      title = "<b>bold</b> *stars* _under_ [link](https://example.com) `code` #fyp @someone"
      assert Caption.build(title, "https://www.tiktok.com/@a/video/1") == title
    end

    test "skips missing and blank titles" do
      assert Caption.build(nil, "https://youtu.be/x") == nil
      assert Caption.build("", "https://youtu.be/x") == nil
      assert Caption.build("   \n\t \r\n ", "https://youtu.be/x") == nil
      assert Caption.build(<<0xFF, 0xFE>>, "https://youtu.be/x") == nil
    end

    test "skips a title that is just the source URL or another link" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      assert Caption.build(url, url) == nil
      assert Caption.build("  #{url}  ", url) == nil
      assert Caption.build("youtube.com/watch?v=dQw4w9WgXcQ", url) == nil
      assert Caption.build("HTTP://WWW.YOUTUBE.COM/watch?v=dqw4w9wgxcq/", url) == nil
      assert Caption.build("https://youtu.be/dQw4w9WgXcQ", url) == nil
    end

    test "skips a title that is just the video id" do
      assert Caption.build("dQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil
      assert Caption.build("dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ?si=abc") == nil
      assert Caption.build("C8xAbC", "https://www.instagram.com/reel/C8xAbC/") == nil

      # yt-dlp's generic extractor names a file after its name.
      assert Caption.build("clip", "https://example.com/media/clip.mp4") == nil
      assert Caption.build("my clip", "https://example.com/my%20clip.mp4") == nil

      # A numeric id behind a short link, also in yt-dlp's fallback titles.
      assert Caption.build("7234567890123456789", "https://vm.tiktok.com/ZMabcdef/") == nil
      assert Caption.build("#7234567890123456789", "https://vm.tiktok.com/ZMabcdef/") == nil
      assert Caption.build("Facebook video #1234567890123", "https://fb.watch/abcDEF/") == nil

      assert Caption.build("TikTok video #7234567890123456789", "https://vm.tiktok.com/ZMa/") ==
               nil

      assert Caption.build(
               "Facebook video #abcDEF",
               "https://www.facebook.com/watch/?v=abcDEF"
             ) == nil
    end

    test "keeps short titles that only look like ids" do
      assert Caption.build("Funny video #3", "https://example.com/watch/42") == "Funny video #3"
      assert Caption.build("2024", "https://example.com/watch/42") == "2024"
      assert Caption.build("Wow", "https://example.com/watch/42") == "Wow"
      assert Caption.build("Wow", nil) == "Wow"
      assert Caption.build("Wow", "https://bad.test/%zz") == "Wow"
    end

    test "trims whitespace and collapses runs of blank lines" do
      title =
        "\n  First line  \r\n\r\n\r\n   \n\t\nSecond line\t\r\nThird line\n\n\n\n  Indented\n\n  "

      assert Caption.build(title, "https://youtu.be/x") ==
               "First line\n\nSecond line\nThird line\n\n  Indented"
    end

    test "removes control characters, keeping tabs" do
      assert Caption.build("Bell\a and\u0000 NUL\u0085\tend", "https://youtu.be/x") ==
               "Bell and NUL\tend"
    end

    test "keeps a title exactly at the limit, counted in UTF-16 code units" do
      # 😀 takes 2 UTF-16 code units, 👨‍👩‍👧 (one grapheme) 8.
      title = String.duplicate("a", @limit - 10) <> "😀" <> "👨‍👩‍👧"
      assert utf16_length(title) == @limit
      assert String.length(title) < @limit

      assert Caption.build(title, "https://youtu.be/x") == title
    end

    test "cuts a longer title on a grapheme boundary and ends it with an ellipsis" do
      # One more unit: the family (8 units) no longer fits with the ellipsis.
      title = String.duplicate("a", @limit - 9) <> "😀" <> "👨‍👩‍👧"
      assert utf16_length(title) == @limit + 1

      caption = Caption.build(title, "https://youtu.be/x")
      assert caption == String.duplicate("a", @limit - 9) <> "😀…"
      assert utf16_length(caption) <= @limit

      # An emoji straddling the cut is dropped whole, never split.
      title = String.duplicate("a", @limit - 2) <> "😀" <> "b"
      caption = Caption.build(title, "https://youtu.be/x")
      assert caption == String.duplicate("a", @limit - 2) <> "…"
      assert utf16_length(caption) == @limit - 1
      assert String.valid?(caption)
    end

    test "cuts a long emoji-only title to exactly the limit" do
      title = String.duplicate("😀", 600)
      caption = Caption.build(title, "https://youtu.be/x")

      assert caption == String.duplicate("😀", 511) <> "…"
      assert utf16_length(caption) == @limit - 1
    end

    test "trims whitespace before the ellipsis of a cut title" do
      title = String.duplicate("a", @limit - 4) <> "   " <> String.duplicate("b", 10)

      assert Caption.build(title, "https://youtu.be/x") ==
               String.duplicate("a", @limit - 4) <> "…"
    end

    test "cuts a long multi-line title after collapsing its blank lines" do
      title = Enum.map_join(1..200, "\n\n\n\n", &"Line #{&1}")
      caption = Caption.build(title, "https://youtu.be/x")

      assert String.starts_with?(caption, "Line 1\n\nLine 2\n\nLine 3")
      assert String.ends_with?(caption, "…")
      refute caption =~ "\n\n\n"
      assert utf16_length(caption) <= @limit
    end
  end

  describe "build/3" do
    test "cuts at :max_length instead of the caption limit" do
      title = String.duplicate("word ", 800)

      assert Caption.build(title, "https://youtu.be/x", max_length: 4096) ==
               String.trim(title)

      caption = Caption.build(title <> "end", "https://youtu.be/x", max_length: 100)
      assert caption == String.duplicate("word ", 19) <> "word…"
      assert utf16_length(caption) <= 100
    end
  end

  describe "split/3" do
    test "posts a title that fits as the caption" do
      entry = %Entry{title: "  A title \n", url: "https://youtu.be/x"}

      assert Caption.split(entry, %Setting{}) == {"A title", nil}
      assert Caption.split(%{entry | title: "x"}, %Setting{}) == {nil, nil}
      assert Caption.split(%{entry | title: nil}, %Setting{}) == {nil, nil}
    end

    test "keeps a text exactly at the caption limit in the caption" do
      title = String.duplicate("a", @limit - 2) <> "😀"
      entry = %Entry{title: title, url: "https://youtu.be/x"}

      assert Caption.split(entry, %Setting{}) == {title, nil}
    end

    test "sends a longer text whole as the follow-up instead of cutting it" do
      title = Enum.map_join(1..60, "\n\n\n", &"Paragraph #{&1}: #{String.duplicate("🎣", 10)}")
      assert utf16_length(title) > @limit
      entry = %Entry{title: title, url: "https://www.instagram.com/p/C8xAbC/"}

      assert {nil, follow_up} = Caption.split(entry, %Setting{})
      assert follow_up == String.replace(title, "\n\n\n", "\n\n")
      refute String.ends_with?(follow_up, "…")
    end

    test "cuts a text to the limit of a message" do
      title = String.duplicate("😀", 3000)
      entry = %Entry{title: title, url: "https://youtu.be/x"}

      assert {nil, follow_up} = Caption.split(entry, %Setting{})
      assert follow_up == String.duplicate("😀", 2047) <> "…"
      assert utf16_length(follow_up) == 4096 - 1
    end

    test "with truncate_caption, also posts a longer text cut to fit the caption" do
      title = Enum.map_join(1..60, "\n\n\n", &"Paragraph #{&1}: #{String.duplicate("🎣", 10)}")
      entry = %Entry{title: title, url: "https://www.instagram.com/p/C8xAbC/"}
      text = String.replace(title, "\n\n\n", "\n\n")

      assert {caption, ^text} = Caption.split(entry, %Setting{}, truncate_caption: true)
      assert caption == Caption.build(title)
      assert String.ends_with?(caption, "…")
      assert utf16_length(caption) <= @limit
      assert String.starts_with?(text, String.trim_trailing(caption, "…"))

      # A text that fits is only the caption, as without the option.
      short = %{entry | title: "A title"}
      assert Caption.split(short, %Setting{}, truncate_caption: true) == {"A title", nil}
      assert Caption.split(entry, %Setting{}, truncate_caption: false) == {nil, text}
    end

    test "sends no text when titles aren't posted" do
      entry = %Entry{title: String.duplicate("a", 2000), url: "https://youtu.be/x"}

      assert Caption.split(entry, %Setting{title_captions: false}) == {nil, nil}

      assert Caption.split(entry, %Setting{title_captions: false}, truncate_caption: true) ==
               {nil, nil}

      assert Caption.split(%{entry | title: "A title"}, %Setting{title_captions: false}) ==
               {nil, nil}
    end
  end
end
