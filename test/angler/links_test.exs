defmodule Angler.LinksTest do
  use ExUnit.Case, async: true

  alias Angler.Links

  describe "extract/1" do
    test "slices url entities in UTF-16 code units (emoji take two)" do
      text = "🎣 look https://vm.tiktok.com/ZM123/ 👀 and site.com/x"

      message = %{
        "text" => text,
        "entities" => [
          %{"type" => "url", "offset" => 8, "length" => 28},
          %{"type" => "url", "offset" => 44, "length" => 10}
        ]
      }

      assert Links.extract(message) == ["https://vm.tiktok.com/ZM123/", "https://site.com/x"]
    end

    test "handles characters outside the BMP inside and around the link" do
      text = "𝕏 👨‍👩‍👧 https://example.com/ü/😀 end"
      offset = Angler.TelegramFixtures.utf16_length("𝕏 👨‍👩‍👧 ")
      length = Angler.TelegramFixtures.utf16_length("https://example.com/ü/😀")

      message = %{
        "text" => text,
        "entities" => [%{"type" => "url", "offset" => offset, "length" => length}]
      }

      assert Links.extract(message) == ["https://example.com/%C3%BC/%F0%9F%98%80"]
    end

    test "takes the URL of text_link entities, not the visible text" do
      message = %{
        "text" => "watch this",
        "entities" => [
          %{
            "type" => "text_link",
            "offset" => 6,
            "length" => 4,
            "url" => "https://youtu.be/abc?si=XYZ"
          }
        ]
      }

      assert Links.extract(message) == ["https://youtu.be/abc"]
    end

    test "reads captions of media messages" do
      caption = "look https://x.com/fisher/status/1?s=20"

      message = %{
        "video" => %{"file_id" => "x"},
        "caption" => caption,
        "caption_entities" => Angler.TelegramFixtures.url_entities(caption)
      }

      assert Links.extract(message) == ["https://x.com/fisher/status/1"]
    end

    test "deduplicates normalized links and keeps their order" do
      text =
        "https://www.instagram.com/reel/B/ https://www.instagram.com/reel/A/?igsh=1 " <>
          "https://www.instagram.com/reel/A/"

      message = %{"text" => text, "entities" => Angler.TelegramFixtures.url_entities(text)}

      assert Links.extract(message) == [
               "https://www.instagram.com/reel/B/",
               "https://www.instagram.com/reel/A/"
             ]
    end

    test "returns at most 5 links" do
      text = Enum.map_join(1..7, " ", &"https://example.com/#{&1}")
      message = %{"text" => text, "entities" => Angler.TelegramFixtures.url_entities(text)}

      assert Links.extract(message) == Enum.map(1..5, &"https://example.com/#{&1}")
    end

    test "skips links longer than 2048 bytes once normalized, keeping the others" do
      longest = Angler.TelegramFixtures.long_link(2_048)
      text = "#{Angler.TelegramFixtures.long_link(2_049)} https://youtu.be/abc #{longest}"

      # 700 Cyrillic letters take 1400 bytes, and 4200 once percent-encoded.
      cyrillic = "https://example.com/" <> String.duplicate("я", 700)

      message = %{
        "text" => text,
        "entities" =>
          Angler.TelegramFixtures.url_entities(text) ++
            [%{"type" => "text_link", "offset" => 0, "length" => 1, "url" => cyrillic}]
      }

      assert Links.extract(message) == ["https://youtu.be/abc", longest]
    end

    test "keeps links with characters URIs don't allow" do
      text = "https://example.com/watch?list[0]=1|2"
      message = %{"text" => text, "entities" => Angler.TelegramFixtures.url_entities(text)}

      assert Links.extract(message) == ["https://example.com/watch?list%5B0%5D=1%7C2"]
    end

    test "skips Telegram links, other schemes and other entity types" do
      text = "t.me/channel/1 https://core.telegram.org/bots @fisher /start"

      message = %{
        "text" => text,
        "entities" => [
          %{"type" => "url", "offset" => 0, "length" => 14},
          %{"type" => "url", "offset" => 15, "length" => 30},
          %{"type" => "mention", "offset" => 46, "length" => 7},
          %{"type" => "bot_command", "offset" => 54, "length" => 6},
          %{"type" => "text_link", "offset" => 0, "length" => 1, "url" => "tg://user?id=1"},
          %{"type" => "text_link", "offset" => 0, "length" => 1, "url" => "ftp://example.com/x"},
          %{"type" => "text_link", "offset" => 0, "length" => 1, "url" => "https://telegram.me/x"}
        ]
      }

      assert Links.extract(message) == []
    end

    test "ignores entities outside the text and malformed entities" do
      message = %{
        "text" => "short",
        "entities" => [
          %{"type" => "url", "offset" => 2, "length" => 10},
          %{"type" => "url", "offset" => -1, "length" => 2},
          %{"type" => "url"},
          %{"type" => "text_link", "offset" => 0, "length" => 5, "url" => nil}
        ]
      }

      assert Links.extract(message) == []
    end

    test "returns nothing for messages without text or entities" do
      assert Links.extract(%{"photo" => []}) == []
      assert Links.extract(%{"text" => "https://example.com"}) == []
      assert Links.extract(%{"caption" => "no links", "caption_entities" => nil}) == []
      assert Links.extract(%{"text" => "https://example.com", "entities" => "bogus"}) == []
    end
  end

  describe "normalize/1" do
    test "adds a missing scheme and lowercases scheme and host" do
      assert Links.normalize("youtube.com/watch?v=Abc") == "https://youtube.com/watch?v=Abc"
      assert Links.normalize("HTTP://WWW.Example.COM/Path") == "http://www.example.com/Path"
      assert Links.normalize("  https://example.com/a \n") == "https://example.com/a"
    end

    test "drops the fragment and an empty query" do
      assert Links.normalize("https://example.com/a?#frag") == "https://example.com/a"
      assert Links.normalize("https://example.com/a?") == "https://example.com/a"
      assert Links.normalize("https://example.com/a#t=1") == "https://example.com/a"
    end

    test "removes tracking parameters and keeps the others in order" do
      assert Links.normalize(
               "https://www.youtube.com/watch?v=abc&utm_source=x&t=42&si=XyZ&feature=share&list=L1"
             ) == "https://www.youtube.com/watch?v=abc&t=42&list=L1"

      assert Links.normalize(
               "https://www.tiktok.com/@fisher/video/123?_r=1&_t=8abc&is_from_webapp=1&sender_device=pc&lang=en"
             ) == "https://www.tiktok.com/@fisher/video/123?lang=en"

      assert Links.normalize("https://www.instagram.com/reel/C1x/?igsh=abc&hl=en") ==
               "https://www.instagram.com/reel/C1x/?hl=en"

      assert Links.normalize("https://example.com/v?fbclid=1&gclid=2&UTM_MEDIUM=3&id=7") ==
               "https://example.com/v?id=7"

      assert Links.normalize("https://youtu.be/abc?si=1&share_source=copy") ==
               "https://youtu.be/abc"
    end

    test "only drops generic parameter names on the sites that use them for tracking" do
      assert Links.normalize("https://open.spotify.com/track/1?si=abc") ==
               "https://open.spotify.com/track/1?si=abc"

      assert Links.normalize("https://music.youtube.com/watch?v=1&si=abc") ==
               "https://music.youtube.com/watch?v=1"

      assert Links.normalize("https://x.com/a/status/1?s=46&t=abc") == "https://x.com/a/status/1"

      assert Links.normalize("https://example.com/a?s=46&t=abc") ==
               "https://example.com/a?s=46&t=abc"

      assert Links.normalize("https://example.com/a?feature=beta") ==
               "https://example.com/a?feature=beta"
    end

    test "drops the viewed carousel item of Instagram links, which show the same post" do
      assert Links.normalize("https://www.instagram.com/p/DdwalmrkTSK/?img_index=2") ==
               "https://www.instagram.com/p/DdwalmrkTSK/"

      assert Links.normalize("https://instagr.am/p/DdwalmrkTSK/?IMG_INDEX=3&igsh=x&hl=en") ==
               "https://instagr.am/p/DdwalmrkTSK/?hl=en"

      assert Links.normalize("https://example.com/gallery?img_index=2") ==
               "https://example.com/gallery?img_index=2"
    end

    test "drops the share tracking of Threads links" do
      assert Links.normalize("https://www.threads.com/@nasa/post/DeMqtuYgkaL?xmt=AQF0abc&slof=1") ==
               "https://www.threads.com/@nasa/post/DeMqtuYgkaL"

      assert Links.normalize("https://www.threads.net/@nasa/post/DeMqtuYgkaL?XMT=a&hl=en") ==
               "https://www.threads.net/@nasa/post/DeMqtuYgkaL?hl=en"

      assert Links.normalize("https://example.com/a?xmt=1&slof=1") ==
               "https://example.com/a?xmt=1&slof=1"
    end

    test "keeps valueless parameters and existing escapes" do
      assert Links.normalize("https://example.com/a%20b?flag&q=a%26b") ==
               "https://example.com/a%20b?flag&q=a%26b"
    end

    test "percent-encodes characters that are not allowed in URIs" do
      assert Links.normalize(~S(https://example.com/a|b{c}^"`\<d>)) ==
               "https://example.com/a%7Cb%7Bc%7D%5E%22%60%5C%3Cd%3E"

      assert Links.normalize("https://example.com/watch?list[0]=1&x=a|b#[y]") ==
               "https://example.com/watch?list%5B0%5D=1&x=a%7Cb"

      assert Links.normalize("http://[::1]:8080/[x]") == "http://[::1]:8080/%5Bx%5D"
    end

    test "converts internationalized hosts to Punycode" do
      assert Links.normalize("https://Пример.рф/видео?q=да") ==
               "https://xn--e1afmkfd.xn--p1ai/%D0%B2%D0%B8%D0%B4%D0%B5%D0%BE?q=%D0%B4%D0%B0"

      assert Links.normalize("bücher.de/x") == "https://xn--bcher-kva.de/x"

      assert Links.normalize("https://ann@bücher.de:8080/x") ==
               "https://ann@xn--bcher-kva.de:8080/x"

      assert Links.host("https://www.пример.рф/") == "xn--e1afmkfd.xn--p1ai"
    end

    test "returns nil for unparsable input" do
      assert Links.normalize(nil) == nil
      assert Links.normalize("") == nil
      assert Links.normalize("   ") == nil
      assert Links.normalize("https://") == nil
      assert Links.normalize("https://example.com:port/") == nil
      assert Links.normalize("http://[::1/x") == nil
    end
  end

  describe "host/1" do
    test "returns the lowercased host without www." do
      assert Links.host("https://www.YouTube.com/watch?v=1") == "youtube.com"
      assert Links.host("https://m.youtube.com/watch?v=1") == "m.youtube.com"
      assert Links.host("youtu.be/abc") == "youtu.be"
    end

    test "returns nil when there is no host" do
      assert Links.host(nil) == nil
      assert Links.host("") == nil
      assert Links.host("https://") == nil
    end
  end
end
