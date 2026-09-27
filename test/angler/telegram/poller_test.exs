defmodule Angler.Telegram.PollerTest do
  # Not async: the poller writes through the shared sandbox, and one test takes the
  # database away.
  use Angler.DataCase, async: false

  import Angler.TelegramFixtures

  alias Angler.Entries.Entry
  alias Angler.Telegram.Poller

  @moduletag :capture_log

  @fast [timeout: 0, error_delay: 5, max_error_delay: 20, conflict_delay: 5, storage_delay: 5]

  # The poller runs under the test supervisor, so it finds this test's stubs
  # through its ancestors; `responses` is a list of getUpdates answers, one per call,
  # after which the poll blocks.
  defp start_poller(responses) do
    test = self()
    responses = start_supervised!({Agent, fn -> responses end})

    stub_bot_api(%{
      "getUpdates" => fn conn ->
        send(test, {:get_updates, conn.body_params["offset"]})

        case Agent.get_and_update(responses, fn list -> {List.first(list), Enum.drop(list, 1)} end) do
          nil -> receive(do: (:release -> Req.Test.json(conn, api_ok([]))))
          fun -> fun.(conn)
        end
      end
    })

    start_supervised!({Poller, [owner: test] ++ @fast})
  end

  defp updates(list), do: &Req.Test.json(&1, api_ok(list))

  # What `Angler.Telegram.Receiver.update_received/2` sends the owner.
  defmacrop update_received(at) do
    quote do: {:"$gen_cast", {:update_received, unquote(at)}}
  end

  defp error(code, description),
    do: &(&1 |> Plug.Conn.put_status(code) |> Req.Test.json(api_error(code, description)))

  test "handles updates in order and confirms them by advancing the offset" do
    first = build_update(group_message("https://youtu.be/one"))
    second = build_update(group_message("https://youtu.be/two"))
    third = build_update(group_message("no link"))

    start_poller([updates([first, second]), updates([third]), updates([])])

    assert_receive {:get_updates, nil}
    assert_receive {:get_updates, offset}
    assert offset == second["update_id"] + 1
    assert_receive {:get_updates, offset}
    assert offset == third["update_id"] + 1
    # An empty batch keeps the offset.
    assert_receive {:get_updates, ^offset}

    assert Repo.aggregate(Entry, :count) == 2
  end

  test "tells the owner when it handled updates, once per batch" do
    before = DateTime.utc_now()
    first = build_update(group_message("https://youtu.be/one"))
    second = build_update(group_message("no link"))

    start_poller([updates([first, second]), updates([])])

    assert_receive {:get_updates, nil}
    assert_receive update_received(%DateTime{} = at)
    assert DateTime.compare(at, before) != :lt

    # The empty batch and the blocked poll after it.
    assert_receive {:get_updates, _offset}
    assert_receive {:get_updates, _offset}
    refute_received update_received(_at)
  end

  test "skips updates that can't be processed" do
    poison = build_update(poison_message())
    good = build_update(group_message("https://youtu.be/good"))

    start_poller([updates([poison, good])])

    assert_receive {:get_updates, nil}
    assert_receive {:get_updates, offset}
    assert offset == good["update_id"] + 1
    assert [%Entry{url: "https://youtu.be/good"}] = Repo.all(Entry)
  end

  test "moves past an update with a link too long to store" do
    long = build_update(group_message(long_link(3_000)))
    good = build_update(group_message("https://youtu.be/good"))

    start_poller([updates([long, good])])

    assert_receive {:get_updates, nil}
    assert_receive {:get_updates, offset}
    assert offset == good["update_id"] + 1
    assert [%Entry{url: "https://youtu.be/good"}] = Repo.all(Entry)
  end

  test "pauses after a 409 conflict and reports it" do
    start_poller([error(409, "Conflict: terminated by other getUpdates request"), updates([])])

    assert_receive {:get_updates, nil}
    assert_receive {:poller_error, message}
    assert message =~ "Conflict: terminated by other getUpdates request"
    assert message =~ "another instance"

    assert_receive {:get_updates, nil}
    assert_receive {:poller_error, nil}
  end

  test "backs off after failed requests" do
    start_poller([
      &Req.Test.transport_error(&1, :timeout),
      error(502, "Bad Gateway"),
      updates([])
    ])

    assert_receive {:poller_error, "Telegram getUpdates failed: timeout"}
    assert_receive {:poller_error, "Telegram getUpdates failed (502): Bad Gateway"}
    assert_receive {:poller_error, nil}
    assert_receive {:get_updates, nil}
    assert_receive {:get_updates, nil}
    assert_receive {:get_updates, nil}
  end

  test "stops the batch at a storage failure and fetches from the failed update again" do
    first = build_update(group_message("https://youtu.be/one"))
    second = build_update(group_message("https://youtu.be/two"))

    # Leave the shared sandbox connection: queries now fail with an ownership error.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    start_poller([updates([first, second])])

    assert_receive {:get_updates, nil}
    assert_receive {:poller_error, "could not store update " <> _}

    first_id = first["update_id"]
    assert_receive {:get_updates, ^first_id}
    # Nothing was handled.
    refute_received update_received(_at)
  end
end
