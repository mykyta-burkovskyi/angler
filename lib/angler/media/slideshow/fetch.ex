defmodule Angler.Media.Slideshow.Fetch do
  @moduledoc """
  Streams a file from TikTok's CDN to disk with a size limit and an overall
  deadline (Req's receive timeout only bounds the wait for each chunk). Image and
  sound URLs need no user agent, referer or cookies.
  """
  alias Angler.Media
  alias Angler.Media.{Error, TikTok}

  @default_timeout :timer.minutes(2)

  @type reason ::
          :too_large
          | :timeout
          | :empty
          | {:http, pos_integer()}
          | {:network, String.t()}
          | {:write, File.posix()}

  @doc """
  Downloads `url` into `path` (replacing it) and returns the number of bytes.

  Options: `:max_bytes` (required) and `:timeout` (milliseconds for the whole
  download, default 2 minutes). On errors `path` may hold a partial file.
  """
  @spec to_file(String.t(), Path.t(), keyword()) :: {:ok, pos_integer()} | {:error, reason()}
  def to_file(url, path, opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @default_timeout)

    case File.open(path, [:write, :binary, :raw], &request(&1, url, max_bytes, deadline)) do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  defp request(file, url, max_bytes, deadline) do
    into = fn {:data, data}, {request, response} ->
      {action, response} = write(file, data, response, max_bytes, deadline)
      {action, {request, response}}
    end

    request = TikTok.request(url: url, into: into, compressed: false, redirect: true)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200} = response} ->
        case {Req.Response.get_private(response, :error), bytes(response)} do
          {nil, 0} -> {:error, :empty}
          {nil, bytes} -> {:ok, bytes}
          {error, _bytes} -> {:error, error}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:network, Exception.message(exception)}}
    end
  end

  # Only the body of a successful response is written; bodies of redirects and
  # errors are dropped.
  defp write(_file, _data, %Req.Response{status: status} = response, _max, _deadline)
       when status != 200,
       do: {:cont, response}

  defp write(file, data, response, max_bytes, deadline) do
    bytes = bytes(response) + byte_size(data)

    cond do
      bytes > max_bytes ->
        {:halt, Req.Response.put_private(response, :error, :too_large)}

      System.monotonic_time(:millisecond) > deadline ->
        {:halt, Req.Response.put_private(response, :error, :timeout)}

      true ->
        case :file.write(file, data) do
          :ok ->
            {:cont, Req.Response.put_private(response, :bytes, bytes)}

          {:error, reason} ->
            {:halt, Req.Response.put_private(response, :error, {:write, reason})}
        end
    end
  end

  defp bytes(response), do: Req.Response.get_private(response, :bytes, 0)

  @doc """
  Whether a failed download is worth retrying later (network trouble, timeouts,
  server errors, rate limits) rather than a problem with the file itself.
  """
  @spec transient?(reason()) :: boolean()
  def transient?({:http, status}), do: status in [408, 429] or status >= 500
  def transient?({:network, _message}), do: true
  def transient?(:timeout), do: true
  def transient?(_reason), do: false

  @doc "A short description of a failure for messages and logs."
  @spec describe(reason()) :: String.t()
  def describe(:too_large), do: "file too large"
  def describe(:timeout), do: "took too long"
  def describe(:empty), do: "empty response"
  def describe({:http, status}), do: "HTTP #{status}"
  def describe({:network, message}), do: message
  def describe({:write, reason}), do: "could not write the file: #{:file.format_error(reason)}"

  @doc """
  Whether the CDN refused a file (an HTTP error or an empty body). With freshly
  signed URLs that is usually a passing refusal (a rate limit, a bad CDN node).
  """
  @spec refusal?(reason()) :: boolean()
  def refusal?({:http, _status}), do: true
  def refusal?(:empty), do: true
  def refusal?(_reason), do: false

  @doc """
  What to do about a file every URL failed for (`reasons`, latest first).

  The job is retried later (a `:transient` error with `message`) when a failure was
  transient, or when the CDN refused the file and `final_attempt?` is false: the
  next attempt loads the post again and gets freshly signed URLs, and a slideshow
  missing a file would otherwise be delivered (and re-sent for the same link)
  without it. Otherwise the file is left out (`{:skip, description}`).
  """
  @spec failure([reason()], String.t(), boolean()) :: {:error, Error.t()} | {:skip, String.t()}
  def failure(reasons, message, final_attempt?) do
    described = reasons |> Enum.reverse() |> Enum.map_join(", ", &describe/1)

    retry? =
      Enum.any?(reasons, &transient?/1) or
        (not final_attempt? and Enum.any?(reasons, &refusal?/1))

    if retry?,
      do: {:error, Error.new(:transient, "#{message} (#{described})")},
      else: {:skip, described}
  end

  @doc "The error for a slideshow whose files exceed `budget` bytes (the source limit)."
  @spec over_budget(non_neg_integer()) :: Error.t()
  def over_budget(budget),
    do: Error.new(:too_large, "This slideshow is larger than #{Media.format_mb(budget)}")

  @doc "The error for a failure writing to disk."
  @spec write_error({:write, File.posix()}) :: Error.t()
  def write_error({:write, _posix} = reason), do: Error.new(:internal, describe(reason))
end
