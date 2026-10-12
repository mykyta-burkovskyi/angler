defmodule Angler.Media.ThreadsNetworkTest do
  # Live Threads posts through Angler.Media.Threads (real Threads and Instagram's CDN).
  # Excluded by default; run with:
  #
  #   mix test test/angler/media/threads_network_test.exs --include network
  #
  # Not async: talks to Threads and the CDN without the Req.Test stubs of the test
  # configuration.
  use ExUnit.Case, async: false

  alias Angler.Media
  alias Angler.Media.{Download, Error, Instagram, Threads}
  alias Angler.Media.Instagram.{Music, Post}

  @moduletag :network
  @moduletag :tmp_dir
  @moduletag timeout: :timer.minutes(5)

  setup do
    for module <- [Threads, Instagram] do
      original = Application.get_env(:angler, module)
      on_exit(fn -> Application.put_env(:angler, module, original) end)
      Application.put_env(:angler, module, [])
    end

    :ok
  end

  defp items(%Post{items: items}), do: Enum.map(items, & &1.type)

  test "reads a photo post (@nasa)" do
    assert {:album, %Post{site: "Threads", username: "nasa"} = post} =
             Threads.route("https://www.threads.com/@nasa/post/DeUWxGgjHSK")

    assert items(post) == [:photo]
    assert post.webpage_url == "https://www.threads.com/@nasa/post/DeUWxGgjHSK"
    assert is_binary(post.caption)
  end

  test "reads a carousel of photos and videos, also by its /t/ and threads.net links" do
    for url <- [
          "https://www.threads.com/@zuck/post/Ddt7cL5EfUG",
          "https://www.threads.com/t/Ddt7cL5EfUG",
          "https://www.threads.net/@zuck/post/Ddt7cL5EfUG"
        ] do
      assert {:album, %Post{} = post} = Threads.route(url)
      assert :photo in items(post) and :video in items(post)
    end
  end

  test "reads a photo post with music" do
    assert {:slideshow, %Post{} = post, %Music{} = music} =
             Threads.route("https://www.threads.com/@nasa/post/DePPcDfkc_a")

    assert items(post) == [:photo]
    assert Instagram.Cdn.cdn?(music.url)
    assert music.clip_duration == 30.0
  end

  test "downloads a video post from the CDN", %{tmp_dir: dir} do
    assert {:ok, %Download{kind: :video, extractor: "Threads"} = download} =
             Media.download("https://www.threads.com/@nasa/post/DeMqtuYgkaL", dir,
               max_source_bytes: 200_000_000
             )

    assert download.size > 1_000_000
    assert <<_size::32, "ftyp", _rest::binary>> = File.read!(download.path)
  end

  test "fails text posts, missing posts and expired share links" do
    assert {:error, %Error{kind: :unsupported}} =
             Threads.route("https://www.threads.com/@zuck/post/Dd1MqfcG0aH")

    assert {:error, %Error{kind: :unavailable}} =
             Threads.route("https://www.threads.com/@nasa/post/DeUWxGgjHSJ")

    assert {:error, %Error{kind: :unavailable}} =
             Threads.route("https://www.threads.com/share/AAAAAAAAAA/")
  end
end
