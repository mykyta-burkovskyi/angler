defmodule Angler.Media.Fetch do
  @moduledoc """
  Streams a file from a CDN (TikTok slideshows, Instagram albums and songs) to
  disk with a size limit and an overall deadline (Req's receive timeout only
  bounds the wait for each chunk). Media URLs need no user agent, referer or
  cookies.

  Several fetches running at once can share a byte budget (the `:budget` option
  of `to_file/3`): it is counted as the bytes arrive, so parallel downloads can't
  jointly exceed it.
  """
  alias Angler.Media
  alias Angler.Media.{Error, TikTok}

  @default_timeout :timer.minutes(2)

  @type reason ::
          :too_large
          | :over_budget
          | :timeout
          | :empty
          | {:http, pos_integer()}
          | {:network, String.t()}
          | {:host_not_allowed, String.t() | nil}
          | {:write, File.posix()}

  @typedoc """
  A byte budget shared by several fetches: an `:atomics` array whose first slot
  counts the bytes written so far, and the limit.
  """
  @type budget :: {:atomics.atomics_ref(), non_neg_integer()}

  @doc """
  Downloads `url` into `path` (replacing it) and returns the number of bytes.

  Options:
    * `:max_bytes` (required) - `{:error, :too_large}` beyond it
    * `:timeout` - milliseconds for the whole download, default 2 minutes
    * `:request` - builds the `Req.Request` from keyword options (`:url`, `:into`,
      ...), default `Angler.Media.TikTok.request/1` (following redirects)
    * `:budget` - a `t:budget/0` shared with other fetches: `{:error, :over_budget}`
      once all of them together would write more than its limit. A failed
      download gives its bytes back.

  On errors `path` may hold a partial file.
  """
  @spec to_file(String.t(), Path.t(), keyword()) :: {:ok, pos_integer()} | {:error, reason()}
  def to_file(url, path, opts) do
    job = %{
      url: url,
      max_bytes: Keyword.fetch!(opts, :max_bytes),
      deadline:
        System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @default_timeout),
      request: Keyword.get(opts, :request, &default_request/1),
      budget: Keyword.get(opts, :budget)
    }

    case File.open(path, [:write, :binary, :raw], &request(&1, job)) do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  @doc "A new `t:budget/0` of `limit` bytes, to share between fetches."
  @spec budget(non_neg_integer()) :: budget()
  def budget(limit) when is_integer(limit) and limit >= 0, do: {:atomics.new(1, []), limit}

  defp default_request(options), do: TikTok.request(Keyword.put(options, :redirect, true))

  defp request(file, job) do
    into = fn {:data, data}, {request, response} ->
      {action, response} = write(file, data, response, job)
      {action, {request, response}}
    end

    request = job.request.(url: job.url, into: into, compressed: false)

    result =
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

    with {:error, _reason} <- result, do: give_back(job.budget, file)
    result
  end

  # Only the body of a successful response is written; bodies of redirects and
  # errors are dropped.
  defp write(_file, _data, %Req.Response{status: status} = response, _job)
       when status != 200,
       do: {:cont, response}

  defp write(file, data, response, job) do
    bytes = bytes(response) + byte_size(data)

    result =
      cond do
        not take(job.budget, byte_size(data)) -> :over_budget
        bytes > job.max_bytes -> :too_large
        System.monotonic_time(:millisecond) > job.deadline -> :timeout
        true -> with {:error, reason} <- :file.write(file, data), do: {:write, reason}
      end

    case result do
      :ok ->
        {:cont, Req.Response.put_private(response, :bytes, bytes)}

      :over_budget ->
        {:halt, Req.Response.put_private(response, :error, :over_budget)}

      error ->
        release(job.budget, byte_size(data))
        {:halt, Req.Response.put_private(response, :error, error)}
    end
  end

  defp bytes(response), do: Req.Response.get_private(response, :bytes, 0)

  # Books `count` bytes on the shared budget, unless that would exceed its limit.
  defp take(nil, _count), do: true

  defp take({counter, limit}, count) do
    if :atomics.add_get(counter, 1, count) > limit do
      release({counter, limit}, count)
      false
    else
      true
    end
  end

  defp release(nil, _count), do: :ok
  defp release({counter, _limit}, count), do: :atomics.sub(counter, 1, count)

  # A failed download gives back the bytes it wrote (a chunk that was not
  # written is released right away).
  defp give_back(nil, _file), do: :ok

  defp give_back(budget, file) do
    case :file.position(file, :cur) do
      {:ok, written} when written > 0 -> release(budget, written)
      _other -> :ok
    end
  end

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
  def describe(:over_budget), do: "over the size limit"
  def describe(:timeout), do: "took too long"
  def describe(:empty), do: "empty response"
  def describe({:http, status}), do: "HTTP #{status}"
  def describe({:network, message}), do: message
  def describe({:host_not_allowed, nil}), do: "not a web address"
  def describe({:host_not_allowed, host}), do: "#{host} is not an allowed host"
  def describe({:write, reason}), do: "could not write the file: #{:file.format_error(reason)}"

  @doc """
  Whether the CDN refused a file (an HTTP error or an empty body), or the file's
  URL was refused before asking (a host that is not the site's CDN). With freshly
  signed URLs that is usually a passing refusal (a rate limit, a bad CDN node).
  """
  @spec refusal?(reason()) :: boolean()
  def refusal?({:http, _status}), do: true
  def refusal?(:empty), do: true
  def refusal?({:host_not_allowed, _host}), do: true
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

  @doc """
  The error for a `noun` (default `"slideshow"`) whose files exceed `budget` bytes
  (the source limit), e.g. "This slideshow is larger than 20 MB".
  """
  @spec over_budget(non_neg_integer(), String.t()) :: Error.t()
  def over_budget(budget, noun \\ "slideshow"),
    do: Error.new(:too_large, "This #{noun} is larger than #{Media.format_mb(budget)}")

  @doc "The error for a failure writing to disk."
  @spec write_error({:write, File.posix()}) :: Error.t()
  def write_error({:write, _posix} = reason), do: Error.new(:internal, describe(reason))
end
