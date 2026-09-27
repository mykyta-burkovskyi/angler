defmodule Angler.Media.Slideshow.FetchTest do
  use ExUnit.Case, async: true

  import Angler.TikTokFixtures

  alias Angler.Media.Error
  alias Angler.Media.Slideshow.{Fetch, Sound}

  @moduletag :tmp_dir

  describe "to_file/3" do
    test "streams the body to disk, following CDN redirects", %{tmp_dir: dir} do
      path = Path.join(dir, "01.jpg")

      stub_tiktok(fn conn ->
        case conn.host do
          "p16.tiktokcdn.test" -> redirect(conn, "https://p19.tiktokcdn.test/moved.jpeg")
          "p19.tiktokcdn.test" -> bytes(conn, "the image")
        end
      end)

      assert Fetch.to_file("https://p16.tiktokcdn.test/a.jpeg", path, max_bytes: 100) == {:ok, 9}
      assert File.read!(path) == "the image"
    end

    test "stops at the size limit", %{tmp_dir: dir} do
      stub_tiktok(&bytes(&1, :binary.copy("x", 101)))

      assert Fetch.to_file("https://p16.tiktokcdn.test/a", Path.join(dir, "a"), max_bytes: 100) ==
               {:error, :too_large}

      stub_tiktok(&bytes(&1, :binary.copy("x", 100)))

      assert Fetch.to_file("https://p16.tiktokcdn.test/a", Path.join(dir, "a"), max_bytes: 100) ==
               {:ok, 100}
    end

    test "reports HTTP errors, empty bodies and network errors", %{tmp_dir: dir} do
      path = Path.join(dir, "a")

      stub_tiktok(&Plug.Conn.send_resp(&1, 403, "expired signature"))

      assert Fetch.to_file("https://p16.tiktokcdn.test/a", path, max_bytes: 100) ==
               {:error, {:http, 403}}

      # Error bodies are not written.
      assert File.read!(path) == ""

      stub_tiktok(&bytes(&1, ""))

      assert Fetch.to_file("https://p16.tiktokcdn.test/a", path, max_bytes: 100) ==
               {:error, :empty}

      stub_tiktok(&Req.Test.transport_error(&1, :econnreset))

      assert {:error, {:network, _message}} =
               Fetch.to_file("https://p16.tiktokcdn.test/a", path, max_bytes: 100)
    end

    test "gives up after the overall timeout", %{tmp_dir: dir} do
      stub_tiktok(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "first")
        Process.sleep(20)
        {:ok, conn} = Plug.Conn.chunk(conn, "second")
        conn
      end)

      assert Fetch.to_file("https://p16.tiktokcdn.test/a", Path.join(dir, "a"),
               max_bytes: 100,
               timeout: 10
             ) == {:error, :timeout}
    end

    test "reports files it can't write", %{tmp_dir: dir} do
      stub_tiktok(&bytes(&1, "data"))
      missing = Path.join([dir, "missing", "a"])

      assert Fetch.to_file("https://p16.tiktokcdn.test/a", missing, max_bytes: 100) ==
               {:error, {:write, :enoent}}
    end
  end

  describe "failure/3" do
    test "retries transient failures later and, on the final attempt, skips the others" do
      assert Fetch.failure([{:http, 404}, {:http, 403}], "Could not download image 2", true) ==
               {:skip, "HTTP 403, HTTP 404"}

      assert Fetch.failure([:too_large, :empty], "x", true) ==
               {:skip, "empty response, file too large"}

      for transient <- [{:http, 503}, {:http, 429}, {:http, 408}, {:network, "closed"}, :timeout],
          final? <- [true, false] do
        assert {:error, %Error{kind: :transient, message: "Could not download image 2 (" <> _}} =
                 Fetch.failure([{:http, 404}, transient], "Could not download image 2", final?)
      end
    end

    test "retries CDN refusals while more attempts follow" do
      # Signed URLs: the next attempt loads the post again and gets fresh ones.
      for refusal <- [{:http, 403}, {:http, 404}, {:http, 410}, :empty] do
        assert Fetch.failure([refusal], "Could not download the slideshow sound", false) ==
                 {:error,
                  Error.new(
                    :transient,
                    "Could not download the slideshow sound (#{Fetch.describe(refusal)})"
                  )}
      end

      # A file over the size limit stays too large.
      assert Fetch.failure([:too_large], "x", false) == {:skip, "file too large"}

      assert Enum.filter([{:http, 403}, :empty, :too_large, :timeout], &Fetch.refusal?/1) ==
               [{:http, 403}, :empty]
    end
  end

  test "errors for the budget and disk failures" do
    assert Fetch.over_budget(20_000_000) ==
             Error.new(:too_large, "This slideshow is larger than 20 MB")

    assert %Error{kind: :internal, message: "could not write the file: no space left on device"} =
             Fetch.write_error({:write, :enospc})
  end

  test "Sound.extension/1 names the sound after ffprobe's format" do
    assert Sound.extension("mp3") == ".mp3"
    assert Sound.extension("mov,mp4,m4a,3gp,3g2,mj2") == ".m4a"
    assert Sound.extension("ogg") == ""
    assert Sound.extension(nil) == ""
  end
end
