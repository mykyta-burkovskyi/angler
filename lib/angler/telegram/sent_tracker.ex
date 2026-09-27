defmodule Angler.Telegram.SentTracker do
  @moduledoc """
  Tells whether an HTTP request made by the calling process had been sent
  completely before it failed, i.e. whether the server may have carried it out.

  Finch's HTTP/1 pools (used by `Angler.Finch`) run requests in the calling process
  and emit `[:finch, :recv, :start]` there once the request line, headers and body
  have been written. A transport error before that event (connect failures, a
  connection lost while uploading) means the request was never complete; an error
  after it (a receive timeout, a connection closed while waiting for the answer)
  leaves the outcome unknown.
  """

  @event [:finch, :recv, :start]
  @handler_id "angler-telegram-sent-tracker"
  @key {__MODULE__, :sent}

  @doc """
  Runs `fun` (which should make a single request) and returns its result together
  with whether the request was sent completely.
  """
  @spec run((-> result)) :: {result, sent? :: boolean()} when result: term()
  def run(fun) when is_function(fun, 0) do
    attach()
    previous = Process.put(@key, false)

    try do
      result = fun.()
      {result, Process.get(@key) == true}
    after
      if previous == nil, do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @doc false
  # Telemetry handler, runs in the process that made the request.
  def handle_event(@event, _measurements, _metadata, _config) do
    if Process.get(@key) == false, do: Process.put(@key, true)
    :ok
  end

  # Attached on first use (the handler is global and stays attached).
  defp attach do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end
end
