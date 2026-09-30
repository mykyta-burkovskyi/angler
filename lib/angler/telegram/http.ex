defmodule Angler.Telegram.HTTP do
  @moduledoc """
  Request plumbing behind `Angler.Telegram`: builds the Req request for a Bot API
  method, decodes Telegram's answer (or an HTTP/transport failure) into
  `{:ok, result}` or `{:error, %Angler.Telegram.Error{}}`, and sends calls that
  post into a chat through `Angler.Telegram.RateLimiter`, retrying short 429s as
  described in `Angler.Telegram`.

  The bot token is part of every request URL and is redacted (`redact/1`) from
  every error built here.
  """
  alias Angler.Telegram
  alias Angler.Telegram.{Config, Error, RateLimiter, SentTracker}

  @receive_timeout 30_000
  @max_rate_limit_retries 2
  @retry_margin_ms 250
  # A send that would have to wait longer than this for the local limiter or a
  # 429's retry_after fails with a 429 instead, so the caller can reschedule it.
  @max_wait_ms 60_000
  @max_body_excerpt 200

  @doc """
  Posts `method` with `body`, the Req body options (`json:` or `form_multipart:`).

  Options: `:api_base_url` (default the configured one), `track_sent: true` (sets
  `Angler.Telegram.Error`'s `:request_sent` on transport errors) and any `Req`
  options, e.g. `receive_timeout: 60_000`.
  """
  @spec post(String.t(), keyword(), keyword()) :: Telegram.result()
  def post(method, body, opts) do
    {api_base_url, req_opts} = Keyword.pop_lazy(opts, :api_base_url, &Config.api_base_url/0)
    {track_sent?, req_opts} = Keyword.pop(req_opts, :track_sent, false)

    case Config.token() do
      token when is_binary(token) and token != "" ->
        req =
          [
            base_url: api_base_url <> "/bot" <> token,
            finch: [name: Angler.Finch],
            retry: false,
            receive_timeout: @receive_timeout
          ]
          |> Req.new()
          |> Req.merge(Config.req_options())
          |> Req.merge(req_opts)

        request = fn -> Req.post(req, [url: method] ++ body) end

        {response, sent?} =
          if track_sent?, do: SentTracker.run(request), else: {request.(), false}

        handle_response(response, method, sent?)

      _ ->
        {:error, %Error{method: method, description: "TELEGRAM_BOT_TOKEN is not configured"}}
    end
  end

  @doc """
  Posts `method` into chat `chat_id` once `Angler.Telegram.RateLimiter` gives it a
  slot of `kind` (`:message`, or `:light` for best-effort calls that are never
  retried), retrying 429 answers whose wait is short (see `Angler.Telegram`).

  Options: `:chat_type` (for the rate limiter), `:max_wait` (ms, default a minute),
  `:count` (how many messages the call posts, e.g. an album's items; default 1)
  and those of `post/3`.
  """
  @spec send_to_chat(String.t(), integer(), RateLimiter.kind(), keyword(), keyword()) ::
          Telegram.result()
  def send_to_chat(method, chat_id, kind, body, opts \\ []) do
    {chat_type, opts} = Keyword.pop(opts, :chat_type)
    {count, opts} = Keyword.pop(opts, :count, 1)
    {max_wait, req_opts} = Keyword.pop(opts, :max_wait)

    call = %{
      method: method,
      chat_id: chat_id,
      chat_type: chat_type,
      kind: kind,
      count: count,
      body: body,
      req_opts: req_opts,
      max_wait: max_wait || @max_wait_ms
    }

    send_with_retries(call, 0)
  end

  @doc "See `Angler.Telegram.redact/1`."
  @spec redact(String.t() | nil) :: String.t() | nil
  def redact(text) when is_binary(text) do
    case Config.token() do
      token when is_binary(token) and token != "" -> String.replace(text, token, "<token>")
      _ -> text
    end
  end

  def redact(nil), do: nil

  ## Rate limited calls

  defp send_with_retries(call, retries) do
    with {:ok, booking} <- acquire(call),
         {:error, %Error{code: 429} = error} <- post(call.method, call.body, call.req_opts) do
      error = %Error{error | retry_after: error.retry_after || 1}

      cond do
        # Best effort: a late reaction or chat action is worse than none, and must
        # not hold back the chat's videos.
        call.kind == :light ->
          {:error, error}

        error.retry_after * 1_000 <= call.max_wait and retries < @max_rate_limit_retries ->
          back_off(call, error, booking)
          Process.sleep(error.retry_after * 1_000 + @retry_margin_ms)
          send_with_retries(call, retries + 1)

        true ->
          back_off(call, error, booking)
          {:error, error}
      end
    end
  end

  # Telegram posted none of the booked messages: their slot is given back, the
  # bookings of other sends to the chat stay.
  defp back_off(call, error, booking),
    do: RateLimiter.backoff(call.chat_id, error.retry_after, release: booking)

  defp acquire(call) do
    case RateLimiter.acquire(call.chat_id, call.chat_type, call.kind,
           max_wait: call.max_wait,
           count: call.count
         ) do
      {:ok, booking} ->
        {:ok, booking}

      {:error, :invalid_count} ->
        {:error,
         %Error{
           method: call.method,
           code: 400,
           description:
             "Bad Request: the local rate limiter can't book #{inspect(call.count)} messages at once"
         }}

      {:error, {:rate_limited, wait_ms}} ->
        retry_after = div(wait_ms + 999, 1_000)

        {:error,
         %Error{
           method: call.method,
           code: 429,
           description: "Too Many Requests: held back by the local rate limiter",
           retry_after: retry_after
         }}
    end
  end

  ## Responses

  defp handle_response({:ok, %Req.Response{body: %{"ok" => true} = body}}, _method, _sent?),
    do: {:ok, body["result"]}

  defp handle_response(
         {:ok, %Req.Response{body: %{"ok" => false} = body} = response},
         method,
         _sent?
       ) do
    parameters = if is_map(body["parameters"]), do: body["parameters"], else: %{}
    code = body["error_code"] || response.status

    {:error,
     %Error{
       method: method,
       code: code,
       description: redact(body["description"]),
       retry_after: seconds(parameters["retry_after"]) || retry_after_header(response, code),
       migrate_to_chat_id: parameters["migrate_to_chat_id"]
     }}
  end

  # Proxies and the HTTP layer of the Bot API server answer with HTML or empty
  # bodies, e.g. 413 for oversized uploads.
  defp handle_response({:ok, %Req.Response{status: status, body: body}}, method, _sent?),
    do:
      {:error, %Error{method: method, code: status, description: http_description(status, body)}}

  defp handle_response({:error, exception}, method, sent?) do
    {:error,
     %Error{
       method: method,
       reason: exception,
       description: redact(Exception.message(exception)),
       request_sent: sent?
     }}
  end

  defp retry_after_header(response, 429) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(String.trim(value)) do
      seconds(seconds)
    else
      _ -> nil
    end
  end

  defp retry_after_header(_response, _code), do: nil

  defp seconds(value) when is_integer(value) and value >= 0, do: value
  defp seconds(_value), do: nil

  defp http_description(status, body) do
    case body_excerpt(body) do
      "" -> "HTTP #{status}"
      excerpt -> "HTTP #{status}: #{excerpt}"
    end
  end

  defp body_excerpt(body) when is_binary(body) do
    if String.valid?(body) do
      body
      |> String.replace(~r/<[^>]*>/, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, @max_body_excerpt)
      |> redact()
    else
      ""
    end
  end

  defp body_excerpt(_body), do: ""
end
