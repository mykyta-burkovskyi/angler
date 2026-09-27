defmodule Angler.Telegram.SentTrackerTest do
  # Real HTTP requests through the application's Finch pool to local sockets.
  use ExUnit.Case, async: true

  alias Angler.Telegram.SentTracker

  test "a request the server read completely but never answered was sent" do
    {listen, url} = listen()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        request = read_request(socket, "")
        # Like a local Bot API server closing a connection that stayed silent.
        :gen_tcp.close(socket)
        request
      end)

    assert {{:error, %Req.TransportError{reason: :closed}}, true} =
             SentTracker.run(fn -> post(url, json: %{video: "BAAC"}) end)

    assert Task.await(server) =~ ~s({"video":"BAAC"})
  end

  test "a multipart upload the server read completely was sent" do
    {listen, url} = listen()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        read_request(socket, "")
        :gen_tcp.close(socket)
      end)

    body = [video: {:binary.copy("\r\n\0", 100_000), filename: "video.mp4"}]

    assert {{:error, %Req.TransportError{reason: :closed}}, true} =
             SentTracker.run(fn -> post(url, form_multipart: body) end)

    Task.await(server)
  end

  test "a request that could not be sent was not" do
    {listen, url} = listen()
    :gen_tcp.close(listen)

    assert {{:error, %Req.TransportError{reason: :econnrefused}}, false} =
             SentTracker.run(fn -> post(url, json: %{}) end)
  end

  test "each run starts over, also when nested" do
    assert {:none, false} = SentTracker.run(fn -> :none end)

    assert {{:inner, false}, true} =
             SentTracker.run(fn ->
               :telemetry.execute([:finch, :recv, :start], %{}, %{})
               SentTracker.run(fn -> :inner end)
             end)
  end

  defp listen do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    {listen, "http://127.0.0.1:#{port}/bot123:TEST/sendVideo"}
  end

  defp post(url, body) do
    Req.post(url, [finch: [name: Angler.Finch], retry: false, receive_timeout: 5_000] ++ body)
  end

  # Reads the request line, headers and a content-length body.
  defp read_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, head)

        if byte_size(body) >= String.to_integer(length),
          do: acc,
          else: read_more(socket, acc)

      [_incomplete] ->
        read_more(socket, acc)
    end
  end

  defp read_more(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_request(socket, acc <> data)
  end
end
