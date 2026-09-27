defmodule Angler.Telegram.Receiver do
  @moduledoc """
  Starts receiving updates according to `Angler.Telegram.Config.mode/0`:

    * `:webhook` - registers the webhook with Telegram on boot (retrying until it succeeds)
    * `:polling` - removes any webhook and long-polls `getUpdates` (development)
      through a linked `Angler.Telegram.Poller`
    * `:disabled` - does nothing

  Both modes first fetch the bot's identity (`getMe`), which is cached for the
  dashboard. Failed setups are retried with exponential backoff (5 s doubling up to
  5 minutes). Telegram is only called from tasks and the poller, so booting never
  waits for Telegram and `status/0` always answers quickly.

  It also remembers when the app last received an update from Telegram (see
  `update_received/2`), so the dashboard can tell a recovered webhook error from a
  current one (`Angler.Telegram.Health`).

  Status changes are broadcast as `{:telegram_receiver, status}` (the map returned
  by `status/0` without `:webhook`), see `subscribe/0`. Received updates change the
  status on busy bots many times a second, so they are broadcast right away only
  for the first update since boot, and otherwise at most once per
  `:broadcast_interval` (30 s), the last one after the interval.
  """
  use GenServer

  require Logger

  alias Angler.Telegram
  alias Angler.Telegram.{Config, Poller, Updates}

  @pubsub Angler.PubSub
  @topic "telegram:receiver"
  @register_timeout 30_000

  @doc """
  Starts the receiver. Options (all optional, for tests): `:name`, `:mode`
  (defaults to the configured mode), `:retry_delay`, `:max_retry_delay` and
  `:broadcast_interval` (ms) and `:poller` (options for `Angler.Telegram.Poller`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Subscribes the caller to `{:telegram_receiver, status}` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc """
  Re-registers the webhook now (dashboard button). Only valid in webhook mode.
  Waits for the attempt and returns `:ok` or `{:error, reason}` with a readable reason.
  """
  @spec register_webhook(GenServer.server()) :: :ok | {:error, String.t()}
  def register_webhook(server \\ __MODULE__) do
    GenServer.call(server, :register, @register_timeout)
  catch
    :exit, {:timeout, _} -> {:error, "timed out waiting for Telegram"}
    :exit, _reason -> {:error, "the Telegram receiver is not running"}
  end

  @doc """
  Records that an update from Telegram was received at `at`: a webhook delivery
  the app acknowledged, or updates the poller handled. A cast, so it never blocks
  or fails, even when the receiver is not running.
  """
  @spec update_received(GenServer.server(), DateTime.t()) :: :ok
  def update_received(server \\ __MODULE__, at \\ DateTime.utc_now()),
    do: GenServer.cast(server, {:update_received, at})

  @doc """
  Status for the dashboard: `%{mode: atom, bot: map | nil, webhook: map | nil,
  last_error: String.t() | nil, last_update_at: DateTime.t() | nil}`, where `bot` is
  the cached `getMe` result, `webhook` a fresh `getWebhookInfo` (webhook mode) and
  `last_update_at` when an update was last received since the receiver started.

  `getWebhookInfo` runs in the calling process; `webhook` is nil when it fails.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    status =
      try do
        GenServer.call(server, :status)
      catch
        :exit, _reason ->
          %{
            mode: Config.mode(),
            bot: nil,
            last_error: "the Telegram receiver is not running",
            last_update_at: nil
          }
      end

    Map.put(status, :webhook, webhook_info(status.mode))
  end

  defp webhook_info(:webhook) do
    case Telegram.get_webhook_info() do
      {:ok, info} -> info
      {:error, _error} -> nil
    end
  end

  defp webhook_info(_mode), do: nil

  ## Server

  @impl true
  def init(opts) do
    mode = Keyword.get_lazy(opts, :mode, &Config.mode/0)
    retry_delay = Keyword.get(opts, :retry_delay, 5_000)

    state = %{
      mode: mode,
      bot: nil,
      last_error: nil,
      last_update_at: nil,
      # Throttles broadcasts of received updates: the last broadcast (monotonic ms)
      # and the timer of the next one.
      broadcast_interval: Keyword.get(opts, :broadcast_interval, 30_000),
      last_broadcast: nil,
      broadcast_timer: nil,
      # Monitor ref of the running setup task, callers of register_webhook/0 waiting for it
      setup: nil,
      waiting: [],
      initial_retry_delay: retry_delay,
      retry_delay: retry_delay,
      max_retry_delay: Keyword.get(opts, :max_retry_delay, 300_000),
      retry_timer: nil,
      poller: nil,
      poller_opts: Keyword.get(opts, :poller, [])
    }

    case mode do
      :disabled ->
        {:ok, state}

      :polling ->
        # The poller is linked: restart it with backoff when it dies.
        Process.flag(:trap_exit, true)
        {:ok, state, {:continue, :setup}}

      :webhook ->
        {:ok, state, {:continue, :setup}}
    end
  end

  @impl true
  def handle_continue(:setup, state), do: {:noreply, start_setup(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:register, from, %{mode: :webhook} = state) do
    state = start_setup(state)
    {:noreply, %{state | waiting: [from | state.waiting]}}
  end

  def handle_call(:register, _from, state), do: {:reply, {:error, "not in webhook mode"}, state}

  @impl true
  def handle_cast({:update_received, %DateTime{} = at}, state),
    do: {:noreply, record_update(state, at)}

  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info({ref, result}, %{setup: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, setup_finished(%{state | setup: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{setup: ref} = state) do
    message = "setup crashed: " <> Telegram.redact(Exception.format_exit(reason))
    {:noreply, setup_finished(%{state | setup: nil}, {:error, message})}
  end

  def handle_info(:retry, state), do: {:noreply, start_setup(%{state | retry_timer: nil})}

  def handle_info({:timeout, timer, :broadcast}, %{broadcast_timer: timer} = state),
    do: {:noreply, broadcast(state)}

  def handle_info({:poller_error, error}, state) do
    {:noreply, broadcast(%{state | last_error: error})}
  end

  def handle_info({:EXIT, pid, reason}, %{poller: pid} = state) do
    message = "poller stopped: " <> Telegram.redact(Exception.format_exit(reason))
    Logger.error("Telegram #{message}")
    {:noreply, schedule_retry(%{state | poller: nil, last_error: message})}
  end

  # Exits of other linked processes, replies to register_webhook/0 callers that gave
  # up, broadcast timers that fired just before being cancelled.
  def handle_info(_message, state), do: {:noreply, state}

  ## Setup

  defp start_setup(%{setup: nil} = state) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    mode = state.mode
    task = Task.Supervisor.async_nolink(Angler.TaskSupervisor, fn -> setup(mode) end)
    %{state | setup: task.ref, retry_timer: nil}
  end

  defp start_setup(state), do: state

  defp setup(:webhook) do
    url = Config.webhook_url()
    secret = Config.webhook_secret()

    cond do
      url in [nil, ""] ->
        {:error, "no webhook URL configured (PUBLIC_URL or TELEGRAM_WEBHOOK_URL)"}

      secret in [nil, ""] ->
        {:error, "no webhook secret configured (TELEGRAM_WEBHOOK_SECRET)"}

      true ->
        readable(
          with {:ok, bot} <- Telegram.get_me(),
               {:ok, _} <-
                 Telegram.set_webhook(url, secret,
                   allowed_updates: Updates.allowed_updates(),
                   max_connections: Config.max_connections()
                 ) do
            {:ok, bot}
          end
        )
    end
  end

  defp setup(:polling) do
    readable(
      with {:ok, bot} <- Telegram.get_me(),
           {:ok, _} <- Telegram.delete_webhook(drop_pending_updates: false) do
        {:ok, bot}
      end
    )
  end

  # Telegram errors never contain the bot token, so their messages can be shown.
  defp readable({:error, %Telegram.Error{} = error}), do: {:error, Exception.message(error)}
  defp readable(result), do: result

  defp setup_finished(state, {:ok, bot}) do
    state = started(%{state | bot: bot, last_error: nil, retry_delay: state.initial_retry_delay})
    reply_waiting(state, :ok)
  end

  defp setup_finished(state, {:error, message}) do
    Logger.warning(
      "Telegram #{state.mode} setup failed: #{message}; retrying in #{div(state.retry_delay, 1_000)} s"
    )

    state = schedule_retry(%{state | last_error: message})
    reply_waiting(state, {:error, message})
  end

  defp started(%{mode: :webhook} = state) do
    Logger.info("Telegram webhook registered for #{bot_name(state.bot)}: #{Config.webhook_url()}")
    broadcast(state)
  end

  defp started(%{mode: :polling, poller: nil} = state) do
    {:ok, poller} = Poller.start_link([owner: self()] ++ state.poller_opts)
    Logger.info("Polling Telegram for updates as #{bot_name(state.bot)}")
    broadcast(%{state | poller: poller})
  end

  defp started(state), do: broadcast(state)

  defp schedule_retry(state) do
    timer = Process.send_after(self(), :retry, state.retry_delay)
    retry_delay = min(state.retry_delay * 2, state.max_retry_delay)
    broadcast(%{state | retry_timer: timer, retry_delay: retry_delay})
  end

  defp reply_waiting(state, reply) do
    Enum.each(state.waiting, &GenServer.reply(&1, reply))
    %{state | waiting: []}
  end

  ## Received updates

  defp record_update(%{last_update_at: nil} = state, at),
    do: broadcast(%{state | last_update_at: at})

  # Concurrent webhook requests may report their times out of order.
  defp record_update(state, at) do
    if DateTime.after?(at, state.last_update_at),
      do: throttle_broadcast(%{state | last_update_at: at}),
      else: state
  end

  defp throttle_broadcast(%{broadcast_timer: nil, last_broadcast: last} = state) do
    wait = if last, do: last + state.broadcast_interval - now(), else: 0

    if wait <= 0,
      do: broadcast(state),
      else: %{state | broadcast_timer: :erlang.start_timer(wait, self(), :broadcast)}
  end

  # A broadcast is already scheduled; it sends the status as it is by then.
  defp throttle_broadcast(state), do: state

  defp broadcast(state) do
    if state.broadcast_timer, do: :erlang.cancel_timer(state.broadcast_timer)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:telegram_receiver, public_status(state)})
    %{state | broadcast_timer: nil, last_broadcast: now()}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp public_status(state), do: Map.take(state, [:mode, :bot, :last_error, :last_update_at])

  defp bot_name(%{"username" => username}), do: "@" <> username
  defp bot_name(_bot), do: "the bot"
end
