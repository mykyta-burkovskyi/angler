defmodule Angler.Media.EgressProxyTest do
  use ExUnit.Case, async: true

  alias Angler.Media.EgressProxy

  # Lets the test servers on 127.0.0.1 through under the name "video.test".
  defp check_test_host("video.test"), do: {:ok, [{127, 0, 0, 1}]}
  defp check_test_host(host), do: Angler.Media.Egress.check(host)

  defp start_proxy(check \\ &check_test_host/1) do
    {:ok, proxy} = EgressProxy.start(check: check)
    on_exit(fn -> EgressProxy.stop(proxy) end)
    %URI{port: port} = URI.parse(proxy.url)
    {proxy, port}
  end

  # A server on 127.0.0.1 that sends the head of the first request it gets to the
  # test, then answers with `response` (or echoes everything it receives when
  # `response` is :echo).
  defp start_server(response) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listen)
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)

      case response do
        :echo ->
          send(test, :connected)
          echo(socket)

        response ->
          send(test, {:request, read_head(socket, "")})
          :ok = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
      end
    end)

    port
  end

  defp echo(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        :gen_tcp.send(socket, data)
        echo(socket)

      {:error, _reason} ->
        :ok
    end
  end

  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      read_head(socket, buffer <> data)
    end
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    socket
  end

  # Sends `request` and returns everything the proxy sends until it closes.
  defp exchange(port, request) do
    socket = connect(port)
    :ok = :gen_tcp.send(socket, request)
    read_all(socket, "")
  end

  defp read_all(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, buffer <> data)
      {:error, :closed} -> buffer
    end
  end

  test "forwards plain HTTP requests to one host per connection" do
    {proxy, port} = start_proxy()
    server = start_server("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nKeep-Alive: 5\r\n\r\nhello")

    response =
      exchange(
        port,
        "GET http://video.test:#{server}/clip.mp4?a=1 HTTP/1.1\r\n" <>
          "Host: video.test:#{server}\r\nProxy-Connection: keep-alive\r\n" <>
          "Proxy-Authorization: Basic eDp5\r\nRange: bytes=0-\r\n\r\n"
      )

    assert_receive {:request, request}

    assert request ==
             "GET /clip.mp4?a=1 HTTP/1.1\r\nHost: video.test:#{server}\r\n" <>
               "Range: bytes=0-\r\nConnection: close\r\n\r\n"

    assert response == "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
    assert EgressProxy.stop(proxy) == []
  end

  test "tunnels CONNECT requests" do
    {proxy, port} = start_proxy()
    server = start_server(:echo)
    socket = connect(port)

    :ok = :gen_tcp.send(socket, "CONNECT video.test:#{server} HTTP/1.1\r\n\r\n")
    assert {:ok, "HTTP/1.1 200 Connection established\r\n\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
    assert_receive :connected

    :ok = :gen_tcp.send(socket, "hello through the tunnel")
    assert {:ok, "hello through the tunnel"} = :gen_tcp.recv(socket, 0, 5_000)

    assert EgressProxy.stop(proxy) == []
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
  end

  test "refuses private addresses and names that resolve to them" do
    {proxy, port} = start_proxy(&Angler.Media.Egress.check/1)
    server = start_server("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")

    for request <- [
          "GET http://127.0.0.1:#{server}/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
          "CONNECT localhost:#{server} HTTP/1.1\r\n\r\n",
          "GET http://[::1]:#{server}/ HTTP/1.1\r\n\r\n",
          "CONNECT 169.254.169.254:80 HTTP/1.1\r\n\r\n"
        ] do
      assert "HTTP/1.1 403 Forbidden\r\n" <> _ = exchange(port, request)
    end

    refute_receive {:request, _request}, 100
    assert EgressProxy.stop(proxy) == ["127.0.0.1", "localhost", "::1", "169.254.169.254"]
  end

  test "refuses requests it cannot vet" do
    {_proxy, port} = start_proxy()

    for request <- [
          "GET /relative HTTP/1.1\r\nHost: video.test\r\n\r\n",
          "GET https://video.test/ HTTP/1.1\r\n\r\n",
          "CONNECT video.test HTTP/1.1\r\n\r\n",
          "NONSENSE\r\n\r\n"
        ] do
      assert "HTTP/1.1 400 Bad Request\r\n" <> _ = exchange(port, request)
    end

    assert "HTTP/1.1 502 Bad Gateway\r\n" <> _ =
             exchange(port, "CONNECT no-such-host.invalid:443 HTTP/1.1\r\n\r\n")
  end

  test "stops when the process that started it exits" do
    task = Task.async(fn -> EgressProxy.start() end)
    {:ok, %EgressProxy{pid: pid}} = Task.await(task)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
