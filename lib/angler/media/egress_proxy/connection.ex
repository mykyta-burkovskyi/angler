defmodule Angler.Media.EgressProxy.Connection do
  @moduledoc """
  One client connection of `Angler.Media.EgressProxy`: reads the request head, vets
  and connects to the target, then relays bytes both ways until either side closes,
  the proxy stops or the connection is idle for too long.

  Plain HTTP requests are rewritten to origin form with `Connection: close`, and so is
  the head of the response, so the client opens a new connection (and the proxy
  checks the host again) for its next request.
  """

  @head_timeout :timer.seconds(30)
  @connect_timeout :timer.seconds(15)
  @send_timeout :timer.seconds(30)
  @idle_timeout :timer.minutes(2)
  @max_head_bytes 65_536
  @hop_by_hop ~w(connection proxy-connection keep-alive proxy-authorization)
  @reasons %{
    400 => "Bad Request",
    403 => "Forbidden",
    408 => "Request Timeout",
    431 => "Request Header Fields Too Large",
    502 => "Bad Gateway"
  }

  @doc """
  Serves the socket that arrives as `{:socket, socket}` (the acceptor hands over the
  socket first), vetting hosts with `check`.
  """
  @spec serve(pid(), (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})) :: :ok
  def serve(proxy, check) do
    monitor = Process.monitor(proxy)

    receive do
      {:socket, client} ->
        :inet.setopts(client,
          nodelay: true,
          send_timeout: @send_timeout,
          send_timeout_close: true
        )

        handle(client, %{proxy: proxy, monitor: monitor, check: check})
        :gen_tcp.close(client)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok
    end

    :ok
  end

  defp handle(client, ctx) do
    with {:ok, head, rest} <- read_head(client, ctx.monitor),
         {:ok, request} <- parse(head),
         {:ok, upstream} <- open(request, ctx) do
      case request do
        %{type: :connect} ->
          :gen_tcp.send(client, "HTTP/1.1 200 Connection established\r\n\r\n")
          if rest != "", do: :gen_tcp.send(upstream, rest)
          relay(client, upstream, nil, ctx.monitor)

        %{type: :forward, head: forward_head} ->
          :gen_tcp.send(upstream, [forward_head, rest])
          relay(client, upstream, "", ctx.monitor)
      end

      :gen_tcp.close(upstream)
    else
      {:reply, status, message} -> reply(client, status, message)
      :closed -> :ok
    end
  end

  ## Request

  defp read_head(socket, monitor, buffer \\ "") do
    :inet.setopts(socket, active: :once)

    receive do
      {:tcp, ^socket, data} ->
        buffer = buffer <> data

        case :binary.split(buffer, "\r\n\r\n") do
          [head, rest] -> {:ok, head, rest}
          [_] when byte_size(buffer) > @max_head_bytes -> {:reply, 431, "Request head too large"}
          [_] -> read_head(socket, monitor, buffer)
        end

      {:tcp_closed, ^socket} ->
        :closed

      {:tcp_error, ^socket, _reason} ->
        :closed

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :closed
    after
      @head_timeout -> {:reply, 408, "No request received"}
    end
  end

  defp parse(head) do
    [request_line | headers] = String.split(head, "\r\n")

    with [method, target, "HTTP/1." <> _ = version] <- String.split(request_line, " "),
         {:ok, request} <- parse_target(method, target) do
      case request do
        %{type: :connect} ->
          {:ok, request}

        %{type: :forward, origin: origin} ->
          request_line = Enum.join([method, origin, version], " ")
          {:ok, Map.put(request, :head, rewrite_head(request_line, headers))}
      end
    else
      _other ->
        {:reply, 400, "Only CONNECT and plain HTTP requests in absolute form are supported"}
    end
  end

  defp parse_target("CONNECT", authority) do
    with {:ok, host, port} <- parse_authority(authority, nil),
         do: {:ok, %{type: :connect, host: host, port: port}}
  end

  defp parse_target(_method, <<scheme::binary-size(7), rest::binary>>) do
    {authority, origin} =
      case :binary.match(rest, ["/", "?", "#"]) do
        {at, _length} -> {binary_part(rest, 0, at), binary_part(rest, at, byte_size(rest) - at)}
        :nomatch -> {rest, ""}
      end

    origin =
      case origin |> String.split("#", parts: 2) |> hd() do
        "/" <> _ = path -> path
        query -> "/" <> query
      end

    with "http://" <- String.downcase(scheme),
         {:ok, host, port} <- parse_authority(authority, 80),
         do: {:ok, %{type: :forward, host: host, port: port, origin: origin}}
  end

  defp parse_target(_method, _target), do: :error

  defp parse_authority(authority, default_port) do
    case URI.parse("//" <> authority) do
      %URI{host: host, port: port} when is_binary(host) and host != "" ->
        port = port || default_port
        if is_integer(port) and port in 1..65_535, do: {:ok, host, port}, else: :error

      _uri ->
        :error
    end
  end

  # Drops hop-by-hop headers and asks for the connection to be closed afterwards.
  defp rewrite_head(first_line, headers) do
    kept = Enum.reject(headers, &hop_by_hop?/1)
    Enum.join([first_line | kept] ++ ["Connection: close", "", ""], "\r\n")
  end

  defp hop_by_hop?(header) do
    name = header |> String.split(":", parts: 2) |> hd() |> String.trim() |> String.downcase()
    name in @hop_by_hop
  end

  ## Upstream

  defp open(%{host: host, port: port}, ctx) do
    case ctx.check.(host) do
      {:ok, addresses} ->
        case connect(addresses, port) do
          {:ok, socket} -> {:ok, socket}
          :error -> {:reply, 502, "Could not connect to #{host}"}
        end

      {:error, :blocked} ->
        send(ctx.proxy, {:blocked, host})
        {:reply, 403, "Downloads may not reach private network addresses (#{host})"}

      {:error, _reason} ->
        {:reply, 502, "Could not resolve #{host}"}
    end
  end

  # IPv4 first: containers often have no IPv6 route.
  defp connect(addresses, port) do
    addresses
    |> Enum.sort_by(&tuple_size/1)
    |> Enum.find_value(:error, fn address ->
      family = if tuple_size(address) == 8, do: [:inet6], else: []

      options =
        [:binary, active: false, nodelay: true, send_timeout: @send_timeout] ++
          [send_timeout_close: true] ++ family

      case :gen_tcp.connect(address, port, options, @connect_timeout) do
        {:ok, socket} -> {:ok, socket}
        {:error, _reason} -> nil
      end
    end)
  end

  ## Relay

  # `pending` buffers the head of a plain HTTP response until it is complete, so it
  # can be rewritten; nil once it was passed on (and always for tunnels).
  defp relay(client, upstream, pending, monitor) do
    :inet.setopts(client, active: :once)
    :inet.setopts(upstream, active: :once)
    loop(client, upstream, pending, monitor)
  end

  defp loop(client, upstream, pending, monitor) do
    receive do
      {:tcp, ^client, data} ->
        continue(:gen_tcp.send(upstream, data), client, client, upstream, pending, monitor)

      {:tcp, ^upstream, data} when is_nil(pending) ->
        continue(:gen_tcp.send(client, data), upstream, client, upstream, nil, monitor)

      {:tcp, ^upstream, data} ->
        buffer = pending <> data

        case :binary.split(buffer, "\r\n\r\n") do
          [head, body] ->
            result = :gen_tcp.send(client, [response_head(head), body])
            continue(result, upstream, client, upstream, nil, monitor)

          [_] when byte_size(buffer) > @max_head_bytes ->
            :ok

          [_] ->
            continue(:ok, upstream, client, upstream, buffer, monitor)
        end

      {:tcp_closed, ^upstream} when is_binary(pending) ->
        :gen_tcp.send(client, pending)

      {:tcp_closed, _socket} ->
        :ok

      {:tcp_error, _socket, _reason} ->
        :ok

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok
    after
      @idle_timeout -> :ok
    end
  end

  defp continue(:ok, socket, client, upstream, pending, monitor) do
    :inet.setopts(socket, active: :once)
    loop(client, upstream, pending, monitor)
  end

  defp continue({:error, _reason}, _socket, _client, _upstream, _pending, _monitor), do: :ok

  defp response_head("HTTP/" <> _ = head) do
    [status_line | headers] = String.split(head, "\r\n")
    rewrite_head(status_line, headers)
  end

  defp response_head(head), do: head <> "\r\n\r\n"

  defp reply(client, status, message) do
    body = message <> "\n"

    :gen_tcp.send(client, [
      "HTTP/1.1 #{status} #{Map.fetch!(@reasons, status)}\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
      body
    ])
  end
end
