defmodule Angler.Telegram.MultipartTest do
  use ExUnit.Case, async: true

  alias Angler.Telegram.Multipart

  test "value/1 turns values into multipart text fields" do
    assert Multipart.value("🎣 text") == "🎣 text"
    assert Multipart.value(-100_123) == "-100123"
    assert Multipart.value(true) == "true"
    assert Multipart.value(false) == "false"
    assert Jason.decode!(Multipart.value(%{message_id: 7})) == %{"message_id" => 7}

    assert Jason.decode!(Multipart.value([%{type: "photo", media: "attach://file0"}])) ==
             [%{"type" => "photo", "media" => "attach://file0"}]

    assert Multipart.text_fields(chat_id: 5, supports_streaming: true) ==
             [chat_id: "5", supports_streaming: "true"]
  end

  test "file_uri/1 encodes an absolute path" do
    assert Multipart.file_uri("/data/entry dir/video.mp4") == "file:///data/entry%20dir/video.mp4"
    assert Multipart.file_uri("video.mp4") == "file://" <> Path.expand("video.mp4")
  end

  test "file_part/2 streams the file in chunks, typed by the file name" do
    assert {%File.Stream{path: "/data/a.bin", line_or_bytes: 65_536},
            filename: "photo0.png", content_type: "image/png"} =
             Multipart.file_part("/data/a.bin", "photo0.png")
  end

  test "content_type/1 knows photos and MP4 videos" do
    assert Multipart.content_type("photo.jpg") == "image/jpeg"
    assert Multipart.content_type("PHOTO.JPEG") == "image/jpeg"
    assert Multipart.content_type("photo.png") == "image/png"
    assert Multipart.content_type("photo.webp") == "image/webp"
    assert Multipart.content_type("video.mp4") == "video/mp4"
    assert Multipart.content_type("photo.heic") == "application/octet-stream"
    assert Multipart.content_type("photo") == "application/octet-stream"
  end
end
