defmodule Angler.Media.Threads.VideoTest do
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures, only: [stub_instagram: 1, bytes: 3]

  alias Angler.Media.{Download, Error}
  alias Angler.Media.Instagram.Post
  alias Angler.Media.Threads.Video

  @moduletag :tmp_dir
  @moduletag :capture_log

  @cdn "https://scontent-iev1-1.cdninstagram.com/o1/v/t16/f2/m69"

  defp post(urls, opts \\ []) do
    %Post{
      code: "DeMqtuYgkaL",
      site: "Threads",
      caption: Keyword.get(opts, :caption, "Artemis II data"),
      username: "nasa",
      webpage_url: "https://www.threads.com/@nasa/post/DeMqtuYgkaL",
      items: [
        %{
          type: :video,
          urls: urls,
          width: 1080,
          height: 1920,
          duration: Keyword.get(opts, :duration, 89.4)
        }
      ]
    }
  end

  test "downloads the video from the CDN into source.mp4", %{tmp_dir: dir} do
    stub_instagram(&bytes(&1, "video bytes", "video/mp4"))
    test = self()

    assert {:ok, %Download{} = download} =
             Video.download(post(["#{@cdn}/a.mp4?oh=sig"]), dir,
               max_source_bytes: 1_000,
               on_progress: &send(test, {:progress, &1})
             )

    assert download == %Download{
             kind: :video,
             path: Path.join(dir, "source.mp4"),
             size: 11,
             duration: 89.4,
             title: "Artemis II data",
             extractor: "Threads",
             webpage_url: "https://www.threads.com/@nasa/post/DeMqtuYgkaL"
           }

    assert File.read!(download.path) == "video bytes"
    assert_received {:instagram_request, "GET", "scontent-iev1-1.cdninstagram.com/o1/" <> _, conn}
    assert Plug.Conn.get_req_header(conn, "cookie") == []
    assert_received {:progress, %{detail: "Downloading"}}
  end

  test "tries the next URL when the CDN refuses one", %{tmp_dir: dir} do
    stub_instagram(fn conn ->
      if conn.request_path =~ "a.mp4",
        do: Plug.Conn.send_resp(conn, 403, ""),
        else: bytes(conn, "b", "video/mp4")
    end)

    assert {:ok, %Download{size: 1}} =
             Video.download(post(["#{@cdn}/a.mp4", "#{@cdn}/b.mp4"]), dir, [])
  end

  test "a refused video is retried, and unavailable on the final attempt", %{tmp_dir: dir} do
    stub_instagram(&Plug.Conn.send_resp(&1, 403, ""))
    post = post(["#{@cdn}/a.mp4"])

    assert {:error, %Error{kind: :transient, message: message}} =
             Video.download(post, dir, final_attempt: false)

    assert message == "Could not download the Threads video (HTTP 403)"

    assert Video.download(post, dir, final_attempt: true) ==
             {:error, Error.new(:unavailable, "Could not download the Threads video (HTTP 403)")}

    refute File.exists?(Path.join(dir, "source.mp4"))
  end

  test "never downloads from another host", %{tmp_dir: dir} do
    stub_instagram(fn _conn -> flunk("unexpected request") end)

    assert {:error, %Error{kind: :unavailable, message: message}} =
             Video.download(post(["https://evil.test/a.mp4"]), dir, [])

    assert message =~ "evil.test"
  end

  test "refuses a video larger than the source limit", %{tmp_dir: dir} do
    stub_instagram(&bytes(&1, String.duplicate("x", 2_000), "video/mp4"))

    assert Video.download(post(["#{@cdn}/a.mp4"]), dir, max_source_bytes: 1_000) ==
             {:error, Error.new(:too_large, "Source file is larger than 0.0 MB")}

    refute File.exists?(Path.join(dir, "source.mp4"))
  end

  test "refuses a video longer than the limit before downloading it", %{tmp_dir: dir} do
    stub_instagram(fn _conn -> flunk("unexpected request") end)

    assert {:error, %Error{kind: :too_large}} =
             Video.download(post(["#{@cdn}/a.mp4"], duration: 120.0), dir, max_duration: 60)

    # Within a second of the limit is fine, and so is an unknown duration.
    stub_instagram(&bytes(&1, "v", "video/mp4"))

    assert {:ok, _download} =
             Video.download(post(["#{@cdn}/a.mp4"], duration: 60.9), dir, max_duration: 60)

    assert {:ok, %Download{duration: nil}} =
             Video.download(post(["#{@cdn}/a.mp4"], duration: nil), dir, max_duration: 60)
  end
end
