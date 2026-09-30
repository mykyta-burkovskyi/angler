defmodule Angler.Media.FetchTest do
  use ExUnit.Case, async: true

  import Angler.TikTokFixtures

  alias Angler.Media.{Error, Fetch, Instagram}

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

  describe "to_file/3 with a request builder" do
    defp stub_instagram(handler) do
      test = self()

      Req.Test.stub(Instagram, fn conn ->
        send(test, {:instagram_request, conn.host <> conn.request_path, conn})
        handler.(conn)
      end)
    end

    defp instagram(options), do: Instagram.request(Keyword.put(options, :redirect, false))

    test "builds the request with it", %{tmp_dir: dir} do
      stub_instagram(&bytes(&1, "the photo"))
      path = Path.join(dir, "01.jpg")

      assert Fetch.to_file("https://scontent.cdninstagram.test/a.jpg", path,
               max_bytes: 100,
               request: &instagram/1
             ) == {:ok, 9}

      assert File.read!(path) == "the photo"
      assert_received {:instagram_request, "scontent.cdninstagram.test/a.jpg", conn}
      assert Plug.Conn.get_req_header(conn, "cookie") == []
    end

    test "does not follow redirects when the builder says so", %{tmp_dir: dir} do
      stub_instagram(fn conn ->
        if conn.request_path == "/a.jpg",
          do: redirect(conn, "https://elsewhere.test/b.jpg"),
          else: bytes(conn, "moved")
      end)

      path = Path.join(dir, "01.jpg")

      assert Fetch.to_file("https://scontent.cdninstagram.test/a.jpg", path,
               max_bytes: 100,
               request: &instagram/1
             ) == {:error, {:http, 302}}

      refute_received {:instagram_request, "elsewhere.test/b.jpg", _conn}
      assert File.read!(path) == ""
    end
  end

  describe "to_file/3 with a shared budget" do
    defp used({counter, _limit}), do: :atomics.get(counter, 1)

    test "counts the bytes of every fetch", %{tmp_dir: dir} do
      stub_tiktok(&bytes(&1, :binary.copy("x", 40)))
      budget = Fetch.budget(100)
      opts = [max_bytes: 1_000, budget: budget]

      assert Fetch.to_file("https://p16.tiktokcdn.test/1", Path.join(dir, "1"), opts) == {:ok, 40}
      assert Fetch.to_file("https://p16.tiktokcdn.test/2", Path.join(dir, "2"), opts) == {:ok, 40}
      assert used(budget) == 80

      assert Fetch.to_file("https://p16.tiktokcdn.test/3", Path.join(dir, "3"), opts) ==
               {:error, :over_budget}

      # The refused file gives its bytes back.
      assert used(budget) == 80
    end

    test "is checked as the bytes arrive, before the file's own limit", %{tmp_dir: dir} do
      stub_tiktok(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(1..10, conn, fn _n, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, :binary.copy("x", 10))
          conn
        end)
      end)

      budget = Fetch.budget(55)

      assert Fetch.to_file("https://p16.tiktokcdn.test/1", Path.join(dir, "1"),
               max_bytes: 55,
               budget: budget
             ) == {:error, :over_budget}

      assert used(budget) == 0
    end

    test "is shared by parallel fetches", %{tmp_dir: dir} do
      stub_tiktok(&bytes(&1, :binary.copy("x", 30)))
      budget = Fetch.budget(100)

      results =
        1..6
        |> Task.async_stream(fn n ->
          Fetch.to_file("https://p16.tiktokcdn.test/#{n}", Path.join(dir, "#{n}"),
            max_bytes: 1_000,
            budget: budget
          )
        end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == {:ok, 30})) == 3
      assert Enum.count(results, &(&1 == {:error, :over_budget})) == 3
      assert used(budget) == 90
    end

    test "gets back the bytes of failed downloads", %{tmp_dir: dir} do
      budget = Fetch.budget(1_000)

      stub_tiktok(&bytes(&1, :binary.copy("x", 101)))

      assert Fetch.to_file("https://p16.tiktokcdn.test/1", Path.join(dir, "1"),
               max_bytes: 100,
               budget: budget
             ) == {:error, :too_large}

      stub_tiktok(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "first")
        Process.sleep(20)
        {:ok, conn} = Plug.Conn.chunk(conn, "second")
        conn
      end)

      assert Fetch.to_file("https://p16.tiktokcdn.test/2", Path.join(dir, "2"),
               max_bytes: 100,
               timeout: 10,
               budget: budget
             ) == {:error, :timeout}

      assert used(budget) == 0
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

    test "counts a URL on a host that is not allowed as a refusal" do
      reason = {:host_not_allowed, "evil.test"}
      assert Fetch.refusal?(reason)
      refute Fetch.transient?(reason)

      assert Fetch.failure([reason], "Could not download item 2", false) ==
               {:error,
                Error.new(
                  :transient,
                  "Could not download item 2 (evil.test is not an allowed host)"
                )}

      assert Fetch.failure([reason], "x", true) == {:skip, "evil.test is not an allowed host"}
      assert Fetch.describe({:host_not_allowed, nil}) == "not a web address"
      assert Fetch.describe(:over_budget) == "over the size limit"
    end
  end

  test "errors for the budget and disk failures" do
    assert Fetch.over_budget(20_000_000) ==
             Error.new(:too_large, "This slideshow is larger than 20 MB")

    assert Fetch.over_budget(1_000_000_000, "Instagram post") ==
             Error.new(:too_large, "This Instagram post is larger than 1000 MB")

    assert %Error{kind: :internal, message: "could not write the file: no space left on device"} =
             Fetch.write_error({:write, :enospc})
  end
end
